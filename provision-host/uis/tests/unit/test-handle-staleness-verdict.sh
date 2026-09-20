#!/bin/bash
# test-handle-staleness-verdict.sh — STALE / FRESH / UNREADABLE, from the shipped shell.
#
# urb-agents#1280. The tester ran the live matrix (healthy / STALE / repaired)
# and declined, for the second round running, to manufacture UNREADABLE by
# breaking something real — saying so rather than claiming a pass. It pointed at
# the _deploy_change_verdict precedent as the route, and it was right:
#
# 🔴 UNREADABLE is the branch that exists SPECIFICALLY so an empty read never
# passes as healthy. That makes it the one where a silent failure is worst, and
# the one least likely to be exercised by accident.
#
# 🔵 This extracts F2's command FROM THE PLAYBOOK and runs it, so it tests the
# shipped code path rather than a copy that can drift away from it.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(dirname "$SCRIPT_DIR")"
source "$TESTS_DIR/lib/test-framework.sh"

UIS_DIR="$(dirname "$TESTS_DIR")"
if [[ -d "/mnt/urbalurbadisk/ansible" ]]; then
    REPO="/mnt/urbalurbadisk"
else
    REPO="$(cd "$UIS_DIR/../.." && pwd)"
fi
PB="$REPO/ansible/playbooks/360-test-dagster.yml"

print_test_section "the code-location handle verdict"

start_test "the playbook exists"
assert_file_exists "$PB" && pass_test

# yq is how the command is lifted out of the YAML. Without it the extraction
# cannot happen, and a skip here must not read as a pass.
if ! command -v yq >/dev/null 2>&1; then
    start_test "yq available to extract F2 from the playbook"
    if [[ -n "${CI:-}" ]]; then
        # 🔴 HARD FAIL IN CI. A dependency quietly missing is how three
        # assertions skipped for months; the house rule is that CI never skips.
        fail_test "yq is missing in CI — the verdict branches were NOT tested"
    else
        skip_test "no yq on this host — CI extracts and runs this"
    fi
    print_summary
    return 0 2>/dev/null || exit 0
fi

_F2="$(yq -r '.[0].tasks[] | select(.name|test("^F2\\.")) | .["ansible.builtin.shell"].cmd' "$PB" 2>/dev/null)"

start_test "F2's command was extracted from the playbook"
# Without this the runs below would execute an empty script and echo nothing,
# and every comparison would fail for the wrong reason — or worse, pass.
if [[ -n "$_F2" && "$_F2" == *newest_loc* && "$_F2" == *oldest_srv* ]]; then
    pass_test
else
    fail_test "could not lift F2 out of the playbook — the cases below would be vacuous"
fi

# Run the shipped command with the Jinja variable replaced by fixture input.
_verdict() {
    local pod_ages="$1" script
    script="${_F2//\{\{ _pod_ages.stdout \}\}/$pod_ages}"
    bash -c "$script" 2>/dev/null | tr -d '\n'
}

_STALE=$'dagster-dagster-webserver-x 2026-09-20T00:18:22Z\ndagster-daemon-y 2026-09-20T00:18:25Z\ndagster-atlas-code-location-z 2026-09-20T02:50:37Z'
_FRESH=$'dagster-dagster-webserver-x 2026-09-20T03:00:00Z\ndagster-daemon-y 2026-09-20T03:00:05Z\ndagster-atlas-code-location-z 2026-09-20T02:50:37Z'

start_test "servers older than the code location -> STALE"
[[ "$(_verdict "$_STALE")" == STALE* ]] && pass_test || fail_test "got: $(_verdict "$_STALE")"

start_test "servers newer than the code location -> FRESH"
[[ "$(_verdict "$_FRESH")" == FRESH* ]] && pass_test || fail_test "got: $(_verdict "$_FRESH")"

start_test "no code-location pod at all -> UNREADABLE, not FRESH"
# The branch the tester would not manufacture on a cluster. An install with no
# code location must not report a healthy handle.
[[ "$(_verdict $'dagster-dagster-webserver-x 2026-09-20T03:00:00Z')" == "UNREADABLE" ]] \
    && pass_test || fail_test "got: $(_verdict $'dagster-dagster-webserver-x 2026-09-20T03:00:00Z')"

start_test "no webserver or daemon pod -> UNREADABLE, not FRESH"
[[ "$(_verdict $'dagster-atlas-code-location-z 2026-09-20T02:50:37Z')" == "UNREADABLE" ]] \
    && pass_test || fail_test "got: $(_verdict $'dagster-atlas-code-location-z 2026-09-20T02:50:37Z')"

start_test "chart labels renamed so nothing matches -> UNREADABLE, not FRESH"
# 🔴 THE CASE THE WHOLE BRANCH EXISTS FOR. A selector that stops matching
# returns empty, and empty must never read as healthy — the failure the sibling
# playbook warns about and that 1.6.130 walked into with an invented label.
[[ "$(_verdict $'something-unrelated 2026-09-20T03:00:00Z')" == "UNREADABLE" ]] \
    && pass_test || fail_test "got: $(_verdict $'something-unrelated 2026-09-20T03:00:00Z')"

start_test "no pods at all -> UNREADABLE"
[[ "$(_verdict "")" == "UNREADABLE" ]] && pass_test || fail_test "got: $(_verdict "")"

print_summary
