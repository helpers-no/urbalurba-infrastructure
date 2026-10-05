#!/bin/bash
# File: platforms/proxmox/scripts/06-destroy.sh
#
# Description:
#   Destroy the six k3s VMs this platform created. Does NOT touch the
#   underlying Proxmox cluster or any of its other guests — those are
#   persistent infrastructure this platform was built ON TOP OF, not
#   something it owns the lifecycle of. "Destroy" here means the same thing
#   it means for a cloud platform's cluster: tear down the (re-creatable)
#   compute, leave the substrate alone.
#
# Usage:
#   ./scripts/06-destroy.sh
#   UIS_DESTROY_CONFIRM=proxmox ./scripts/06-destroy.sh   # non-interactive

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$PLATFORM_DIR/config.sh"

if [[ ! -f "$CONFIG_FILE" ]]; then
    print_error "No config.sh found — nothing to destroy."
    exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE"

echo "This will destroy all six k3s VMs:"
echo "  ${PROXMOX_HOST1_NAME}-k3s / ${PROXMOX_HOST1_NAME}-k3s-test  (on ${PROXMOX_HOST1_NAME})"
echo "  ${PROXMOX_HOST2_NAME}-k3s / ${PROXMOX_HOST2_NAME}-k3s-test  (on ${PROXMOX_HOST2_NAME})"
echo "  ${PROXMOX_HOST3_NAME}-k3s / ${PROXMOX_HOST3_NAME}-k3s-test  (on ${PROXMOX_HOST3_NAME})"
echo
echo "The Proxmox cluster itself, and anything else on these 3 hosts, is untouched."
echo

if [[ -n "${UIS_DESTROY_CONFIRM:-}" ]]; then
    typed="$UIS_DESTROY_CONFIRM"
else
    read -r -p "Type 'proxmox' to confirm: " typed
fi

if [[ "$typed" != "proxmox" ]]; then
    print_error "Confirmation did not match 'proxmox' — aborting. Nothing was destroyed."
    exit 1
fi

SSH_OPTS=(-i "$PROXMOX_SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes)

destroy_vm() {
    local host="$1" addr="$2" vmid="$3" name="$4"
    if ssh "${SSH_OPTS[@]}" "root@${addr}" "qm status ${vmid}" >/dev/null 2>&1; then
        echo "Destroying ${name} (VMID ${vmid}) on ${host}..."
        ssh "${SSH_OPTS[@]}" "root@${addr}" "qm stop ${vmid} 2>/dev/null; qm destroy ${vmid} --purge 1"
    else
        print_warning "${name} (VMID ${vmid}) on ${host}: already gone"
    fi
}

destroy_vm "$PROXMOX_HOST1_NAME" "$PROXMOX_HOST1_ADDR" "$K3S_VM_HOST1_VMID"      "${PROXMOX_HOST1_NAME}-k3s"
destroy_vm "$PROXMOX_HOST1_NAME" "$PROXMOX_HOST1_ADDR" "$K3S_VM_HOST1_TEST_VMID" "${PROXMOX_HOST1_NAME}-k3s-test"
destroy_vm "$PROXMOX_HOST2_NAME" "$PROXMOX_HOST2_ADDR" "$K3S_VM_HOST2_VMID"      "${PROXMOX_HOST2_NAME}-k3s"
destroy_vm "$PROXMOX_HOST2_NAME" "$PROXMOX_HOST2_ADDR" "$K3S_VM_HOST2_TEST_VMID" "${PROXMOX_HOST2_NAME}-k3s-test"
destroy_vm "$PROXMOX_HOST3_NAME" "$PROXMOX_HOST3_ADDR" "$K3S_VM_HOST3_VMID"      "${PROXMOX_HOST3_NAME}-k3s"
destroy_vm "$PROXMOX_HOST3_NAME" "$PROXMOX_HOST3_ADDR" "$K3S_VM_HOST3_TEST_VMID" "${PROXMOX_HOST3_NAME}-k3s-test"

# Remove the contexts from the merged kubeconfig, if present, so `platform
# list` doesn't report a dead cluster as unreachable instead of destroyed.
if [[ -f /mnt/urbalurbadisk/provision-host/uis/lib/platform-switching.sh ]]; then
    # shellcheck source=/dev/null
    source /mnt/urbalurbadisk/provision-host/uis/lib/platform-switching.sh
    pf_remove_context "proxmox" || true
    pf_remove_context "proxmox-test" || true
fi

rm -f /mnt/urbalurbadisk/kubeconfig/proxmox-kubeconf /mnt/urbalurbadisk/kubeconfig/proxmox-test-kubeconf 2>/dev/null || true

print_success "All six VMs destroyed. config.sh is preserved — re-run ./uis platform up proxmox to rebuild."
