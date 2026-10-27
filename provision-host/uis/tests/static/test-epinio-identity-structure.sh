#!/bin/bash
# test-epinio-identity-structure.sh — urb-agents#2040 (gates 17/18 migration)
#
# 627-setup-epinio-identity.yml wires Epinio's Dex connector to up to three identity
# providers, each independently optional. This asserts the properties that matter most
# if they silently regress: every enabled connector's required fields/secret are
# actually checked, the reflector annotation merge is a union (not an overwrite that
# could drop a different consumer's namespace), Dex's restart is unconditional (its own
# config reload needs it every time, confirmed live during the PoC), and the secret-
# bearing tasks carry no_log.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"

REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
PLAYBOOK="$REPO_ROOT/ansible/playbooks/627-setup-epinio-identity.yml"

print_test_section "Epinio identity wiring: required params, union not overwrite, unconditional restart"

start_test "the playbook is where this test thinks it is"
[[ -f "$PLAYBOOK" ]] && pass_test || { fail_test "missing: $PLAYBOOK"; print_summary; exit $?; }

pb="$(grep -v '^[[:space:]]*#' "$PLAYBOOK")"

start_test "control: the scan still sees real tasks"
if grep -qF 'kubernetes.core.k8s' <<< "$pb"; then
    pass_test
else
    fail_test "control" "comment-stripping removed everything — every check below is vacuous"
    print_summary
    exit 1
fi

start_test "refuses outright when no connector is enabled at all"
grep -qF 'epinio_identity_github.enabled or epinio_identity_authentik.enabled or epinio_identity_okta.enabled' <<< "$pb" \
    && pass_test \
    || fail_test "no enabled-check" "running this with nothing enabled would silently no-op through every task instead of failing clearly"

for connector in github authentik okta; do
    start_test "the ${connector} connector's secret is checked, only when ${connector}.enabled"
    if grep -qF "epinio_identity_${connector}_client_secret | length > 0" <<< "$pb" \
        && grep -qF "when: epinio_identity_${connector}.enabled" <<< "$pb"; then
        pass_test
    else
        fail_test "${connector} secret not gated correctly" "the playbook could proceed with that connector configured but no real secret"
    fi
done

start_test "🔴 reflector annotation is a UNION with whatever's already there, never a bare overwrite"
if grep -qF 'reject' <<< "$pb" && grep -qF '+ [epinio_namespace]' <<< "$pb" && grep -qF '| unique' <<< "$pb"; then
    pass_test
else
    fail_test "union logic missing" "a second future consumer of Authentik's Certificate could have its own namespace silently dropped on the next run of this playbook"
fi

start_test "🔴 Dex restart is unconditional — no 'when' gating it on whether the config actually changed"
_restart_block="$(sed -n '/name: 20\. Restart Dex/,/changed_when:/p' "$PLAYBOOK")"
if grep -qE '^\s*when:' <<< "$_restart_block"; then
    fail_test "restart is conditional" "Dex only reads its connector Secret at startup — a Helm values change with no restart leaves the OLD connector list serving, confirmed live during the PoC"
else
    pass_test
fi

start_test "the rendered Helm values / blueprint tasks carry no_log (both contain a real client secret)"
if grep -qE '^\s*no_log:\s*true\s*$' "$PLAYBOOK"; then
    pass_test
else
    fail_test "no no_log found anywhere" "a client secret could land in Ansible's own verbose/diff output"
fi

start_test "the identity values are applied with --reuse-values, not a bare -f (would reset the base install's own domain/TLS/storage settings)"
grep -qF -- '--reuse-values' <<< "$pb" \
    && pass_test \
    || fail_test "--reuse-values missing" "a plain helm upgrade -f would discard everything 625-setup-epinio.yml already configured that isn't also in this file"

print_summary
