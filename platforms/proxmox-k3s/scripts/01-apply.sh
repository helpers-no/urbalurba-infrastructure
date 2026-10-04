#!/bin/bash
# File: platforms/proxmox-k3s/scripts/01-apply.sh
#
# Description:
#   Build the six k3s VMs (one production + one mirror-test node per Proxmox
#   host) and form both k3s clusters. Idempotent — every step checks "does
#   this already exist" first, so a warm re-run is a fast no-op, same as a
#   cold run is a full build.
#
# Prerequisites:
#   - scripts/00-preflight.sh passed (3 Proxmox hosts reachable, clustered,
#     storage present)
#
# Usage:
#   ./scripts/01-apply.sh

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

if [[ ! -f "$CONFIG_FILE" ]]; then
    print_error "No config.sh found — run ./scripts/00-preflight.sh first."
    exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE"

print_section "PROXMOX-K3S — APPLY"

# ─── Step 1: generate the ansible inventory + VM declarations ────────────
print_status "Generating ansible config from config.sh..."
bash "$SCRIPT_DIR/generate-ansible-config.sh"

cd "$ANSIBLE_DIR"
INV="generated/inventory.yml"
PUBKEY="${PROXMOX_SSH_KEY}.pub"

ap() { ansible-playbook -i "$INV" "$@"; }

# ─── Step 2: create the six VMs ───────────────────────────────────────────
print_section "Step 2: create the six k3s VMs"

declare -a VM_SPECS=(
  "${PROXMOX_HOST1_NAME} ${PROXMOX_HOST1_NAME}-k3s"
  "${PROXMOX_HOST1_NAME} ${PROXMOX_HOST1_NAME}-k3s-test"
  "${PROXMOX_HOST2_NAME} ${PROXMOX_HOST2_NAME}-k3s"
  "${PROXMOX_HOST2_NAME} ${PROXMOX_HOST2_NAME}-k3s-test"
  "${PROXMOX_HOST3_NAME} ${PROXMOX_HOST3_NAME}-k3s"
  "${PROXMOX_HOST3_NAME} ${PROXMOX_HOST3_NAME}-k3s-test"
)

for spec in "${VM_SPECS[@]}"; do
    read -r host vm <<< "$spec"
    print_status "vm-ensure: $vm on $host"
    ap playbooks/vm-ensure.yml --limit "$host" \
        -e "vm_file=generated/vars/vms/${vm}.yml" \
        -e "control_pubkey_file=${PUBKEY}"
done
print_success "All six VMs created and reachable"

# ─── Step 3: production cluster — init then join ──────────────────────────
print_section "Step 3: production k3s cluster"

INIT_VM="${PROXMOX_HOST1_NAME}-k3s"
JOIN_VMS=("${PROXMOX_HOST2_NAME}-k3s" "${PROXMOX_HOST3_NAME}-k3s")

print_status "k3s-ensure: $INIT_VM (--cluster-init)"
ap playbooks/k3s-ensure.yml --limit "$INIT_VM" \
    -e "vm_file=generated/vars/vms/${INIT_VM}.yml"

# Read the generated token straight from the init node — never written to a
# file, held only in this shell's memory for the rest of this run.
TOKEN="$(ssh -i "$PROXMOX_SSH_KEY" -o StrictHostKeyChecking=accept-new "${VM_CIUSER}@${K3S_VM_HOST1_IP}" \
    sudo cat /var/lib/rancher/k3s/server/node-token)"

for i in 0 1; do
    vm="${JOIN_VMS[$i]}"
    print_status "k3s-ensure: $vm (join)"
    ap playbooks/k3s-ensure.yml --limit "$vm" \
        -e "vm_file=generated/vars/vms/${vm}.yml" \
        -e "k3s_token=${TOKEN}"
done
unset TOKEN
print_success "Production cluster formed"

# ─── Step 4: mirror test cluster — init then join ─────────────────────────
print_section "Step 4: mirror test k3s cluster"

INIT_VM_TEST="${PROXMOX_HOST1_NAME}-k3s-test"
JOIN_VMS_TEST=("${PROXMOX_HOST2_NAME}-k3s-test" "${PROXMOX_HOST3_NAME}-k3s-test")

print_status "k3s-ensure: $INIT_VM_TEST (--cluster-init)"
ap playbooks/k3s-ensure.yml --limit "$INIT_VM_TEST" \
    -e "vm_file=generated/vars/vms/${INIT_VM_TEST}.yml"

TOKEN="$(ssh -i "$PROXMOX_SSH_KEY" -o StrictHostKeyChecking=accept-new "${VM_CIUSER}@${K3S_VM_HOST1_TEST_IP}" \
    sudo cat /var/lib/rancher/k3s/server/node-token)"

for vm in "${JOIN_VMS_TEST[@]}"; do
    print_status "k3s-ensure: $vm (join)"
    ap playbooks/k3s-ensure.yml --limit "$vm" \
        -e "vm_file=generated/vars/vms/${vm}.yml" \
        -e "k3s_token=${TOKEN}"
done
unset TOKEN
print_success "Mirror test cluster formed"

print_section "APPLY COMPLETE"
echo "Both k3s clusters are up. Next: ./scripts/02-post-apply.sh (or ./uis platform up proxmox-k3s)"
