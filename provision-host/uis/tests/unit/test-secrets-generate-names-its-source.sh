#!/bin/bash
# test-secrets-generate-names-its-source.sh — `uis secrets generate` must say
# which file it read values from, every run.
#
# urb-agents/urbalurba-infrastructure#568: an edit to NEKO_CDP_TOKEN in
# `provision-host/uis/templates/secrets-templates/00-common-values.env.template`
# (the file this filename is tracked at in the repo/image), followed by
# `uis secrets generate && uis secrets apply`, produced neither the new value
# nor the original shipped default — because that file is copied to the LIVE
# path (.uis.secrets/secrets-config/00-common-values.env.template) exactly
# once, on first run, and never again: `generate_kubernetes_secrets()` always
# reads the live copy, and `copy_secrets_templates()`'s existing-install
# branch deliberately never overwrites an existing value there (by design —
# see test-secrets-new-defaults-propagate.sh). Editing the shipped copy on an
# already-installed system is a silent no-op.
#
# The fix doesn't change which file is authoritative (that's correct as-is —
# an operator's edits must survive an upgrade). It makes the mismatch
# impossible to miss: `generate_kubernetes_secrets()` now names the exact
# path it read, every run, not only on error.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"
REPO="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
FIRST_RUN="$REPO/provision-host/uis/lib/first-run.sh"

print_test_section "generate_kubernetes_secrets names the file it read"

TMP="$(create_test_dir)"
trap 'cleanup_test_dir "$TMP"' EXIT

# A stub live installation: SECRETS_DIR pre-set (paths.sh respects an
# already-exported value — see get_secrets_dir()), so no /mnt/urbalurbadisk
# dependency.
export SECRETS_DIR="$TMP/.uis.secrets"
mkdir -p "$SECRETS_DIR/secrets-config"
_live_common="$SECRETS_DIR/secrets-config/00-common-values.env.template"
echo 'NEKO_CDP_TOKEN=WhateverIsInTheLiveCopy' > "$_live_common"
# A minimal but real master template — one substitution is enough to prove
# envsubst actually ran end to end, not just that the function didn't crash.
cat > "$SECRETS_DIR/secrets-config/00-master-secrets.yml.template" <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: urbalurba-secrets
stringData:
  NEKO_CDP_TOKEN: "${NEKO_CDP_TOKEN}"
EOF

source "$FIRST_RUN"

start_test "it prints the live path, not just 'Generating...'"
_out="$(generate_kubernetes_secrets 2>&1)"
echo "$_out" | grep -qF "Reading values from: $_live_common" && pass_test \
    || fail_test "expected the exact live path in the output, got:\n$_out"

start_test "and it actually read values from THAT file, not some other copy"
_out="$(generate_kubernetes_secrets 2>&1)"
grep -q 'NEKO_CDP_TOKEN: "WhateverIsInTheLiveCopy"' \
    "$SECRETS_DIR/generated/kubernetes/kubernetes-secrets.yml" && pass_test \
    || fail_test "generated secret does not carry the live copy's value"

start_test "the shipped template (repo copy) carries the same warning, verbatim"
_shipped="$REPO/provision-host/uis/templates/secrets-templates/00-common-values.env.template"
grep -q "urb-agents/urbalurba-infrastructure#568" "$_shipped" && pass_test \
    || fail_test "the #568 warning is missing from the shipped template's header"

start_test "the warning names the real fix: ./uis secrets edit"
grep -q '\./uis secrets edit' "$_shipped" && pass_test \
    || fail_test "the shipped template no longer points at 'uis secrets edit'"

print_summary
