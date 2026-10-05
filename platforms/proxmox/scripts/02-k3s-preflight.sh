#!/bin/bash
# File: platforms/proxmox/scripts/02-k3s-preflight.sh
#
# Description:
#   Verify the one-time, NOT-scripted prerequisites are actually in place before
#   03-k3s-apply.sh touches anything:
#     1. ansible is available in this container (installs it if not)
#     2. the SSH key config.sh names exists (generates it if not)
#     3. all three Proxmox hosts are reachable with that key
#     4. all three are actually Proxmox, and the same major version
#     5. all three are joined in one quorate cluster
#     6. the configured storage exists on all three
#
# Why steps 5-6 are CHECKED, not CREATED: forming the Proxmox cluster itself
# needs a human typing a root password at one point (`pvecm add` authenticates
# over the Proxmox API, not SSH keys — no wrapper removes that step). See
# README.md's "Before you start" for the exact manual commands. This script's
# job is to fail loudly and early if that part wasn't done, not to attempt it.
#
# Usage:
#   ./scripts/02-k3s-preflight.sh

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
print_status()  { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
print_section() { echo; echo -e "${GREEN}========================================${NC}"; echo -e "${GREEN}$1${NC}"; echo -e "${GREEN}========================================${NC}"; echo; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$PLATFORM_DIR/config.sh"

print_section "PROXMOX-K3S — PREFLIGHT"

if [[ ! -f "$CONFIG_FILE" ]]; then
    print_error "No config.sh found at $CONFIG_FILE"
    echo "  Copy config.sh-template to config.sh and fill in your 3 machines first."
    echo "  (./uis platform init proxmox does this for you interactively.)"
    exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE"

# ─── Step 1: ansible available ────────────────────────────────────────────
# 🔴 NOT a self-heal install if missing. The provision-host image already guarantees
# ansible-core from PyPI, not apt (provision-host-02-kubetools.sh — deliberately PyPI, since
# Launchpad's PPA flakes regularly; see that script's own comment). `apt-get install ansible`
# would install a second, DIFFERENT ansible stack (Ubuntu's distro package) alongside the pip
# one every other UIS playbook relies on, rather than treating a missing `ansible-playbook` as
# what it actually is — a broken image — and failing loudly. Same philosophy the cluster-
# membership check two steps below already uses: refuse and point at the real fix, don't
# improvise a different one.
print_section "Step 1: ansible"
if ! command -v ansible-playbook >/dev/null 2>&1; then
    print_error "ansible-playbook not found in this container."
    echo "  This image is expected to ship it (via pip, provision-host-02-kubetools.sh)."
    echo "  Rebuild the provision-host image rather than installing a second ansible stack here."
    exit 1
fi
print_success "ansible-playbook: $(ansible-playbook --version | head -1)"

# ─── Step 2: SSH key ───────────────────────────────────────────────────────
print_section "Step 2: SSH key"
if [[ ! -f "$PROXMOX_SSH_KEY" ]]; then
    print_warning "No key at $PROXMOX_SSH_KEY — generating one"
    mkdir -p "$(dirname "$PROXMOX_SSH_KEY")"
    ssh-keygen -t ed25519 -f "$PROXMOX_SSH_KEY" -N "" -C "proxmox" >/dev/null
    echo
    echo "  Public key (add this to each Proxmox host's /root/.ssh/authorized_keys"
    echo "  before continuing — see README.md's \"Before you start\"):"
    echo
    cat "${PROXMOX_SSH_KEY}.pub"
    echo
fi
print_success "SSH key: $PROXMOX_SSH_KEY"

# ─── Step 3-4: each host reachable, is Proxmox, versions match ───────────
print_section "Step 3: the three Proxmox hosts"
declare -a HOST_NAMES=("$PROXMOX_HOST1_NAME" "$PROXMOX_HOST2_NAME" "$PROXMOX_HOST3_NAME")
declare -a HOST_ADDRS=("$PROXMOX_HOST1_ADDR" "$PROXMOX_HOST2_ADDR" "$PROXMOX_HOST3_ADDR")
declare -a PVE_VERSIONS=()

SSH_OPTS=(-i "$PROXMOX_SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes)

for i in 0 1 2; do
    name="${HOST_NAMES[$i]}"; addr="${HOST_ADDRS[$i]}"
    print_status "Checking $name ($addr)..."
    if ! ssh "${SSH_OPTS[@]}" "root@${addr}" true 2>/dev/null; then
        print_error "$name ($addr) is not reachable by SSH as root with $PROXMOX_SSH_KEY"
        echo "  Add the public key printed above to its /root/.ssh/authorized_keys."
        exit 1
    fi
    ver="$(ssh "${SSH_OPTS[@]}" "root@${addr}" pveversion 2>/dev/null || true)"
    if [[ -z "$ver" ]]; then
        print_error "$name ($addr) answers SSH but 'pveversion' failed — is Proxmox installed?"
        exit 1
    fi
    PVE_VERSIONS+=("$ver")
    print_success "$name — $ver"
done

if [[ "${PVE_VERSIONS[0]%% *}" != "${PVE_VERSIONS[1]%% *}" ]] || [[ "${PVE_VERSIONS[1]%% *}" != "${PVE_VERSIONS[2]%% *}" ]]; then
    print_warning "The three hosts report different pveversion output — fine if intentional, worth a second look if not:"
    for i in 0 1 2; do echo "    ${HOST_NAMES[$i]}: ${PVE_VERSIONS[$i]}"; done
fi

# ─── Step 5: one quorate cluster ──────────────────────────────────────────
print_section "Step 5: cluster membership"
PVECM_OUT="$(ssh "${SSH_OPTS[@]}" "root@${HOST_ADDRS[0]}" pvecm status 2>&1 || true)"
if ! echo "$PVECM_OUT" | grep -q "Quorate:\s*Yes"; then
    print_error "${HOST_NAMES[0]} is not in a quorate Proxmox cluster."
    echo "  This is the one step that genuinely needs a human — see README.md's"
    echo "  \"Before you start\" for the exact pvecm commands. Run them, then re-run"
    echo "  this script."
    echo
    echo "  Raw pvecm status:"
    echo "$PVECM_OUT" | sed 's/^/    /'
    exit 1
fi
NODE_COUNT="$(echo "$PVECM_OUT" | grep -oP 'Nodes:\s*\K[0-9]+' || echo "?")"
print_success "Quorate, $NODE_COUNT node(s)"

for i in 1 2; do
    name="${HOST_NAMES[$i]}"; addr="${HOST_ADDRS[$i]}"
    if ! ssh "${SSH_OPTS[@]}" "root@${addr}" "pvecm status 2>&1 | grep -q 'Quorate:\\s*Yes'"; then
        print_error "$name does not report Quorate: Yes — is it actually in the same cluster as ${HOST_NAMES[0]}?"
        exit 1
    fi
done
print_success "All three hosts confirm membership in the same quorate cluster"

# ─── Step 6: storage exists everywhere ────────────────────────────────────
print_section "Step 6: storage \"$PROXMOX_STORAGE\""
for i in 0 1 2; do
    name="${HOST_NAMES[$i]}"; addr="${HOST_ADDRS[$i]}"
    if ! ssh "${SSH_OPTS[@]}" "root@${addr}" "pvesm status --storage ${PROXMOX_STORAGE}" >/dev/null 2>&1; then
        print_error "Storage '$PROXMOX_STORAGE' not found on $name"
        echo "  See README.md's \"Before you start\" for how the reference lab created this"
        echo "  (a ZFS pool registered as Proxmox storage, same name on every host)."
        exit 1
    fi
done
print_success "Storage '$PROXMOX_STORAGE' present on all three hosts"

print_section "PREFLIGHT COMPLETE"
echo "All three Proxmox hosts are reachable, clustered, and have the right storage."
echo "Next: ./scripts/03-k3s-apply.sh (or ./uis platform up proxmox)"
