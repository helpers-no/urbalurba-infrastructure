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

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
print_status()  { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
print_section() { echo; echo -e "${GREEN}========================================${NC}"; echo -e "${GREEN}$1${NC}"; echo -e "${GREEN}========================================${NC}"; echo; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# config.sh is per-install REAL STATE (host addresses, VMIDs, which services are
# selected) -- it must survive a container restart/uis-pull the same way every
# other platform's own persistent config already does (platform-switching.sh's
# PF_CLUSTER_CONFIG, azure-aks's own .uis.secrets/cloud-accounts/azure-default.env).
# platforms/proxmox/ itself is part of the container's image layer, not a
# persistent mount -- a config.sh written there silently vanishes on the next
# pull (urb-agents#1935, found running `uis platform init proxmox` for real,
# against a live lab, for the first time).
REPO_ROOT="${UIS_REPO_ROOT:-$(cd "$PLATFORM_DIR/../.." && pwd)}"
ANSIBLE_DIR="$PLATFORM_DIR/ansible"
CONFIG_FILE="$REPO_ROOT/.uis.secrets/platforms/proxmox/config.sh"

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
ssh_node() { local addr="$1"; shift; ssh -i "$PROXMOX_SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "root@${addr}" "$@"; }

# 🔴 Same node-locality bug as 05-core-services-apply.sh (urb-agents#1937): `pct exec` only ever
# looks under the node it's run ON, and bao is HA-managed, so it may not be on host1 by the time
# this script runs. `pvesh` IS cluster-aware (asked of host1, answered for the whole cluster).
declare -A NODE_ADDR=(
    ["$PROXMOX_HOST1_NAME"]="$PROXMOX_HOST1_ADDR"
    ["$PROXMOX_HOST2_NAME"]="$PROXMOX_HOST2_ADDR"
    ["$PROXMOX_HOST3_NAME"]="$PROXMOX_HOST3_ADDR"
)
# $2 (optional) is the service name this vmid is EXPECTED to be — warned on a mismatch, not
# asserted (urb-agents#1940: a hardcoded VMID can collide with an unrelated real guest; a hard
# refusal would also be wrong for a guest legitimately adopted under a different name).
guest_node() {
    local vmid="$1" expected_name="${2:-}" node name cluster_json
    cluster_json="$(ssh_h1 "pvesh get /cluster/resources --type vm --output-format json")"
    node="$(echo "$cluster_json" | jq -r --arg vmid "$vmid" '.[] | select((.vmid|tostring)==$vmid) | .node')"
    if [[ -z "$node" ]]; then
        print_error "VMID ${vmid} is not reported anywhere in the cluster (pvesh /cluster/resources) — is it actually running?"
        exit 1
    fi
    if [[ -n "$expected_name" ]]; then
        name="$(echo "$cluster_json" | jq -r --arg vmid "$vmid" '.[] | select((.vmid|tostring)==$vmid) | .name')"
        if [[ -n "$name" && "$name" != "$expected_name" ]]; then
            # >&2 — this function's stdout is captured by the caller; the warning must still
            # reach the terminal rather than get folded into the captured node name.
            print_warning "VMID ${vmid} exists but is named '${name}', not '${expected_name}' — this usually means the VMID collides with an UNRELATED guest, not ${expected_name}. Double-check before trusting anything derived from it. If ${expected_name}'s real VMID differs, override it via config.sh's CORE_SERVICE_*_VMID." >&2
        fi
    fi
    if [[ -z "${NODE_ADDR[$node]:-}" ]]; then
        print_error "VMID ${vmid} is on node '${node}', which is none of PROXMOX_HOST{1,2,3}_NAME in config.sh."
        exit 1
    fi
    echo "$node"
}

print_status "Finding which node bao's guest actually lives on..."
BAO_VMID="$(grep -m1 '^  vmid:' "$ANSIBLE_DIR/generated/vars/core-services/bao.yml" | awk '{print $2}')"
BAO_NODE_NAME="$(guest_node "$BAO_VMID" bao)"
BAO_NODE_ADDR="${NODE_ADDR[$BAO_NODE_NAME]}"

print_status "Finding bao's guest IP (via ${BAO_NODE_NAME})..."
BAO_IP="$(ssh_node "$BAO_NODE_ADDR" "pct exec ${BAO_VMID} -- hostname -I" | awk '{print $1}')"
if [[ -z "$BAO_IP" ]]; then
    print_error "Could not get an IP for bao (VMID ${BAO_VMID}) on ${BAO_NODE_NAME} — is it actually running?"
    exit 1
fi

print_status "Wiring proxmox-test to the real bao instance via ${BAO_IP}..."
# 🔴 `-e target_contexts=[...]` (key=value CLI form with inline JSON) is NOT parsed as a list by
# this ansible-core version (urb-agents#1938) — it comes through as a plain STRING, and `loop:
# "{{ target_contexts }}"` refuses outright. The whole `-e` argument has to BE one JSON object.
ansible-playbook -i "${BAO_IP}," -u root --private-key "$PROXMOX_SSH_KEY" \
    --ssh-common-args "-o StrictHostKeyChecking=accept-new" \
    playbooks/k3s-bao-ensure.yml -e "bao_host=${BAO_IP}" -e '{"target_contexts": ["proxmox-test"]}'

print_success "proxmox-test now uses the real vault-backed 'openbao' store, proven end to end."
echo "  Existing ExternalSecrets on that cluster keep working untouched — only the backend changed."
