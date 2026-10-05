#!/bin/bash
# File: platforms/proxmox/scripts/00-storage-ensure.sh
#
# Description:
#   Phase 2 of the novice-lab-owner sequence: give each of the 3 configured Proxmox hosts a
#   working ZFS pool, registered as Proxmox storage, reachable by this platform's own SSH key
#   from here on. Scripts stay thin — platforms/proxmox/ansible/playbooks/storage-ensure.yml
#   does the actual work; this just drives it once per host and handles the one interactive
#   bootstrap step ansible itself can do (--ask-pass), nothing hand-rolled.
#
# Usage:
#   ./scripts/00-storage-ensure.sh                  # bootstrap key + verify every host (safe,
#                                                      no disk is ever touched by this mode)
#   ./scripts/00-storage-ensure.sh --create-pool    # also create the pool, per host — shows the
#                                                      exact disk found, asks for a typed "YES"
#
# 🔴 The pool-creation step is DESTRUCTIVE on whatever disk is chosen. This script auto-detects
# a candidate disk per host and asks for an explicit typed "YES" before touching it — it never
# proceeds on an assumption.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
print_status()  { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
print_section() { echo; echo -e "${GREEN}========================================${NC}"; echo -e "${GREEN}$1${NC}"; echo -e "${GREEN}========================================${NC}"; echo; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ANSIBLE_DIR="$PLATFORM_DIR/ansible"
CONFIG_FILE="$PLATFORM_DIR/config.sh"
PLAYBOOK="$ANSIBLE_DIR/playbooks/storage-ensure.yml"

CREATE_POOL=0
for arg in "$@"; do
    [[ "$arg" == "--create-pool" ]] && CREATE_POOL=1
done

print_section "PROXMOX — STORAGE ENSURE"

if [[ ! -f "$CONFIG_FILE" ]]; then
    print_error "No config.sh found at $CONFIG_FILE"
    echo "  Copy config.sh-template to config.sh and fill in your 3 machines first."
    echo "  (./uis platform init proxmox does this for you interactively.)"
    exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE"

if ! command -v ansible-playbook >/dev/null 2>&1; then
    print_error "ansible-playbook not found in this container."
    echo "  This image is expected to ship it (via pip, provision-host-02-kubetools.sh)."
    exit 1
fi

# ─── the control key: created here if this is the very first run ─────────────────────────────
if [[ ! -f "$PROXMOX_SSH_KEY" ]]; then
    print_warning "No key at $PROXMOX_SSH_KEY — generating one"
    mkdir -p "$(dirname "$PROXMOX_SSH_KEY")"
    ssh-keygen -t ed25519 -f "$PROXMOX_SSH_KEY" -N "" -C "proxmox" >/dev/null
fi
print_success "Control key: $PROXMOX_SSH_KEY"

declare -a HOST_NAMES=("$PROXMOX_HOST1_NAME" "$PROXMOX_HOST2_NAME" "$PROXMOX_HOST3_NAME")
declare -a HOST_ADDRS=("$PROXMOX_HOST1_ADDR" "$PROXMOX_HOST2_ADDR" "$PROXMOX_HOST3_ADDR")

for i in 0 1 2; do
    name="${HOST_NAMES[$i]}"; addr="${HOST_ADDRS[$i]}"
    print_section "$name ($addr)"

    # ─── does the key already work? ────────────────────────────────────────────────────────
    if ssh -i "$PROXMOX_SSH_KEY" -o BatchMode=yes -o ConnectTimeout=6 \
         -o StrictHostKeyChecking=accept-new "root@${addr}" true 2>/dev/null; then
        print_success "key already works — no bootstrap needed"
    else
        if ! command -v sshpass >/dev/null 2>&1; then
            print_error "Key auth to $name failed, and sshpass isn't installed — can't ask for"
            echo "  the root password to bootstrap it. Install sshpass in this container, or"
            echo "  add $PROXMOX_SSH_KEY.pub to $name's /root/.ssh/authorized_keys yourself."
            exit 1
        fi
        print_warning "Key auth failed — will ask for ${name}'s ROOT PASSWORD once, to install it"
        echo
        if ! ansible-playbook -i "${addr}," "$PLAYBOOK" \
                -e "control_pubkey_file=${PROXMOX_SSH_KEY}.pub" \
                -e "storage_id=${PROXMOX_STORAGE}" \
                -k; then
            print_error "Bootstrap failed for $name — see the ansible output above."
            exit 1
        fi
        print_success "$name bootstrapped — key installed and confirmed"
    fi

    # ─── verify (and, if asked, create the pool) over the now-working key ───────────────────
    EXTRA_ARGS=(-e "control_pubkey_file=${PROXMOX_SSH_KEY}.pub" -e "storage_id=${PROXMOX_STORAGE}")

    if [[ "$CREATE_POOL" == "1" ]]; then
        # Ask once, read-only, what this host's pool situation already is.
        ansible-playbook -i "${addr}," --private-key "$PROXMOX_SSH_KEY" "$PLAYBOOK" "${EXTRA_ARGS[@]}"

        print_status "Looking for a candidate disk on $name..."
        disk_id="$(ssh -i "$PROXMOX_SSH_KEY" -o BatchMode=yes "root@${addr}" \
            "ls -1 /dev/disk/by-id/ | grep -vE -- '-part[0-9]+$' | grep -viE '^(nvme-eui|wwn-)' | head -1" || true)"

        if [[ -z "$disk_id" ]]; then
            print_error "Could not auto-detect a disk on $name. List them yourself:"
            echo "    ssh -i $PROXMOX_SSH_KEY root@${addr} 'ls -1 /dev/disk/by-id/'"
            echo "  then re-run with that id — auto-detect is a convenience, not the only path."
            exit 1
        fi

        echo
        echo "  Found: /dev/disk/by-id/${disk_id}"
        echo "  🔴 This ERASES that disk to build the ZFS pool. Ctrl-C now if it's the wrong one."
        printf "  Type YES to continue on %s: " "$name"
        read -r confirm
        if [[ "$confirm" != "YES" ]]; then
            print_warning "Skipped $name — not confirmed."
            continue
        fi

        ansible-playbook -i "${addr}," --private-key "$PROXMOX_SSH_KEY" "$PLAYBOOK" \
            "${EXTRA_ARGS[@]}" -e create_pool=true -e "pool_disk_id=${disk_id}"
    else
        ansible-playbook -i "${addr}," --private-key "$PROXMOX_SSH_KEY" "$PLAYBOOK" "${EXTRA_ARGS[@]}"
    fi
done

print_section "STORAGE ENSURE COMPLETE"
if [[ "$CREATE_POOL" == "1" ]]; then
    echo "All 3 hosts bootstrapped; pools created where confirmed."
else
    echo "All 3 hosts bootstrapped and verified. Nothing destructive has happened yet."
    echo "Next: ./scripts/00-storage-ensure.sh --create-pool"
fi
echo "Then: ./scripts/01-cluster-join.sh --via <existing-member>"
