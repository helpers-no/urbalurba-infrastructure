#!/bin/bash
# test-argocd-register-uis-layout.sh — register reads uis/, falls back to manifests/
#
# urb-agents#1898 (bifrost): `uis argocd register` hard-required a manifests/
# directory and failed for repositories using the published uis/ layout
# standard (kustomization.yaml, one file per service). Verified live against
# the real GitHub API before this fix: terchris/bifrost has uis/ and no
# manifests/, and the unpatched playbook refused it with "No manifests/
# directory found" — the exact failure bifrost reported. The legacy case
# (terchris/urb-dev-typescript-hello-world: manifests/ only, no uis/) must
# keep working, and a repo with neither must still refuse.
#
# This static test can't reach GitHub in CI, so it asserts the STRUCTURE that
# produces that behavior: uis/ is checked, manifests/ is checked only as a
# fallback, the ArgoCD Application path is driven by the detected variable
# (never hardcoded), and the failure message names both locations.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
REG="$REPO/ansible/playbooks/argocd-register-app.yml"

PASS=0; FAIL=0
pass() { echo -e "  Testing: $1... \033[0;32mPASS\033[0m"; ((++PASS)); }
fail() { echo -e "  Testing: $1... \033[0;31mFAIL\033[0m"; echo -e "    \033[0;31m→ $2\033[0m"; ((++FAIL)); }

echo "=== argocd register reads uis/, falls back to manifests/ (#1898) ==="

[[ -f "$REG" ]] || { fail "file present" "missing: $REG"; echo; echo "  Passed: $PASS  Failed: $FAIL"; exit 1; }

# Comment-stripped: the prose above and in the playbook names uis/ and
# manifests/ repeatedly, so a file-wide grep would pass with the fix reverted.
reg="$(grep -v '^[[:space:]]*#' "$REG")"

if grep -q 'uri:' <<<"$reg"; then
    pass "control: the comment-stripped scan still sees tasks"
else
    fail "control: the scan sees tasks" "stripping removed everything — all checks below vacuous"
    echo ""; echo "  Passed: $PASS  Failed: $FAIL"; exit 1
fi

# --- uis/ must be checked, as a GitHub contents API call ------------------
if grep -qF '/contents/uis"' <<<"$reg"; then
    pass "checks the uis/ directory via the contents API"
else
    fail "checks uis/" "no request to contents/uis — the standard layout is never tried"
fi

# --- manifests/ must be a FALLBACK, not an unconditional check -------------
# The specific regression this guards: the old code checked manifests/
# unconditionally, so register-app rejected ANY repo using uis/ alone.
_manifests_block="$(sed -n '/contents\/manifests/,/^$/p' <<<"$reg" | head -20)"
if grep -qF 'uis_check_status' <<<"$_manifests_block"; then
    pass "manifests/ check is gated on uis/ having already failed"
else
    fail "manifests/ is a fallback, not a parallel requirement" "a repo with only uis/ would still be required to also have manifests/, or vice versa without priority"
fi

# --- the chosen path must come from a variable, never hardcoded ----------
if grep -qE "path:[[:space:]]*(manifests|uis)[[:space:]]*$" <<<"$reg"; then
    fail "Application path is not hardcoded" "the ArgoCD Application source.path is a literal, so only one layout can ever work"
else
    pass "Application path is driven by the detected app_path, not a literal"
fi

if grep -qF 'path: "{{ app_path }}"' <<<"$reg"; then
    pass "Application source.path reads the detected app_path"
else
    fail "Application source.path reads app_path" "the registered Application would not point at the directory that was actually found"
fi

# --- uis/ must win when both exist (the published standard, not the legacy shape) ---
if grep -qE "app_path:.*'uis'[[:space:]]*if.*uis_check_status" <<<"$reg"; then
    pass "uis/ takes priority over manifests/ when both are present"
else
    fail "uis/ is preferred" "a repo mid-migration with both directories could silently register against the stale manifests/ copy"
fi

# --- a repo with NEITHER directory must still be refused -------------------
if grep -q 'No uis/ or manifests/ directory found' <<<"$reg"; then
    pass "still refuses when neither directory exists"
else
    fail "refuses when neither exists" "a repo with no deployable layout at all would silently proceed"
fi

echo ""
echo "  Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
