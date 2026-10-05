#!/bin/bash
# File: platforms/proxmox/scripts/04-k3s-post-apply.sh
#
# Description:
#   Post-apply cluster configuration, for BOTH the production and mirror-test
#   clusters:
#     1. Fetch each cluster's kubeconfig from its init node, fix it up, merge
#        into the unified kubeconf-all
#     2. Install Traefik via the shared UIS playbook (it already auto-detects
#        k3s's own bundled Traefik and skips the Helm install — same as it
#        does for rancher-desktop, which also runs k3s)
#     3. Flip UIS's active target to the production cluster
#     4. Validate and report
#
# Prerequisites:
#   - scripts/03-k3s-apply.sh completed successfully
#
# Usage:
#   ./scripts/04-k3s-post-apply.sh

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
print_status()  { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
print_section() { echo; echo -e "${GREEN}========================================${NC}"; echo -e "${GREEN}$1${NC}"; echo -e "${GREEN}========================================${NC}"; echo; }

# ─── Environment check ────────────────────────────────────────────────────
if [[ ! -f /.dockerenv ]] || [[ ! -d /mnt/urbalurbadisk ]]; then
    print_error "This script must run inside the provision-host container"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$PLATFORM_DIR/config.sh"

if [[ ! -f "$CONFIG_FILE" ]]; then
    print_error "No config.sh found — run ./scripts/02-k3s-preflight.sh first."
    exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE"

KUBECONFIG_DIR="/mnt/urbalurbadisk/kubeconfig"
mkdir -p "$KUBECONFIG_DIR"

print_section "PROXMOX-K3S — POST-APPLY SETUP"

# ─── Step 1: fetch + fix up + write each cluster's kubeconfig ─────────────
# k3s's own kubeconfig always names everything "default" (cluster/user/
# context) and points at 127.0.0.1 — fine for a single node talking to
# itself, useless once merged with anything else. Fix both before this ever
# reaches the shared merge playbook (which only knows how to rewrite
# MicroK8s's generic names, not k3s's — see this platform's PR description).
write_kubeconf() {
    local cluster_name="$1" init_ip="$2" dest="$3"
    local raw
    # 🔴 Same address, new host key, every rebuild — this platform's whole design is destroy +
    # recreate VMs at fixed IPs, so a known_hosts entry from the PREVIOUS incarnation at this
    # address is the routine case, not an anomaly. StrictHostKeyChecking=accept-new only accepts
    # addresses never seen before; it correctly still refuses a CHANGED key for one it has. Scrub
    # first — same precaution vm-ensure.yml already takes for the same reason.
    ssh-keygen -f ~/.ssh/known_hosts -R "${init_ip}" >/dev/null 2>&1 || true
    raw="$(ssh -i "$PROXMOX_SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
        "${VM_CIUSER}@${init_ip}" sudo cat /etc/rancher/k3s/k3s.yaml)"
    echo "$raw" \
        | sed -e "s/127\.0\.0\.1/${init_ip}/" \
              -e "s/name: default/name: ${cluster_name}/g" \
              -e "s/cluster: default/cluster: ${cluster_name}/" \
              -e "s/user: default/user: ${cluster_name}/" \
              -e "s/current-context: default/current-context: ${cluster_name}/" \
        > "$dest"
    chmod 600 "$dest"
}

print_section "Step 1: kubeconfigs"

PROD_CLUSTER_NAME="proxmox"
TEST_CLUSTER_NAME="proxmox-test"

print_status "Production ($PROD_CLUSTER_NAME, via ${K3S_VM_HOST1_IP})..."
write_kubeconf "$PROD_CLUSTER_NAME" "$K3S_VM_HOST1_IP" "${KUBECONFIG_DIR}/${PROD_CLUSTER_NAME}-kubeconf"
print_success "Written: ${PROD_CLUSTER_NAME}-kubeconf"

print_status "Test ($TEST_CLUSTER_NAME, via ${K3S_VM_HOST1_TEST_IP})..."
write_kubeconf "$TEST_CLUSTER_NAME" "$K3S_VM_HOST1_TEST_IP" "${KUBECONFIG_DIR}/${TEST_CLUSTER_NAME}-kubeconf"
print_success "Written: ${TEST_CLUSTER_NAME}-kubeconf"

# Seed rancher-desktop into the merge first, same reason AKS's post-apply
# does — without it, a kubeconf-all built here can end up containing only
# this platform's clusters, and `platform use rancher-desktop` afterward
# fails with "not initialized".
# shellcheck source=/dev/null
source /mnt/urbalurbadisk/provision-host/uis/lib/platform-switching.sh
pf_ensure_kubeconf_seeded

ANSIBLE_PLAYBOOK="/mnt/urbalurbadisk/ansible/playbooks/04-merge-kubeconf.yml"
if [[ -f "$ANSIBLE_PLAYBOOK" ]]; then
    cd /mnt/urbalurbadisk
    ansible-playbook "$ANSIBLE_PLAYBOOK"
    print_success "Kubeconfig merged via the shared UIS playbook"
else
    print_warning "Shared merge playbook not found at $ANSIBLE_PLAYBOOK — leaving per-cluster files as-is"
fi

MERGED_KUBECONFIG="${KUBECONFIG_DIR}/kubeconf-all"
export KUBECONFIG="$MERGED_KUBECONFIG"

# ─── Step 2: verify both clusters answer ──────────────────────────────────
print_section "Step 2: verify both clusters"

for ctx in "$PROD_CLUSTER_NAME" "$TEST_CLUSTER_NAME"; do
    count="$(kubectl --context "$ctx" get nodes --no-headers 2>/dev/null | wc -l)"
    if [[ "$count" -eq 0 ]]; then
        print_error "$ctx: no nodes found"
        exit 1
    fi
    print_success "$ctx: $count node(s) ready"
done

# ─── Step 3: Traefik, on both clusters ────────────────────────────────────
# ansible/playbooks/003-setup-traefik.yml already detects k3s's own bundled
# Traefik (via its HelmChart CR) and skips the Helm install when found — the
# same thing it already does for rancher-desktop, which also runs k3s. No
# special handling needed here; this just calls the same shared playbook
# every other platform uses.
print_section "Step 3: Traefik"

for ctx in "$PROD_CLUSTER_NAME" "$TEST_CLUSTER_NAME"; do
    print_status "Checking Traefik on $ctx..."
    ansible-playbook /mnt/urbalurbadisk/ansible/playbooks/003-setup-traefik.yml \
        -e "target_host=$ctx"
done
print_success "Traefik confirmed on both clusters"

# ─── Step 4: point UIS at the production cluster ──────────────────────────
print_section "Step 4: switch UIS target to the production cluster"

pf_lockstep_flip "$PROD_CLUSTER_NAME"
print_success "cluster-config.sh + kubectl context flipped to: $PROD_CLUSTER_NAME"
echo "  (Use './uis platform use rancher-desktop' to switch back,"
echo "   or 'kubectl config use-context $TEST_CLUSTER_NAME' for the test cluster.)"

# ─── Summary ───────────────────────────────────────────────────────────────
print_section "POST-APPLY COMPLETE — BOTH CLUSTERS READY"

echo "Production: $PROD_CLUSTER_NAME — $(kubectl --context "$PROD_CLUSTER_NAME" get nodes --no-headers | wc -l) node(s)"
echo "Test:       $TEST_CLUSTER_NAME — $(kubectl --context "$TEST_CLUSTER_NAME" get nodes --no-headers | wc -l) node(s)"
echo
echo "Deploy services (to whichever is the active target — production, right now):"
echo "  ./uis deploy nginx"
echo
echo "Context switching:"
echo "  kubectl config use-context $PROD_CLUSTER_NAME"
echo "  kubectl config use-context $TEST_CLUSTER_NAME"
echo
echo "Manage:"
echo "  ./uis platform status proxmox"
echo "  ./uis platform down   proxmox"
