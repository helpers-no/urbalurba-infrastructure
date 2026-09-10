#!/bin/bash
# test-no-internal-detail-in-product.sh — the shipping surface must not name
# the reference installation's private network.
#
# 🔴 THIS REPOSITORY IS PUBLIC. Files under provision-host/ and ansible/ are
# the product: they are baked into the image and copied onto every machine that
# installs UIS. An example in a shipped comment is read by strangers.
#
# Found while answering a topology question (ops, urb-agents#600): the shipped
# external-services.yaml default, both proxy templates and the proxy playbook's
# usage line together named a backplane address, a container id and a bridge
# name, plus a doc that does not exist in this repository.
#
# ⚠️ SCOPE IS DELIBERATELY NARROW. `hosts/<name>/` holds one installation's OWN
# manifests, where its own addresses belong; whether they should be in a public
# repository at all is a separate decision and is not this lint's business.
# Examples in product files should use RFC 5737 documentation addresses
# (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"

REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

print_test_section "no internal detail on the shipping surface"

# One pattern per line: identifiers that only exist on the reference lab.
_patterns=(
    '10\.10\.0\.[0-9]+'          # the backplane range
    '\bCT [0-9]{3}\b'            # Proxmox container ids
    '\bvmbr[0-9]\b'              # hypervisor bridges
    'odin-backplane'             # a doc that is not in this repository
)

_scan() {
    local root="$1" pat found=""
    for pat in "${_patterns[@]}"; do
        found+="$(grep -rInE "$pat" "$root/provision-host" "$root/ansible" 2>/dev/null \
                   | grep -v '/tests/static/test-no-internal-detail-in-product.sh:' || true)"
    done
    printf '%s' "$found"
}

start_test "provision-host/ and ansible/ name no lab address, container id or bridge"
hits="$(_scan "$REPO_ROOT")"
if [[ -z "$hits" ]]; then
    pass_test
else
    fail_test "internal detail on the shipping surface:"$'\n'"$hits"
fi

# 🔴 POSITIVE CONTROLS. An empty result from a grep proves nothing about the
# grep. Each pattern is shown to actually match the thing it is written for.
_ctl="$(mktemp -d)"
mkdir -p "$_ctl/provision-host" "$_ctl/ansible"
_ctl_check() {
    local label="$1" line="$2"
    printf '%s\n' "$line" > "$_ctl/provision-host/sample.sh"
    start_test "positive control: $label is caught"
    [[ -n "$(_scan "$_ctl")" ]] && pass_test || fail_test "pattern does not match: $line"
}
_ctl_check "a backplane address"  '# host: 10.10.0.105'
_ctl_check "a container id"       '# runs in CT 105 on the hypervisor'
_ctl_check "a bridge name"        '# over the host-only bridge vmbr1'
_ctl_check "the absent doc"       '# see docs: odin-backplane-network.md'

start_test "negative control: an RFC 5737 documentation address is allowed"
printf '%s\n' '# host: 192.0.2.10' > "$_ctl/provision-host/sample.sh"
[[ -z "$(_scan "$_ctl")" ]] && pass_test || fail_test "documentation addresses must not be flagged"

start_test "negative control: an ordinary cluster address is allowed"
printf '%s\n' '# postgresql.default.svc.cluster.local:5432 and 127.0.0.1' > "$_ctl/provision-host/sample.sh"
[[ -z "$(_scan "$_ctl")" ]] && pass_test || fail_test "false positive on ordinary addresses"
rm -rf "$_ctl"

print_summary
