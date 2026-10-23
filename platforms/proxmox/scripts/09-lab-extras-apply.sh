#!/bin/bash
# File: platforms/proxmox/scripts/09-lab-extras-apply.sh
#
# Description:
#   Build every guest in LAB_EXTRAS. Each declaration's own `service.kind` (lxc or vm — see
#   generate-ansible-config.sh's write_guest_decl/write_vm_extra_decl) decides the mechanism:
#     - lxc (dns-resolver, nas): guest-ensure.yml, then replicate to both other nodes and
#       register under the same flat HA rule CORE_SERVICES guests use. Same guest -> install ->
#       replicate -> HA-register shape as 05-core-services-apply.sh, deliberately NOT merged into
#       that script or its CORE_SERVICES list — see config.sh-template's "Lab extras" section
#       (urb-agents#1970/#1971/#1972) for why these stay a visibly separate, empty-by-default list.
#     - vm (forgejo-runner): vm-ensure.yml instead, and NO replicate/HA-register step — see
#       urb-agents#1982: disposable CI-runner compute has nothing worth Proxmox-HA-protecting.
#
#   NOT part of `up.sh`'s historical 5-step chain in spirit — it IS now one more step of it (see
#   up.sh), but LAB_EXTRAS is empty by default, so a lab owner who never opts in never has this
#   script build anything. Unlike CORE_SERVICES, there is no "reference lab's own real
#   configuration" default here to inherit.
#
# Usage:
#   ./scripts/09-lab-extras-apply.sh              # every guest in LAB_EXTRAS
#   ./scripts/09-lab-extras-apply.sh dns-resolver  # just this one (called by
#                                                   # scripts/08-lab-extra-add.sh)

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
print_status()  { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
print_section() { echo; echo -e "${GREEN}========================================${NC}"; echo -e "${GREEN}$1${NC}"; echo -e "${GREEN}========================================${NC}"; echo; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="${UIS_REPO_ROOT:-$(cd "$PLATFORM_DIR/../.." && pwd)}"
ANSIBLE_DIR="$PLATFORM_DIR/ansible"
CONFIG_FILE="$REPO_ROOT/.uis.secrets/platforms/proxmox/config.sh"

print_section "PROXMOX — LAB EXTRAS APPLY"

if [[ ! -f "$CONFIG_FILE" ]]; then
    print_error "No config.sh found at $CONFIG_FILE"
    exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE"
LAB_EXTRAS="${LAB_EXTRAS:-}"

if [[ -z "${LAB_EXTRAS// }" ]]; then
    print_warning "LAB_EXTRAS is empty in config.sh — nothing to build. Exiting."
    exit 0
fi

# Same scoped-run shape as 05-core-services-apply.sh's own TARGET_SERVICES.
TARGET_EXTRAS="${1:-$LAB_EXTRAS}"
if [[ -n "${1:-}" ]]; then
    _found=0
    for _e in $LAB_EXTRAS; do
        [[ "$_e" == "$1" ]] && _found=1 && break
    done
    if [[ "$_found" -eq 0 ]]; then
        print_error "'$1' is not in config.sh's LAB_EXTRAS ($LAB_EXTRAS) — add it there first."
        exit 1
    fi
fi

print_status "Generating ansible config from config.sh..."
bash "$SCRIPT_DIR/generate-ansible-config.sh"

cd "$ANSIBLE_DIR"
PUBKEY="${PROXMOX_SSH_KEY}.pub"
ssh_h1() { ssh -i "$PROXMOX_SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "root@${PROXMOX_HOST1_ADDR}" "$@"; }
ssh_node() { local addr="$1"; shift; ssh -i "$PROXMOX_SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "root@${addr}" "$@"; }

declare -A NODE_ADDR=(
    ["$PROXMOX_HOST1_NAME"]="$PROXMOX_HOST1_ADDR"
    ["$PROXMOX_HOST2_NAME"]="$PROXMOX_HOST2_ADDR"
    ["$PROXMOX_HOST3_NAME"]="$PROXMOX_HOST3_ADDR"
)

# Identical to 05-core-services-apply.sh's own guest_node — see that file's comment for why this
# is cluster-wide (pvesh) rather than node-local (pct), and why a VMID/name mismatch warns rather
# than refuses.
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
            print_warning "VMID ${vmid} exists but is named '${name}', not '${expected_name}' — this usually means the VMID collides with an UNRELATED guest, not ${expected_name}. Double-check before trusting anything derived from it. If ${expected_name}'s real VMID differs, override it via config.sh's LAB_EXTRA_*_VMID." >&2
        fi
    fi
    if [[ -z "${NODE_ADDR[$node]:-}" ]]; then
        print_error "VMID ${vmid} is on node '${node}', which is none of PROXMOX_HOST{1,2,3}_NAME in config.sh."
        exit 1
    fi
    echo "$node"
}

for extra in $TARGET_EXTRAS; do
    decl="generated/vars/lab-extras/${extra}.yml"
    if [[ ! -f "$decl" ]]; then
        print_warning "No declaration for '$extra' (unknown lab extra?) — skipped"
        continue
    fi
    vmid="$(grep -m1 '^  vmid:' "$decl" | awk '{print $2}')"
    # 🔵 kind: lxc|vm — written by write_guest_decl/write_vm_extra_decl in
    # generate-ansible-config.sh. Defaults to lxc for safety if somehow absent (every declaration
    # this script actually reads carries it; this is not expected to trigger in practice).
    kind="$(grep -m1 '^  kind:' "$decl" | awk '{print $2}')"
    kind="${kind:-lxc}"

    print_section "$extra (VMID $vmid, kind=$kind)"

    if [[ "$kind" == "vm" ]]; then
        # 🔴 THE GENERATED INVENTORY, NOT A BARE COMMA ADDRESS — vm-ensure.yml's play is
        # `hosts: proxmox` (a NAMED group), unlike guest-ensure.yml's `hosts: all`. A bare
        # `-i "${addr},"` ad-hoc inventory has no such group and would match nothing.
        print_status "vm-ensure..."
        ansible-playbook -i generated/inventory.yml --limit "$PROXMOX_HOST1_NAME" \
            -u root --private-key "$PROXMOX_SSH_KEY" \
            playbooks/vm-ensure.yml \
            -e "vm_file=${decl}" -e "control_pubkey_file=${PUBKEY}"
    else
        print_status "guest-ensure..."
        ansible-playbook -i "${PROXMOX_HOST1_ADDR}," -u root --private-key "$PROXMOX_SSH_KEY" \
            playbooks/guest-ensure.yml \
            -e "guest_file=${decl}" -e "guest_pubkey=${PUBKEY}"
    fi

    print_status "Finding which node ${extra}'s guest actually lives on..."
    guest_node_name="$(guest_node "$vmid" "$extra")"
    guest_node_addr="${NODE_ADDR[$guest_node_name]}"
    if [[ "$guest_node_name" != "$PROXMOX_HOST1_NAME" ]]; then
        print_warning "VMID ${vmid} is on '${guest_node_name}', not host1 — HA relocated it since it was declared."
    fi

    print_status "Finding ${extra}'s guest IP..."
    if [[ "$kind" == "vm" ]]; then
        # 🔵 READ FROM THE DECLARATION, NOT DISCOVERED LIVE — unlike an LXC guest's DHCP-ish
        # `pct exec hostname -I`, vm-ensure.yml sets this VM's address statically via cloud-init
        # (`--ipconfig0`), proven reachable by vm-ensure.yml's own SSH-login proof already. No
        # guest-agent round trip needed.
        guest_ip="$(grep -m1 '^  ip:' "$decl" | awk '{print $2}' | tr -d '"')"
        guest_ip="${guest_ip%%/*}"
    else
        guest_ip="$(ssh_node "$guest_node_addr" "pct exec ${vmid} -- hostname -I" | awk '{print $1}')"
    fi
    if [[ -z "$guest_ip" ]]; then
        print_error "Could not get an IP for ${extra} (VMID ${vmid}) on ${guest_node_name} — is it actually running?"
        exit 1
    fi
    ssh-keygen -f ~/.ssh/known_hosts -R "${guest_ip}" >/dev/null 2>&1 || true

    print_status "service-${extra} (${guest_ip})..."
    extra_vars_file="generated/vars/lab-extras/_extra-vars.yml"
    extra_args=(-e "@${extra_vars_file}")

    # 🔵 PER-EXTRA SITE DATA — real, persistent, per-install, never regenerated, same shape as
    # config.sh itself (urb-agents#1935's own "survives a uis-pull" discipline). Some lab extras
    # (nas, forgejo-runner) need bespoke data — named human/agent accounts, a registration token
    # — that config.sh's own flat-scalar style was never meant to carry, and that this script has
    # no business inventing or defaulting (same "site data, not role data" rule the role itself
    # enforces). A lab owner who needs one copies the matching `-template` file themselves; this
    # is entirely optional — only passed if present, so an extra with no such file (dns-resolver
    # today) behaves exactly as before.
    site_data_file="$REPO_ROOT/.uis.secrets/platforms/proxmox/lab-extras/${extra}-site-data.yml"
    if [[ -f "$site_data_file" ]]; then
        extra_args+=(-e "@${site_data_file}")
    fi

    # 🔵 A VM-kind guest's declared ciuser, NOT root — unlike LXC, where root is the standing
    # convention everywhere else in this platform, a VM's cloud-init identity is VM_CIUSER
    # (k3s-ensure.yml's own `guests:` inventory group follows the same rule). The role itself
    # carries `become: true` to get root where it actually needs it.
    service_ssh_user="root"
    [[ "$kind" == "vm" ]] && service_ssh_user="$VM_CIUSER"

    ansible-playbook -i "${guest_ip}," -u "$service_ssh_user" --private-key "$PROXMOX_SSH_KEY" \
        --ssh-common-args "-o StrictHostKeyChecking=accept-new" \
        "${extra_args[@]}" \
        "playbooks/service-${extra}.yml" || {
        print_error "service-${extra} failed — see ansible output above."
        exit 1
    }
    print_success "$extra installed and verified"

    if [[ "$kind" == "vm" ]]; then
        # 🔴 NO REPLICATION, NO HA — deliberately. Unlike pg/bao/garage/nas (real data that must
        # follow a node failure), a VM-kind lab-extra like forgejo-runner is disposable compute:
        # nothing it holds is worth Proxmox-HA-protecting, and registering it as an HA member
        # would just mean Proxmox tries to restart a CI runner that was never promised uptime.
        print_status "$extra is a VM-kind lab-extra — stateless compute, no replication or HA registration (see README.md's \"Lab extras\" section)."
    else
        print_status "Replicating $extra to both other nodes..."
        for target_name in "$PROXMOX_HOST1_NAME" "$PROXMOX_HOST2_NAME" "$PROXMOX_HOST3_NAME"; do
            [[ "$target_name" == "$guest_node_name" ]] && continue
            ansible-playbook -i "${guest_node_addr}," -u root --private-key "$PROXMOX_SSH_KEY" \
                playbooks/replication-ensure.yml -e "vmid=${vmid}" -e "target_node=${target_name}"
        done

        print_status "Registering $extra as an HA member..."
        ansible-playbook -i "${PROXMOX_HOST1_ADDR}," -u root --private-key "$PROXMOX_SSH_KEY" \
            playbooks/ha-ensure.yml --tags member -e "vmid=${vmid}"

        print_success "$extra fully protected: replicated + HA-registered"
    fi
done
