#!/bin/bash
# test-secrets-new-defaults-propagate.sh - a new default VALUE must reach an
# existing installation, not only a brand-new one
#
# imac, urb-agents#1802: `uis deploy garage` failed twice with
# "GARAGE_ACCESS_KEY / GARAGE_SECRET_KEY / GARAGE_RPC_SECRET not found in
# urbalurba-secrets" - the keys existed in the generated Secret, but their
# values were empty strings. Root cause: copy_secrets_templates()'s
# existing-install branch synced the structural YAML template (new KEY NAMES)
# but never looked at 00-common-values.env.template itself (where a VALUE
# actually lives), so three new lines added there never reached an
# installation that pre-dated them.
#
# 🔴 Not Garage-specific. Any future secret added the same way hits every
# existing installation the same silent way - "silent" because the failure,
# once hit, IS clear (configure.sh refuses with a named-key error); nothing
# prompts an existing user to look before that point.
#
# This runs the real _append_missing_default_values() against a stub
# installation rather than grepping first-run.sh's source, because the thing
# that matters is what the function actually appends — and the first version
# of this fix was tested exactly this way (not left to a static check) before
# it shipped.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"
REPO="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
SHIPPED="$REPO/provision-host/uis/templates/secrets-templates/00-common-values.env.template"
FIRST_RUN="$REPO/provision-host/uis/lib/first-run.sh"

print_test_section "new default values propagate into an existing installation"

TMP="$(create_test_dir)"
trap 'cleanup_test_dir "$TMP"' EXIT

# Load the real function. first-run.sh sources logging.sh/utilities.sh/
# paths.sh relative to itself, which is fine - none of those are stubbed or
# overridden here, only the two file arguments the function itself takes.
source "$FIRST_RUN"

_stub_installed_file() {
    # A realistic pre-existing installation: everything the shipped template
    # has, EXCEPT the three lines this test's fixture names, simulating "this
    # install predates a later addition" without hardcoding which addition.
    grep -vE "^($1)=" "$SHIPPED" > "$TMP/installed.env"
    sed -i 's/^DEFAULT_DATABASE_PASSWORD=.*/DEFAULT_DATABASE_PASSWORD=OperatorChangedThisOnPurpose999/' "$TMP/installed.env"
}

start_test "a key missing from the installed file is appended with the shipped default"
_stub_installed_file "GARAGE_ACCESS_KEY|GARAGE_SECRET_KEY|GARAGE_RPC_SECRET"
_append_missing_default_values "$SHIPPED" "$TMP/installed.env" >/dev/null
if grep -q "^GARAGE_ACCESS_KEY=GKlocaldevgarage01$" "$TMP/installed.env" \
   && grep -q "^GARAGE_SECRET_KEY=" "$TMP/installed.env" \
   && grep -q "^GARAGE_RPC_SECRET=" "$TMP/installed.env"; then
    pass_test
else
    fail_test "the three missing keys were not appended with their shipped values"
fi

start_test "exactly the missing keys are added — not every key the shipped file has"
_stub_installed_file "GARAGE_ACCESS_KEY|GARAGE_SECRET_KEY|GARAGE_RPC_SECRET"
_append_missing_default_values "$SHIPPED" "$TMP/installed.env" >/dev/null
_added=$(diff <(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$TMP/installed.env" | sort -u) \
              <(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$SHIPPED" | sort -u))
if [[ -z "$_added" ]]; then
    pass_test
else
    fail_test "installed file's key set does not match the shipped file's after propagation: $_added"
fi

start_test "🔴 a value the operator already changed is left untouched"
_stub_installed_file "GARAGE_ACCESS_KEY|GARAGE_SECRET_KEY|GARAGE_RPC_SECRET"
_append_missing_default_values "$SHIPPED" "$TMP/installed.env" >/dev/null
if grep -q "^DEFAULT_DATABASE_PASSWORD=OperatorChangedThisOnPurpose999$" "$TMP/installed.env"; then
    pass_test
else
    fail_test "an existing, operator-set value was overwritten rather than left alone"
fi

start_test "running it twice does not duplicate the appended lines (idempotent)"
_stub_installed_file "GARAGE_ACCESS_KEY|GARAGE_SECRET_KEY|GARAGE_RPC_SECRET"
_append_missing_default_values "$SHIPPED" "$TMP/installed.env" >/dev/null
_append_missing_default_values "$SHIPPED" "$TMP/installed.env" >/dev/null
_count=$(grep -c "^GARAGE_ACCESS_KEY=" "$TMP/installed.env")
if [[ "$_count" -eq 1 ]]; then
    pass_test
else
    fail_test "GARAGE_ACCESS_KEY appears $_count times after two runs — not idempotent"
fi

start_test "nothing from an up-to-date installed file is appended"
cp "$SHIPPED" "$TMP/installed.env"
_before="$(md5sum "$TMP/installed.env" | awk '{print $1}')"
_append_missing_default_values "$SHIPPED" "$TMP/installed.env" >/dev/null
_after="$(md5sum "$TMP/installed.env" | awk '{print $1}')"
if [[ "$_before" == "$_after" ]]; then
    pass_test
else
    fail_test "an already-current file was modified anyway"
fi

start_test "copy_secrets_templates's existing-install branch actually calls this"
# ⚠️ First version of this assertion just grepped the bare function name,
# which also matches its own `# Usage:` comment and its own
# `_append_missing_default_values() {` definition line - so it stayed green
# after the real call site was deleted entirely. The function existing and
# working (proven above) does not mean anything calls it, which is exactly
# the shape of the bug this whole fix is for: logic correct for the case it
# handled, never extended to the case that broke. Require the call-site
# shape specifically - a bare invocation ending in a line-continuation
# backslash, which neither the comment nor the definition has.
if grep -qE '^\s+_append_missing_default_values \\$' "$REPO/provision-host/uis/lib/first-run.sh"; then
    pass_test
else
    fail_test "copy_secrets_templates never calls _append_missing_default_values"
fi

print_summary
