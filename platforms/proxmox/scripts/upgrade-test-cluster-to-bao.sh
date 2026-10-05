#!/bin/bash
# File: platforms/proxmox/scripts/upgrade-test-cluster-to-bao.sh
#
# Description:
#   Upgrades the TEST cluster (proxmox-test) from the simple, plain-Kubernetes-Secret-backed
#   ClusterSecretStore it gets by default to the REAL vault-backed one production uses.
#
#   🔵 WHY THIS IS A SEPARATE SCRIPT, NEVER RUN AUTOMATICALLY (Terje, 2026-10-05): a test/dev tier
#   doesn't need real vault semantics by default — only the SAME `ExternalSecret` interface a
#   workload also sees in production, which it already has (see k3s-bao-simple-ensure.yml). This
#   script exists for the moment you DO want to exercise the real thing on the test cluster first
#   — e.g. proving a vault policy or role change before it touches production — without making
#   that the default for every lab owner who never needs it.
#
#   It overwrites the SAME ClusterSecretStore name ("openbao"), so any ExternalSecret already
#   pointed at it keeps working untouched — only what answers underneath changes.
#
# Usage:
#   ./scripts/upgrade-test-cluster-to-bao.sh

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
print_status()  { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
print_section() { echo; echo -e "${GREEN}========================================${NC}"; echo -e "${GREEN}$1${NC}"; echo -e "${GREEN}========================================${NC}"; echo; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ANSIBLE_DIR="$PLATFORM_DIR/ansible"
CONFIG_FILE="$PLATFORM_DIR/config.sh"

print_section "Upgrade proxmox-test to the real bao-backed secret store"

if [[ ! -f "$CONFIG_FILE" ]]; then
    print_error "No config.sh found at $CONFIG_FILE"
    exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE"

if [[ " $CORE_SERVICES " != *" bao "* ]]; then
    print_error "\"bao\" is not in CORE_SERVICES — there is no bao guest to point this cluster at."
    echo "  Add \"bao\" to CORE_SERVICES in config.sh and run ./scripts/05-core-services-apply.sh first."
    exit 1
fi

cd "$ANSIBLE_DIR"
ssh_h1() { ssh -i "$PROXMOX_SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "root@${PROXMOX_HOST1_ADDR}" "$@"; }

print_status "Finding bao's guest IP..."
BAO_VMID="$(grep -m1 '^  vmid:' "$ANSIBLE_DIR/generated/vars/core-services/bao.yml" | awk '{print $2}')"
BAO_IP="$(ssh_h1 "pct exec ${BAO_VMID} -- hostname -I" | awk '{print $1}')"
if [[ -z "$BAO_IP" ]]; then
    print_error "Could not get an IP for bao (VMID ${BAO_VMID}) — is it actually running?"
    exit 1
fi

print_status "Wiring proxmox-test to the real bao instance via ${BAO_IP}..."
ansible-playbook -i "${BAO_IP}," -u root --private-key "$PROXMOX_SSH_KEY" \
    --ssh-common-args "-o StrictHostKeyChecking=accept-new" \
    playbooks/k3s-bao-ensure.yml -e "bao_host=${BAO_IP}" -e 'target_contexts=["proxmox-test"]'

print_success "proxmox-test now uses the real vault-backed 'openbao' store, proven end to end."
echo "  Existing ExternalSecrets on that cluster keep working untouched — only the backend changed."
