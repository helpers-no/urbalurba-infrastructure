#!/bin/bash
# File: platforms/proxmox/scripts/01-cluster-join.sh
#
# Description:
#   Phase 3 of the novice-lab-owner sequence: join the 3 configured hosts into one Proxmox
#   cluster. host1 creates it (`pvecm create` — local-only, no remote auth, fully automated);
#   host2 and host3 each join through host1 (`pvecm add` — Proxmox API auth with the TARGET's
#   root password, typed interactively; no wrapper removes that, see cluster-join.yml's own
#   comments). This script collapses what the maintainer's private-lab original needed as two
#   separate `ansible-playbook` invocations with a human typing a command in between into one
#   call: preflight checks → an interactive `ssh -t ... pvecm add` (the human types into a real
#   pty this script holds open, nothing captured or scripted around) → verify.
#
# Usage:
#   ./scripts/01-cluster-join.sh

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
PLAYBOOK="$PLATFORM_DIR/ansible/playbooks/cluster-join.yml"

print_section "PROXMOX — CLUSTER JOIN"

if [[ ! -f "$CONFIG_FILE" ]]; then
    print_error "No config.sh found at $CONFIG_FILE"
    exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE"

PUBKEY="${PROXMOX_SSH_KEY}.pub"
ssh_h1() { ssh -i "$PROXMOX_SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "root@${PROXMOX_HOST1_ADDR}" "$@"; }

# ─── already clustered? idempotent, not an error ──────────────────────────────────────────────
if ssh_h1 "test -f /etc/pve/corosync.conf"; then
    print_status "Checking existing cluster quorum..."
    status="$(ssh_h1 pvecm status)"
    if echo "$status" | grep -q "Quorate:[[:space:]]*Yes"; then
        print_success "Already clustered and quorate — nothing to do."
        echo "$status" | sed 's/^/  /'
        exit 0
    else
        print_error "$PROXMOX_HOST1_NAME has a cluster config but is NOT quorate. Investigate"
        echo "  by hand before continuing — this script won't guess what's wrong:"
        echo "$status" | sed 's/^/  /'
        exit 1
    fi
fi

# ─── host1 creates the cluster — local-only, no remote auth needed, fully automated ───────────
print_section "1/3 — $PROXMOX_HOST1_NAME creates the cluster \"$PROXMOX_CLUSTER_NAME\""
ssh_h1 "pvecm create ${PROXMOX_CLUSTER_NAME}"
print_success "Cluster created on $PROXMOX_HOST1_NAME"

# ─── host2 and host3 each join through host1 ──────────────────────────────────────────────────
declare -a JOIN_NAMES=("$PROXMOX_HOST2_NAME" "$PROXMOX_HOST3_NAME")
declare -a JOIN_ADDRS=("$PROXMOX_HOST2_ADDR" "$PROXMOX_HOST3_ADDR")

for i in 0 1; do
    name="${JOIN_NAMES[$i]}"; addr="${JOIN_ADDRS[$i]}"
    print_section "$((i + 2))/3 — $name joins via $PROXMOX_HOST1_NAME"

    print_status "Preflight checks on $name..."
    ansible-playbook -i "${addr}," -u root --private-key "$PROXMOX_SSH_KEY" "$PLAYBOOK" \
        -e "join_via=${PROXMOX_HOST1_ADDR}" -e "control_pubkey_file=${PUBKEY}" --tags preflight

    echo
    print_warning "Your turn: type ${name}'s ROOT PASSWORD when asked, then the literal word \"yes\""
    echo "  at the fingerprint prompt (not just \"y\" — that fails it with no retry)."
    echo

    # 🔵 -t forces a real pty, so the password and fingerprint prompts come through live and you
    # type into them exactly as if you'd run this yourself — nothing here is scripted around it.
    if ! ssh -t -i "$PROXMOX_SSH_KEY" -o StrictHostKeyChecking=accept-new "root@${addr}" \
            "pvecm add ${PROXMOX_HOST1_ADDR}"; then
        print_error "pvecm add failed or was aborted for $name. Fix it by hand, then re-run this"
        echo "  script — it will see the cluster already exists on $PROXMOX_HOST1_NAME and resume"
        echo "  from here."
        exit 1
    fi

    print_status "Verifying $name joined correctly..."
    ansible-playbook -i "${addr}," -u root --private-key "$PROXMOX_SSH_KEY" "$PLAYBOOK" \
        -e "join_via=${PROXMOX_HOST1_ADDR}" -e "control_pubkey_file=${PUBKEY}" --tags verify
    print_success "$name joined and verified"
done

print_section "CLUSTER JOIN COMPLETE"
echo "All 3 hosts are one quorate Proxmox cluster."
echo "Next: ./uis platform up proxmox"
