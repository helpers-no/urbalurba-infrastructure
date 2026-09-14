#!/bin/bash
# test-dagster-run-launch-unknown.sh — a launch is a SIDE EFFECT
#
# 🔴 `uis dagster run transform_checks --wait` reported
#
#     "Launch did not return a run id (rc=0). "
#
# rc 0, and nothing after it: stdout was EMPTY. The mutation had succeeded and
# the job was running. imac read exit 2 as "it did not run" and ran it again —
# two invocations, three concurrent runs of the ~649-test dbt suite on a 3-CPU
# VM (imac via ops-dev, urb-agents#1052).
#
# ⚠️ THE SECOND-ORDER COST IS WORSE THAN THE DUPLICATE WORK. Three dbt suites
# contending for one database can make a check fail, and that failure is an
# artefact of the duplicate launches rather than a finding about the data. A
# false launch failure can manufacture a false check failure.
#
# 🔵 The assertion was right to refuse to claim a success it could not parse.
# What was wrong is that "I could not read the answer" and "the answer was no"
# arrived as the same outcome — on a command whose failure mode is to do the
# expensive thing twice.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
PB="$REPO_ROOT/ansible/playbooks/362-dagster-run.yml"

PASS=0; FAIL=0
pass() { echo -e "  Testing: $1... \033[0;32mPASS\033[0m"; ((++PASS)); }
fail() { echo -e "  Testing: $1... \033[0;31mFAIL\033[0m"; echo -e "    \033[0;31m→ $2\033[0m"; ((++FAIL)); }

echo "=== an unreadable launch is not a failed launch ==="

[[ -f "$PB" ]] || { fail "playbook present" "missing: $PB"; echo; echo "  Passed: $PASS  Failed: $FAIL"; exit 1; }
pb="$(grep -v '^[[:space:]]*#' "$PB")"

if grep -q 'ansible.builtin.assert' <<<"$pb"; then
    pass "control: the comment-stripped scan still sees tasks"
else
    fail "control: the scan sees tasks" "stripping removed everything"
    echo ""; echo "  Passed: $PASS  Failed: $FAIL"; exit 1
fi

# 🔴 TWO DISTINCT ASSERTIONS. One outcome for "no body" and "body without the
# marker" is what made a running job read as a failed launch.
_empty="$(sed -n '/7a\./,/7b\./p' "$PB")"
_reject="$(sed -n '/7b\./,/8\./p' "$PB")"

if [[ -n "$_empty" && -n "$_reject" ]]; then
    pass "🔴 the empty-body case and the rejected case are separate assertions"
else
    fail "🔴 they are separate assertions" \
         "one outcome for both is how 'could not read' became 'did not run'"
fi

if grep -q 'trim | length > 0' <<<"$_empty"; then
    pass "the first one tests for a body at all, not for the marker"
else
    fail "the first tests for a body at all" "testing the marker first conflates the two cases"
fi

# 🔴 THE LOAD-BEARING SENTENCE: a run MAY have been launched.
if grep -qi 'MAY HAVE BEEN LAUNCHED' <<<"$_empty"; then
    pass "🔴 it says a run MAY have been launched — not that the launch failed"
else
    fail "🔴 it says a run may have been launched" \
         "an operator told 'it did not run' runs it again, and launching is a side effect"
fi

if grep -qi 'DO NOT RUN THIS AGAIN WITHOUT LOOKING' <<<"$_empty"; then
    pass "🔴 and tells the operator not to retry blindly"
else
    fail "🔴 it warns against a blind retry" \
         "the whole cost of this defect was the retry, not the parse"
fi

if grep -q 'template progress' <<<"$_empty"; then
    pass "and names how to check before retrying"
else
    fail "it names how to check first" "a warning with no way to act is the correct-and-unreachable shape"
fi

# ⚠️ The rejected case must say the opposite: no run started, retry is safe.
if grep -qi 'no run was started and re-running is safe' <<<"$_reject"; then
    pass "⚠️ a REJECTED launch says no run started, so a retry is safe"
else
    fail "⚠️ a rejected launch says a retry is safe" \
         "leaving both cases ambiguous makes the operator guess in the expensive direction"
fi

# 🔴 IT MUST SHOW WHAT IT LOOKED AT. The original failure reported that it did
# not find the marker without showing the body — the could-not-look shape. Had
# it printed the stdout, imac would have seen LaunchRunSuccess and not re-run.
if grep -q '_launch.stdout' <<<"$_reject" && grep -q '_launch.stderr' <<<"$_reject"; then
    pass "🔴 the rejected case shows the body AND stderr it judged"
else
    fail "🔴 it shows what it judged" "reporting 'marker not found' without the text is unactionable"
fi

if grep -q '_launch.stderr' <<<"$_empty"; then
    pass "and the empty case shows stderr, which is where the phase is"
else
    fail "the empty case shows stderr" "an empty body with no diagnostics leaves nothing to act on"
fi

# ⚠️ The probe pod's PHASE is the evidence that distinguishes "finished with no
# output" from "not finished yet" — reading logs from a running pod returns
# whatever has been written, which for a slow mutation is nothing.
if grep -q 'UIS_LAUNCH_PHASE' <<<"$pb"; then
    pass "⚠️ the launch reports the probe pod's phase"
else
    fail "⚠️ the launch reports the pod phase" \
         "without it, 'empty' cannot be told from 'not finished'"
fi

if grep -q 'UIS_LAUNCH_PHASE' <<<"$_empty"; then
    pass "and the empty-body failure quotes it"
else
    fail "the empty-body failure quotes the phase" "the evidence is collected and not shown"
fi

# 🔴 AND THE LAUNCH MUST NOT BE RETRIED BY THE PLAYBOOK ITSELF. A retry on a
# non-idempotent mutation is a second run, silently.
# ⚠️ THE WHOLE TASK, not up to `register:`. The first version scanned
# `/6. Launch the run/,/register: _launch/` — and `retries:` in Ansible can sit
# AFTER `register:`, so adding one escaped the assertion entirely. A range that
# stops early reports absence it has not established; seventh
# pattern-versus-target mismatch today, and the second about a RANGE rather than
# a token.
_launch_task="$(awk '/6\. Launch the run/,0' "$PB" | awk 'NR>1 && /^    - name: /{exit} {print}')"
if ! grep -qE '^\s+retries:' <<<"$_launch_task"; then
    pass "🔴 the launch task has no retries — a retried mutation is a second run"
else
    fail "🔴 the launch task has no retries" \
         "Ansible retrying a launch launches again; idempotence is not a property of this call"
fi

echo ""
echo "  Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
