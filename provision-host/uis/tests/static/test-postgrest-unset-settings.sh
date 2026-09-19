#!/bin/bash
# test-postgrest-unset-settings.sh — a documented "we do not set this" must stay true.
#
# urb-agents#1259. A live consumer fetches the register unpaged and is only
# correct while PostgREST's db-max-rows is unset: set it, and the client gets
# the first N rows with a 200, a well-formed body and no error, so every figure
# derived from it goes quietly low.
#
# 🔴 The trap is an interaction. db-aggregates-enabled is a reasonable request,
# and the standard mitigation for the load it invites is db-max-rows plus a
# statement timeout — which is what a requester will propose. Granting the
# aggregates request with that mitigation silently caps every unpaged consumer.
# Two sensible decisions, made separately, combining into a data bug.
#
# 🔵 THIS TEST EXISTS TO MAKE THE DOCUMENTATION SELF-ENFORCING. postgrest.md
# states that UIS does not set these. A page asserting a fact about the code is
# worthless if the code can change underneath it — so the claim is asserted
# here. Setting either value is allowed; setting it while the page still says
# otherwise is not.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"

if [[ -d "/mnt/urbalurbadisk/manifests" ]]; then
    REPO="/mnt/urbalurbadisk"
else
    REPO="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
fi
DOC="$REPO/website/docs/services/integration/postgrest.md"

print_test_section "PostgREST settings UIS deliberately leaves unset"

# Where a setting would have to appear to take effect. Not the whole repo: the
# docs and this test both NAME these settings, and a repo-wide grep would match
# its own explanation — the comment-matching lesson from the oauth2 suite.
_SEARCH=("$REPO/manifests" "$REPO/provision-host/uis/lib" "$REPO/ansible")
_PAT='PGRST_DB_MAX_ROWS|db-max-rows|PGRST_DB_AGGREGATES_ENABLED|db-aggregates-enabled'

start_test "the search pattern can match a PostgREST setting at all"
# An empty grep is not evidence. Prove the pattern and the paths work together
# before reading zero hits as "not set" — a typo in either would pass silently.
if grep -rhoE 'PGRST_DB_[A-Z_]+' "${_SEARCH[@]}" 2>/dev/null | grep -q 'PGRST_DB_'; then
    pass_test
else
    fail_test "positive control failed: no PGRST_DB_* found in the searched paths, so absence proves nothing"
fi

start_test "UIS does not set db-max-rows or db-aggregates-enabled"
_hits=$(grep -rniE "$_PAT" "${_SEARCH[@]}" 2>/dev/null || true)
if [[ -z "$_hits" ]]; then
    pass_test
else
    fail_test "one of these is now set — postgrest.md says it is not, and that page must be updated in the same change:
$_hits"
fi

start_test "the page still carries the warning that makes the absence deliberate"
# Deleting the section would also make the check above pass, and would leave the
# next operator with no reason not to set it.
_ok=0
grep -qF 'db-max-rows` is unset' "$DOC" && _ok=$((_ok+1))
grep -qF 'db-aggregates-enabled' "$DOC" && _ok=$((_ok+1))
if [[ "$_ok" -eq 2 ]]; then
    pass_test
else
    fail_test "only $_ok of 2 — the documented reason is gone, so the setting looks free to change"
fi

print_summary
