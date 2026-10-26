#!/bin/bash
# test-epinio-cert-manager-shared-ca.sh — Epinio's own endpoint must use uis-ca, not its
# own bundled CA.
#
# 🔴 `certManager.enabled: true` alone does NOT point Epinio's chart at this platform's
# shared `uis-ca` ClusterIssuer — confirmed against the pinned chart's own source
# (epinio/helm-charts @ epinio-1.14.3, templates/certificates/): `global.tlsIssuer`
# defaults to `"epinio-ca"`, one of four issuers the chart creates and manages itself.
# Without `global.customTlsIssuer: uis-ca`, Epinio silently issues its own endpoint's
# certificate from a second, separate self-signed CA — exactly the "bespoke Epinio-only
# CA" pattern Terje's decision rejected (urb-agents#1911 → #2023: cert-manager is a
# shared UIS service, not a per-component mount).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"

REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
PLAYBOOK="$REPO_ROOT/ansible/playbooks/625-setup-epinio.yml"

print_test_section "Epinio's own Certificate comes from the shared uis-ca ClusterIssuer"

start_test "the playbook is where this test thinks it is"
[[ -f "$PLAYBOOK" ]] && pass_test || { fail_test "missing: $PLAYBOOK"; print_summary; exit $?; }

start_test "control: certManager.enabled is still set (the thing customTlsIssuer builds on)"
grep -qE '^\s*enabled:\s*true' "$PLAYBOOK" && pass_test \
    || fail_test "control" "certManager.enabled: true not found — has the values block moved?"

start_test "🔴 global.customTlsIssuer is set to uis-ca in the Helm values this playbook writes"
_values_block="$(sed -n '/dest: \/tmp\/epinio-values.yaml/,/mode: /p' "$PLAYBOOK")"
if grep -qE '^\s*customTlsIssuer:\s*uis-ca\s*$' <<< "$_values_block"; then
    pass_test
else
    fail_test "customTlsIssuer missing or wrong" \
        "without it, Epinio issues from its own bundled epinio-ca, not this platform's uis-ca"
fi

print_summary
