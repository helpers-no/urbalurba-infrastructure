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
#   ./scripts/05-core-services-apply.sh              # every service in CORE_SERVICES
#   ./scripts/05-core-services-apply.sh forgejo       # just this one (e.g. called by
#                                                      # scripts/07-core-service-add.sh after
#                                                      # appending it to config.sh, so adding one
#                                                      # service doesn't re-touch every other
#                                                      # already-built guest)

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

# An explicit arg scopes the per-service loop below to just that one service — used by
# scripts/07-core-service-add.sh, which appends the new service to config.sh's CORE_SERVICES
# (so generate-ansible-config.sh below still regenerates every current declaration, cheap and
# harmless) but only wants THIS run to touch the one service being added, not re-run
# service-<name>.yml/replication-ensure.yml/ha-ensure.yml against every already-built guest too.
# Validated against the real CORE_SERVICES list, not trusted blind — a typo here should fail
# loudly, the same "unknown service, skipped" the per-service loop already does for config.sh's
# own list, not silently build nothing.
TARGET_SERVICES="${1:-$CORE_SERVICES}"
if [[ -n "${1:-}" ]]; then
    _found=0
    for _svc in $CORE_SERVICES; do
        [[ "$_svc" == "$1" ]] && _found=1 && break
    done
    if [[ "$_found" -eq 0 ]]; then
        print_error "'$1' is not in config.sh's CORE_SERVICES ($CORE_SERVICES) — add it there first."
        exit 1
    fi
fi

print_status "Generating ansible config from config.sh..."
bash "$SCRIPT_DIR/generate-ansible-config.sh"

cd "$ANSIBLE_DIR"
PUBKEY="${PROXMOX_SSH_KEY}.pub"
ssh_h1() { ssh -i "$PROXMOX_SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "root@${PROXMOX_HOST1_ADDR}" "$@"; }
ssh_node() { local addr="$1"; shift; ssh -i "$PROXMOX_SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "root@${addr}" "$@"; }

# 🔴 `pct`/`pvesr` ARE NODE-LOCAL COMMANDS — unlike `ha-manager`/`pvesh`, which are cluster-aware
# because their state lives in /etc/pve (synced to every node by pmxcfs). `pct exec`/`pct config`
# only ever look under THIS node's own `/etc/pve/nodes/<this-node>/lxc/<vmid>.conf`, never another
# node's, and `pvesr create-local-job` creates a job SOURCED FROM wherever it runs. Every core
# service here is HA-managed (urb-agents#1936/#1937) — HA relocating a guest off whichever node
# generate-ansible-config.sh happened to declare for it is the NORMAL state, not an edge case.
# Confirmed live, urb-agents#1937: `pct exec` against host1 for a guest HA-placed on another node
# failed with "Configuration file 'nodes/<host1>/lxc/<vmid>.conf' does not exist" — guest-ensure.yml
# itself was already fixed (#596) to recognize the guest exists and stop creating a duplicate, but
# every step AFTER that in this script still assumed host1 was where the guest actually lives.
declare -A NODE_ADDR=(
    ["$PROXMOX_HOST1_NAME"]="$PROXMOX_HOST1_ADDR"
    ["$PROXMOX_HOST2_NAME"]="$PROXMOX_HOST2_ADDR"
    ["$PROXMOX_HOST3_NAME"]="$PROXMOX_HOST3_ADDR"
)
# Which node actually holds this vmid right now, cluster-wide — not which one generate-ansible-
# config.sh declared for it. pvesh is cluster-aware, so asking host1 is enough regardless of where
# the guest itself lives.
guest_node() {
    local vmid="$1" node
    node="$(ssh_h1 "pvesh get /cluster/resources --type vm --output-format json" \
        | jq -r --arg vmid "$vmid" '.[] | select((.vmid|tostring)==$vmid) | .node')"
    if [[ -z "$node" ]]; then
        print_error "VMID ${vmid} is not reported anywhere in the cluster (pvesh /cluster/resources) — is it actually running?"
        exit 1
    fi
    if [[ -z "${NODE_ADDR[$node]:-}" ]]; then
        print_error "VMID ${vmid} is on node '${node}', which is none of PROXMOX_HOST{1,2,3}_NAME in config.sh."
        exit 1
    fi
    echo "$node"
}

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
FORGEJO_IP=""

for svc in $TARGET_SERVICES; do
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

    print_status "Finding which node ${svc}'s guest actually lives on..."
    guest_node_name="$(guest_node "$vmid")"
    guest_node_addr="${NODE_ADDR[$guest_node_name]}"
    if [[ "$guest_node_name" != "$PROXMOX_HOST1_NAME" ]]; then
        print_warning "VMID ${vmid} is on '${guest_node_name}', not host1 — HA relocated it since it was declared."
    fi

    print_status "Finding ${svc}'s guest IP (via ${guest_node_name})..."
    guest_ip="$(ssh_node "$guest_node_addr" "pct exec ${vmid} -- hostname -I" | awk '{print $1}')"
    if [[ -z "$guest_ip" ]]; then
        print_error "Could not get an IP for ${svc} (VMID ${vmid}) on ${guest_node_name} — is it actually running?"
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
    if [[ "$svc" == "forgejo" ]]; then
        FORGEJO_IP="$guest_ip"
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
    # 🔴 "local" job — must run ON THE NODE THAT ACTUALLY HOLDS THE GUEST (replication-ensure.yml's
    # own header), and "both other nodes" means every PROXMOX_HOST*_NAME except wherever the guest
    # actually is, not host2+host3 unconditionally (that would try to replicate host1 -> host1 if
    # HA had relocated this guest there).
    for target_name in "$PROXMOX_HOST1_NAME" "$PROXMOX_HOST2_NAME" "$PROXMOX_HOST3_NAME"; do
        [[ "$target_name" == "$guest_node_name" ]] && continue
        ansible-playbook -i "${guest_node_addr}," -u root --private-key "$PROXMOX_SSH_KEY" \
            playbooks/replication-ensure.yml -e "vmid=${vmid}" -e "target_node=${target_name}"
    done

    print_status "Registering $svc as an HA member..."
    ansible-playbook -i "${PROXMOX_HOST1_ADDR}," -u root --private-key "$PROXMOX_SSH_KEY" \
        playbooks/ha-ensure.yml --tags member -e "vmid=${vmid}"

    print_success "$svc fully protected: replicated + HA-registered"
done

# ─── fill in IPs for registry/forgejo if THIS run didn't touch them but config.sh still has ────
# ─── them (a scoped single-service run — see TARGET_SERVICES above) ────────────────────────────
# 🔴 WITHOUT THIS, A SCOPED "add forgejo" RUN WOULD WRONGLY REFUSE registries.yaml's EXISTING
# registry ENTRY. k3s-registry-ensure.yml writes the WHOLE file every run and refuses on any
# domain it doesn't recognize from THIS run's own inputs — if "registry" is already configured
# from an earlier run but wasn't in TARGET_SERVICES this time, REGISTRY_IP would stay empty here,
# the playbook would be told nothing about it, and it would refuse citing registry's own
# already-legitimate entry as unrecognized. Looking it up directly (not re-running guest-ensure/
# service-install/replicate/ha for it — already done, that's the whole point of scoping) keeps
# every run's picture of "what k3s should trust" complete, regardless of what this particular run
# was scoped to touch.
_core_services_has() {
    local want="$1" _s
    for _s in $CORE_SERVICES; do [[ "$_s" == "$want" ]] && return 0; done
    return 1
}

if [[ -z "$REGISTRY_IP" ]] && _core_services_has registry && [[ -f "generated/vars/core-services/registry.yml" ]]; then
    _vmid="$(grep -m1 '^  vmid:' "generated/vars/core-services/registry.yml" | awk '{print $2}')"
    _node_name="$(guest_node "$_vmid" 2>/dev/null)" && REGISTRY_IP="$(ssh_node "${NODE_ADDR[$_node_name]}" "pct exec ${_vmid} -- hostname -I" 2>/dev/null | awk '{print $1}')"
fi
if [[ -z "$FORGEJO_IP" ]] && _core_services_has forgejo && [[ -f "generated/vars/core-services/forgejo.yml" ]]; then
    _vmid="$(grep -m1 '^  vmid:' "generated/vars/core-services/forgejo.yml" | awk '{print $2}')"
    _node_name="$(guest_node "$_vmid" 2>/dev/null)" && FORGEJO_IP="$(ssh_node "${NODE_ADDR[$_node_name]}" "pct exec ${_vmid} -- hostname -I" 2>/dev/null | awk '{print $1}')"
fi

# ─── wire k3s registry trust, ONLY if the lab owner selected a service that needs it ────────────
# 🔵 A CLEAR, CONDITIONAL STEP — not something every lab owner's cluster silently gets. A lab
# owner who selects neither "registry" nor "forgejo" never has k3s-registry-ensure.yml run against
# them at all; their k3s nodes behave exactly as before.
#
# 🔴 ONE COMBINED INVOCATION, NOT TWO — this is the composition INVESTIGATE-system-registry-cache
# Part 5 calls for. k3s-registry-ensure.yml writes the WHOLE registries.yaml file every run; if
# "registry" and "forgejo" each triggered their own separate ansible-playbook call against that
# same file, the second call would — thanks to the refuse-on-unrecognized-domain guard the
# playbook now has — actually REFUSE outright rather than silently clobbering the first (that
# guard exists precisely to turn a silent data-loss bug into a loud, early one) but the fix is
# still to never put the playbook in that position: both mechanisms' desired state is assembled
# here, in bash, and handed to ONE playbook run.
#
# See that playbook for why a restart is required and why registry_port/registry_upstreams are
# read from the registry role's own defaults rather than duplicated here.
if [[ -n "$REGISTRY_IP" || -n "$FORGEJO_IP" ]]; then
    print_section "Wire k3s registry trust"

    k3s_registry_ensure_args=(-i generated/inventory.yml --limit guests playbooks/k3s-registry-ensure.yml)

    if [[ -n "$REGISTRY_IP" ]]; then
        print_status "Zot pull-through cache: every k3s node (both clusters) via ${REGISTRY_IP}..."
        k3s_registry_ensure_args+=(-e "registry_host=${REGISTRY_IP}")
    fi

    if [[ -n "$FORGEJO_IP" ]]; then
        # 🔵 SINGLE SOURCE OF TRUTH: the port comes from roles/forgejo/defaults/main.yml's
        # forgejo_http_port — Forgejo serves its registry on the same port as everything else, so
        # this must never drift from what service-forgejo.yml actually configured.
        forgejo_port="$(grep -m1 '^forgejo_http_port:' roles/forgejo/defaults/main.yml | awk '{print $2}')"
        print_status "Forgejo's own registry: direct insecure trust via ${FORGEJO_IP}:${forgejo_port}..."
        # 🔴 `-e key=[...]`/`-e key={...}` (key=value CLI form with inline JSON) is NOT parsed as a
        # nested structure by this ansible-core version — confirmed live, urb-agents#1938: it comes
        # through as a plain STRING, and `registry_direct_insecure | map(attribute='domain')` then
        # iterates the string's own characters, raising "'str object' has no attribute 'domain'" on
        # the first one. The whole `-e` argument has to BE one JSON object instead (`-e '{"key":
        # ...}'`), which ansible always parses correctly regardless of key=value quirks.
        k3s_registry_ensure_args+=(-e "{\"registry_direct_insecure\": [{\"domain\": \"${FORGEJO_IP}:${forgejo_port}\", \"endpoint\": \"${FORGEJO_IP}:${forgejo_port}\"}]}")
    fi

    ansible-playbook "${k3s_registry_ensure_args[@]}"
    print_success "Every k3s node now trusts every registry this run configured"
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
    # 🔴 `-e target_contexts=[...]` (key=value CLI form with inline JSON) is NOT parsed as a list by
    # this ansible-core version — same bug class as registry_direct_insecure above (urb-agents#1938),
    # found reading this file afterward rather than live: it comes through as a plain STRING, and
    # `loop: "{{ target_contexts }}"` refuses outright ("The `loop` value must resolve to a 'list',
    # not 'str'"). The whole `-e` argument has to BE one JSON object (`-e '{"key": [...]}'`).
    ansible-playbook -i "${BAO_IP}," -u root --private-key "$PROXMOX_SSH_KEY" \
        --ssh-common-args "-o StrictHostKeyChecking=accept-new" \
        playbooks/k3s-bao-ensure.yml -e "bao_host=${BAO_IP}" -e '{"target_contexts": ["proxmox"]}'
    print_success "ClusterSecretStore 'openbao' is Ready on proxmox, proven end to end"

    print_status "Test (proxmox-test): the simple plain-Secret-backed store..."
    ansible-playbook playbooks/k3s-bao-simple-ensure.yml -e '{"target_contexts": ["proxmox-test"]}'
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
echo "Built: ${TARGET_SERVICES}"
echo "Each is replicated to both other nodes and HA-registered under one flat rule."
echo
echo "Prove it: power off a node and watch 'ha-manager status' move its guests elsewhere —"
echo "a real test, not inferred from configuration existing."
