#!/bin/bash
# test-dagster-run-timeout.sh — `--timeout N` must mean N seconds of wall clock.
#
# 🔴 It used to mean "poll N/10 times". `retries: timeout / 10` with `delay: 10`
# counts ITERATIONS and silently assumes each costs only the delay — but every
# iteration also launches a probe pod, waits for it to terminate, reads its logs
# and deletes it. imac measured the consequence on the acceptance host:
# `--timeout N` waited about 2.6 x N (#719).
#
# ⚠️ The drift is host-dependent, so it is largest exactly where the host is
# slowest and the operator has least ability to predict it. A budget must be
# enforced in the unit it is expressed in.
#
# This is a STATIC test: it asserts the shape of the enforcement. The semantics
# — that the guard fires on a passed deadline and not on a future one — were
# verified by executing the rendered fragment under dash.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAYBOOK="$(cd "$SCRIPT_DIR/../../../.." && pwd)/ansible/playbooks/362-dagster-run.yml"

PASS=0; FAIL=0
pass() { echo -e "  Testing: $1... \033[0;32mPASS\033[0m"; ((++PASS)); }
fail() { echo -e "  Testing: $1... \033[0;31mFAIL\033[0m"; echo -e "    \033[0;31m→ $2\033[0m"; ((++FAIL)); }

echo "=== uis dagster run: the wait budget ==="

if [[ ! -f "$PLAYBOOK" ]]; then
    fail "playbook present" "not found: $PLAYBOOK"
    echo ""; echo "  Passed: $PASS  Failed: $FAIL"; exit 1
fi

body="$(cat "$PLAYBOOK")"
# Comments explain the defect by naming it; they must not satisfy the assertions.
code="$(grep -v '^[[:space:]]*#' "$PLAYBOOK")"

# ── positive control ───────────────────────────────────────────────────────────
if grep -q 'ansible.builtin.shell' <<<"$code"; then
    pass "control: the code scan sees the playbook's tasks"
else
    fail "control: the code scan sees the playbook's tasks" "comment stripping removed everything"
fi

# ── the deadline exists and is absolute ────────────────────────────────────────
if grep -q '_poll_deadline' <<<"$code"; then
    pass "a wall-clock deadline is computed"
else
    fail "a wall-clock deadline is computed" "no _poll_deadline in the playbook"
fi

if grep -qE '_poll_deadline:.*\(_now \| int\) \+ \(_timeout \| int\)' <<<"$code"; then
    pass "the deadline is start + timeout, in seconds"
else
    fail "the deadline is start + timeout, in seconds" "deadline is not derived from _timeout as seconds"
fi

if grep -qE 'date \+%s.*-ge \{\{ _poll_deadline \}\}' <<<"$code"; then
    pass "🔴 the poll checks the clock against the deadline"
else
    fail "🔴 the poll checks the clock against the deadline" \
         "the poll body does not compare date +%s to _poll_deadline"
fi

# ── retries must NOT be the budget ─────────────────────────────────────────────
if grep -qE 'retries:.*_timeout \| int / 10' <<<"$code"; then
    fail "🔴 retries is not the budget" \
         "retries is still timeout/10 — that is the iteration-count bug, not a deadline"
else
    pass "🔴 retries is not the budget"
fi

if grep -qE 'retries:.*_timeout' <<<"$code" && grep -qE 'retries:.*/ 5' <<<"$code"; then
    pass "retries remains a backstop above what the deadline can consume"
else
    fail "retries remains a backstop above what the deadline can consume" \
         "expected a retry count derived at a shorter interval than the delay"
fi

# ── giving up is not succeeding ────────────────────────────────────────────────
if grep -q 'deadline-exceeded' <<<"$code"; then
    pass "the poll emits a distinct marker when the budget runs out"
else
    fail "the poll emits a distinct marker when the budget runs out" "no deadline-exceeded marker"
fi

# The marker must end the until-loop.
# ⚠️ `grep -q` PRINTS NOTHING, so `grep -q ... | grep ...` is always false — the
# first version of this assertion was that, and it failed against correct code.
until_block="$(grep -A4 'until:' <<<"$code")"
if grep -q 'deadline-exceeded' <<<"$until_block"; then
    pass "the marker ends the wait"
else
    fail "the marker ends the wait" "until: does not mention the deadline marker"
fi

# The marker and the real terminal states must be SEPARATE conditions: a run
# status of SUCCESS/FAILURE/CANCELED is an answer, the marker is the absence of
# one, and collapsing them would make a timeout indistinguishable from a result.
if grep -q 'deadline-exceeded' <<<"$until_block" \
   && grep -q 'SUCCESS|FAILURE|CANCELED' <<<"$until_block" \
   && grep -q ' or$\| or ' <<<"$until_block"; then
    pass "the marker is a separate condition from a real terminal state"
else
    fail "the marker is a separate condition from a real terminal state" \
         "until: $until_block"
fi

fail_task="$(awk '/12\. A wait that never reached a terminal state/,/^    - name: "13/' "$PLAYBOOK")"
if grep -q 'SUCCESS|FAILURE|CANCELED' <<<"$fail_task"; then
    pass "🔴 a deadline-exceeded wait still fails the command"
else
    fail "🔴 a deadline-exceeded wait still fails the command" \
         "task 12 no longer gates on a real terminal state"
fi

if grep -q 'waited' <<<"$fail_task"; then
    pass "the timeout message reports how long it actually waited"
else
    fail "the timeout message reports how long it actually waited" \
         "a budget that drifted is only visible if the real elapsed time is printed"
fi

# ── the probe body stays POSIX: ansible.builtin.shell is /bin/sh ───────────────
if grep -q '\$RANDOM' <<<"$code"; then
    fail "no \$RANDOM in the poll body" "dash expands \$RANDOM to nothing — the 1.6.46 defect"
else
    pass "no \$RANDOM in the poll body"
fi

if grep -qE 'if \[\[ ' <<<"$code"; then
    fail "the shell bodies use POSIX tests" "[[ ]] is a bashism; ansible.builtin.shell runs /bin/sh"
else
    pass "the shell bodies use POSIX tests"
fi

echo ""
echo "  Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
