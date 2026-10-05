#!/bin/bash
# File: platforms/proxmox/scripts/05-core-services-apply.sh
#
# Description:
#   Phase 5 of the novice-lab-owner sequence: build every service in CORE_SERVICES as a Proxmox
#   LXC (not a k3s pod), replicate each to both other nodes, and register all of them under one
#   flat HA rule — every node an equal failover target, no hardware-strength ranking (see
#   PLAN-storage-cluster-005-core-services.md's "Design decisions"). Scripts stay thin; the real
#   work is in guest-ensure.yml / service-<name>.yml / replication-ensure.yml / ha-ensure.yml.
#
# Order, and why: each guest must exist before it can be replicated or HA-registered — that part
# is non-negotiable. The flat HA rule itself is cluster-wide and guest-independent, so it's
# created/updated once at the end, after every guest this run touches is already a member.
#
# Usage:
#   ./scripts/05-core-services-apply.sh

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
GENERATED="$ANSIBLE_DIR/generated"

print_section "PROXMOX — CORE SERVICES APPLY"

if [[ ! -f "$CONFIG_FILE" ]]; then
    print_error "No config.sh found at $CONFIG_FILE"
    exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE"

if [[ -z "${CORE_SERVICES// }" ]]; then
    print_warning "CORE_SERVICES is empty in config.sh — nothing to build. Exiting."
    exit 0
fi

print_status "Generating ansible config from config.sh..."
bash "$SCRIPT_DIR/generate-ansible-config.sh"

cd "$ANSIBLE_DIR"
PUBKEY="${PROXMOX_SSH_KEY}.pub"
ssh_h1() { ssh -i "$PROXMOX_SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "root@${PROXMOX_HOST1_ADDR}" "$@"; }

# ─── preflight: the two things every service below assumes ────────────────────────────────────
print_section "Preflight"

print_status "Confirming storage \"$PROXMOX_STORAGE\" is present on host1..."
ssh_h1 "pvesm status --storage ${PROXMOX_STORAGE}" >/dev/null
print_success "Storage present"

print_status "Confirming a watchdog is loaded on all 3 hosts (HA needs it for fencing)..."
for addr in "$PROXMOX_HOST1_ADDR" "$PROXMOX_HOST2_ADDR" "$PROXMOX_HOST3_ADDR"; do
    # 🔴 Checks for the /dev/watchdog DEVICE, not a module name — found running this for real:
    # Proxmox's own default driver is named "softdog", which does not contain the substring
    # "watchdog" at all. Checking for the device Proxmox's HA stack actually opens is robust to
    # whichever driver (software or hardware) provides it, unlike grepping for one module name.
    # 🔴 accept-new, matching ssh_h1 above — found running this for real against a genuinely
    # fresh known_hosts (a real new lab owner's first run): host1 only passed because ssh_h1's
    # call moments earlier happened to cache its key first; host2 had never been touched by
    # anything that accepts a new key, so it hit "Host key verification failed" outright.
    if ! ssh -i "$PROXMOX_SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "root@${addr}" "test -c /dev/watchdog"; then
        print_error "No /dev/watchdog on ${addr}. HA needs one so a node that loses quorum"
        echo "  reliably resets itself, rather than risking split-brain. softdog is the Proxmox"
        echo "  default when no hardware watchdog exists — 'modprobe softdog' and re-run."
        exit 1
    fi
done
print_success "Watchdog present on all 3 hosts"

# ─── the physical pool name, for guest-ensure.yml's zfs_recordsize task (pg only) ──────────────
POOL_NAME="${PROXMOX_STORAGE%-vm}"

# ─── per-service: guest -> install -> replicate to both other nodes -> HA member ───────────────
VMID_LIST=()
REGISTRY_IP=""
BAO_IP=""

for svc in $CORE_SERVICES; do
    decl="generated/vars/core-services/${svc}.yml"
    if [[ ! -f "$decl" ]]; then
        print_warning "No declaration for '$svc' (unknown service?) — skipped"
        continue
    fi
    vmid="$(grep -m1 '^  vmid:' "$decl" | awk '{print $2}')"
    VMID_LIST+=("$vmid")

    print_section "$svc (VMID $vmid)"

    print_status "guest-ensure..."
    ansible-playbook -i "${PROXMOX_HOST1_ADDR}," -u root --private-key "$PROXMOX_SSH_KEY" \
        playbooks/guest-ensure.yml \
        -e "guest_file=${decl}" -e "guest_pubkey=${PUBKEY}" -e "pool_name=${POOL_NAME}"

    print_status "Finding ${svc}'s guest IP..."
    guest_ip="$(ssh_h1 "pct exec ${vmid} -- hostname -I" | awk '{print $1}')"
    if [[ -z "$guest_ip" ]]; then
        print_error "Could not get an IP for ${svc} (VMID ${vmid}) — is it actually running?"
        exit 1
    fi
    # Same stale-host-key reasoning as 04-k3s-post-apply.sh: a rebuilt guest reuses the same
    # DHCP-leased address a previous incarnation may have had.
    ssh-keygen -f ~/.ssh/known_hosts -R "${guest_ip}" >/dev/null 2>&1 || true

    # 🔵 Captured here, dynamically — NEVER hardcoded — for the k3s-wiring step below, which only
    # runs at all if "registry" is actually in CORE_SERVICES (see after this loop).
    if [[ "$svc" == "registry" ]]; then
        REGISTRY_IP="$guest_ip"
    fi
    if [[ "$svc" == "bao" ]]; then
        BAO_IP="$guest_ip"
    fi

    print_status "service-${svc} (${guest_ip})..."
    extra_vars_file="generated/vars/core-services/_extra-vars.yml"
    ansible-playbook -i "${guest_ip}," -u root --private-key "$PROXMOX_SSH_KEY" \
        --ssh-common-args "-o StrictHostKeyChecking=accept-new" \
        -e "@${extra_vars_file}" \
        "playbooks/service-${svc}.yml" || {
        print_error "service-${svc} failed — see ansible output above."
        exit 1
    }
    print_success "$svc installed and verified"

    print_status "Replicating $svc to both other nodes..."
    ansible-playbook -i "${PROXMOX_HOST1_ADDR}," -u root --private-key "$PROXMOX_SSH_KEY" \
        playbooks/replication-ensure.yml -e "vmid=${vmid}" -e "target_node=${PROXMOX_HOST2_NAME}"
    ansible-playbook -i "${PROXMOX_HOST1_ADDR}," -u root --private-key "$PROXMOX_SSH_KEY" \
        playbooks/replication-ensure.yml -e "vmid=${vmid}" -e "target_node=${PROXMOX_HOST3_NAME}"

    print_status "Registering $svc as an HA member..."
    ansible-playbook -i "${PROXMOX_HOST1_ADDR}," -u root --private-key "$PROXMOX_SSH_KEY" \
        playbooks/ha-ensure.yml --tags member -e "vmid=${vmid}"

    print_success "$svc fully protected: replicated + HA-registered"
done

# ─── wire k3s to the registry cache, ONLY if the lab owner selected it ─────────────────────────
# 🔵 A CLEAR, CONDITIONAL STEP — not something every lab owner's cluster silently gets. A lab
# owner who never puts "registry" in CORE_SERVICES never has k3s-registry-ensure.yml run against
# them at all; their k3s nodes behave exactly as before. See that playbook for why a restart is
# required and why registry_port/registry_upstreams are read from the registry role's own
# defaults rather than duplicated here.
if [[ -n "$REGISTRY_IP" ]]; then
    print_section "Wire k3s to the registry cache"
    print_status "Rendering registries.yaml on every k3s node (both clusters) via ${REGISTRY_IP}..."
    ansible-playbook -i generated/inventory.yml --limit guests \
        playbooks/k3s-registry-ensure.yml -e "registry_host=${REGISTRY_IP}"
    print_success "Every k3s node now mirrors every registry upstream through ${REGISTRY_IP}"
fi

# ─── wire ESO + a ClusterSecretStore to bao, ONLY if the lab owner selected it ─────────────────
# 🔵 Same conditional shape as the registry wiring above — a lab owner who never puts "bao" in
# CORE_SERVICES never has either playbook below run at all; their k3s clusters are untouched.
#
# 🔵 PRODUCTION GETS THE REAL THING; TEST GETS THE SIMPLE ONE (Terje, 2026-10-05). "proxmox" is
# wired to the real vault-backed store (k3s-bao-ensure.yml — see that file for why each cluster
# needs its own auth mount and why the root token never leaves the bao guest). "proxmox-test"
# gets the SAME ClusterSecretStore name, backed by a plain Kubernetes Secret instead
# (k3s-bao-simple-ensure.yml) — no vault auth, no bidirectional TokenReview, far less to go wrong
# for a tier that doesn't need real vault semantics. Upgrade proxmox-test to the real thing later,
# on demand, with ./scripts/upgrade-test-cluster-to-bao.sh — it never runs automatically.
if [[ -n "$BAO_IP" ]]; then
    print_section "Wire ESO + a ClusterSecretStore to bao"

    print_status "Production (proxmox): the real vault-backed store, via ${BAO_IP}..."
    ansible-playbook -i "${BAO_IP}," -u root --private-key "$PROXMOX_SSH_KEY" \
        --ssh-common-args "-o StrictHostKeyChecking=accept-new" \
        playbooks/k3s-bao-ensure.yml -e "bao_host=${BAO_IP}" -e 'target_contexts=["proxmox"]'
    print_success "ClusterSecretStore 'openbao' is Ready on proxmox, proven end to end"

    print_status "Test (proxmox-test): the simple plain-Secret-backed store..."
    ansible-playbook playbooks/k3s-bao-simple-ensure.yml -e 'target_contexts=["proxmox-test"]'
    print_success "ClusterSecretStore 'openbao' is Ready on proxmox-test (plain Secret, no vault)"
fi

# ─── the one flat rule, naming every node + every service this run touched ─────────────────────
if [[ "${#VMID_LIST[@]}" -gt 0 ]]; then
    print_section "Flat HA rule — every node an equal target"
    RESOURCES="$(printf 'ct:%s,' "${VMID_LIST[@]}")"
    RESOURCES="${RESOURCES%,}"
    NODES="${PROXMOX_HOST1_NAME},${PROXMOX_HOST2_NAME},${PROXMOX_HOST3_NAME}"
    ansible-playbook -i "${PROXMOX_HOST1_ADDR}," -u root --private-key "$PROXMOX_SSH_KEY" \
        playbooks/ha-ensure.yml --tags rule -e "resources=${RESOURCES}" -e "nodes=${NODES}"
fi

print_section "CORE SERVICES APPLY COMPLETE"
echo "Built: ${CORE_SERVICES}"
echo "Each is replicated to both other nodes and HA-registered under one flat rule."
echo
echo "Prove it: power off a node and watch 'ha-manager status' move its guests elsewhere —"
echo "a real test, not inferred from configuration existing."
