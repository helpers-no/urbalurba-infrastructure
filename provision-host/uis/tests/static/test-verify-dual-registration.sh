#!/bin/bash
# test-verify-dual-registration.sh — a VERIFY_SERVICES entry needs BOTH CLI forms.
#
# 🔴 `070-verify-authentik.yml` existed, unreachable, since it was written.
# Nobody dispatched to it from `uis verify authentik` OR `uis authentik verify`,
# and it was never in VERIFY_SERVICES, so `uis test-all` never ran it either
# (freeverse, urb-agents#2013).
#
# uis-cli.sh's own comments state the contract twice, verbatim:
#
#     `uis alloy verify` is the form VERIFY_SERVICES stores, so test-all
#     reaches the E2E tests through here - not through `uis verify alloy`.
#     Both are registered; a service with only one of them is unreachable
#     from whichever path it is missing.
#
# but nothing enforced it — the contract lived only as a comment next to the
# first few entries, not as a check against every entry in VERIFY_SERVICES.
# This test is that check: every VERIFY_SERVICES member must be dispatched
# from BOTH `uis verify <service>` (inside cmd_verify) and `uis <service>
# verify` (the top-level case in main()).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"

REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
CLI="$REPO_ROOT/provision-host/uis/manage/uis-cli.sh"
INTEGRATION="$REPO_ROOT/provision-host/uis/lib/integration-testing.sh"

print_test_section "every VERIFY_SERVICES member is reachable from both CLI forms"

start_test "the files are where this test thinks they are"
if [[ -f "$CLI" && -f "$INTEGRATION" ]]; then
    pass_test
else
    fail_test "missing file" "CLI=$CLI INTEGRATION=$INTEGRATION"
    print_summary; exit $?
fi

# Service ids VERIFY_SERVICES declares (one per line: "service_id:cli args").
_verify_service_ids() {
    local f="$1"
    sed -n '/^VERIFY_SERVICES="$/,/^"$/p' "$f" \
        | grep -E '^[a-z][a-z0-9_-]*:' \
        | cut -d: -f1 | sort -u
}

# Verbs dispatched inside the top-level `case "$command" in ... esac` in main().
# Same two-case-blocks trap test-help-lists-every-command.sh already documents:
# take the SECOND such block, not the first pre-dispatch one.
_toplevel_dispatched() {
    awk '
        /^    case "\$command" in/ { inside=1; next }
        inside && /^    esac/      { inside=0; next }
        inside && /^        [a-z][a-z0-9|_.-]*\)/ {
            line=$0; sub(/\).*/, "", line); gsub(/[ \t]/, "", line); print line
        }
    ' "$CLI" | tr '|' '\n' | sort -u
}

# Verbs dispatched inside cmd_verify()'s own `case "$target" in ... esac`.
_cmd_verify_dispatched() {
    sed -n '/^cmd_verify() {/,/^}/p' "$CLI" \
        | grep -E '^        [a-z][a-z0-9|_.-]*\)' \
        | sed -E 's/\).*//; s/[ \t]//g' \
        | tr '|' '\n' | sort -u
}

start_test "control: VERIFY_SERVICES parses to a non-trivial list"
_ids="$(_verify_service_ids "$INTEGRATION")"
_n=$(printf '%s\n' "$_ids" | grep -c .)
[[ "$_n" -ge 5 ]] && pass_test || { fail_test "control" "parsed only $_n ids; the parse is probably wrong"; print_summary; exit $?; }

start_test "control: both dispatch tables parse to non-trivial lists"
_top="$(_toplevel_dispatched)"
_cv="$(_cmd_verify_dispatched)"
_topn=$(printf '%s\n' "$_top" | grep -c .)
_cvn=$(printf '%s\n' "$_cv" | grep -c .)
if [[ "$_topn" -ge 15 && "$_cvn" -ge 10 ]]; then
    pass_test
else
    fail_test "control" "top-level=$_topn cmd_verify=$_cvn; one of the parses is probably wrong"
    print_summary; exit $?
fi

start_test "🔴 every VERIFY_SERVICES member is dispatched from BOTH CLI forms"
_missing=""
while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    grep -qx "$id" <<< "$_top" || _missing+="$id(missing: uis $id verify) "
    grep -qx "$id" <<< "$_cv"  || _missing+="$id(missing: uis verify $id) "
done <<< "$_ids"
[[ -z "$_missing" ]] && pass_test || fail_test "registered in VERIFY_SERVICES but not fully dispatched" "$_missing"

print_summary
