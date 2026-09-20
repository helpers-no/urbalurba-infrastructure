#!/bin/bash
# test-deploy-says-what-it-did.sh — a deploy that rolled nothing must not claim it did.
#
# urb-agents#1275, the second instance of one sentence in two days:
#
#   2026-09-18  #1235  the oauth2 secret path — reported success, changed nothing
#   2026-09-19  #1271  uis deploy dagster    — reported success, rolled nothing
#
# `./uis deploy dagster` printed "✓ Dagster deployed successfully" while the
# webserver and daemon pods stayed two days old, because the Helm values were
# unchanged. Two green Dagster runs then executed a stale image before anyone
# suspected the command.
#
# ⚠️ "Nothing to do" is usually the CORRECT outcome of a deploy, so this must
# never go red on a healthy no-op. The message is the fix, not the exit code.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TESTS_DIR/lib/test-framework.sh" 2>/dev/null || source "$SCRIPT_DIR/../lib/test-framework.sh"

if [[ -d "/mnt/urbalurbadisk/provision-host" ]]; then
    REPO="/mnt/urbalurbadisk"
else
    REPO="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
fi
LIB="$REPO/provision-host/uis/lib/service-deployment.sh"

_code_only() { grep -vE '^[[:space:]]*#' "$@"; }

print_test_section "uis deploy says what it actually did"

start_test "service-deployment.sh exists"
assert_file_exists "$LIB" && pass_test

start_test "the workload is fingerprinted BEFORE the playbook runs"
# Taken afterwards, the answer is always "matches" and the message is always
# wrong in the same direction.
_b=$(grep -n '_UIS_FP_BEFORE=' "$LIB" | head -1 | cut -d: -f1)
_r=$(grep -n 'ansible-playbook "\$playbook_path"' "$LIB" | head -1 | cut -d: -f1)
if [[ -n "$_b" && -n "$_r" && "$_b" -lt "$_r" ]]; then
    pass_test
else
    fail_test "the snapshot does not precede the playbook (before=$_b run=$_r)"
fi

start_test "the fingerprint includes pod START TIME, not just names"
# A pod restarted in place keeps its name. Names alone would report a real
# restart as "nothing changed" — the defect, inverted.
if _code_only "$LIB" | grep -qF '.status.startTime'; then
    pass_test
else
    fail_test "a restart-in-place would be reported as no change"
fi

start_test "a deploy that rolled nothing says so"
if _code_only "$LIB" | grep -qF 'nothing changed'; then
    pass_test
else
    fail_test "the no-op case still claims a successful deploy"
fi

start_test "and it names the case an operator actually cares about"
# "nothing changed" alone is not actionable. The reason someone runs a deploy is
# usually a new image, and an unchanged chart rolls nothing even when the image
# behind the tag has moved.
if _code_only "$LIB" | grep -qF 'it did NOT'; then
    pass_test
else
    fail_test "nothing warns that an expected image change did not take effect"
fi

start_test "a no-op is NOT an error"
# Going red on a healthy no-op would be a worse defect than the one being fixed.
if _code_only "$LIB" | grep -A2 'nothing changed' | grep -qE 'log_(error|warn)'; then
    fail_test "a healthy no-op is reported as a warning or error"
else
    pass_test
fi

start_test "'could not tell' is its own answer, not folded into either"
# A service with no namespace, or one kubectl cannot reach, must not be reported
# as rolled OR as unchanged.
if _code_only "$LIB" | grep -qF 'could not tell'; then
    pass_test
else
    fail_test "an unknown comparison is being reported as a fact"
fi

print_summary
