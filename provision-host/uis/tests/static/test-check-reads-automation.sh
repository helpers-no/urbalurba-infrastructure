#!/bin/bash
# test-check-reads-automation.sh — a healthy verdict on a stopped pipeline
#
# 🔴 FALSE ALL-CLEAR. `uis template check atlas` reported healthy, exit 0, and
# told the operator "3 newer deletion(s) awaiting the next transform (:10/:40)
# — not a fault" while every schedule and sensor was STOPPED. There is no next
# transform. The sentence is not incomplete, it is FALSE (imac via ops-dev,
# urb-agents#1036).
#
# ⚠️ AND IT IS THE FIRST STATE EVERY OPERATOR IS IN: a fresh install ships
# stopped, so install → load first data → run the status command passes straight
# through it.
#
# 🔵 "A false alarm wastes attention, a false all-clear spends it." The sentence
# was added to FIX a false alarm and that fix was right — it asserts a future
# event without checking that anything is scheduled to produce it.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
LIB="$REPO_ROOT/provision-host/uis/lib/template.sh"

PASS=0; FAIL=0
pass() { echo -e "  Testing: $1... \033[0;32mPASS\033[0m"; ((++PASS)); }
fail() { echo -e "  Testing: $1... \033[0;31mFAIL\033[0m"; echo -e "    \033[0;31m→ $2\033[0m"; ((++FAIL)); }

echo "=== check must not relay a claim about the future without looking ==="

log_warn() { echo "WARN: $*" >&2; }
eval "$(sed -n '/^_check_qualify_by_automation() {/,/^}$/p' "$LIB")"

if declare -F _check_qualify_by_automation >/dev/null; then
    pass "control: the qualifier loaded from the real lib"
else
    fail "control: the qualifier loaded" "the sed extraction matched nothing — every assertion is vacuous"
    echo ""; echo "  Passed: $PASS  Failed: $FAIL"; exit 1
fi

_q() { AUTO_RUNNING="$1"; AUTO_TOTAL="$2"; QOUT="$(_check_qualify_by_automation "$3" 2>&1)"; QRC=$?; }

# ── 🔴 THE REPORTED DEFECT ───────────────────────────────────────────────────
_q 0 5 healthy
if [[ "$QRC" == "2" ]]; then
    pass "🔴 healthy + NOTHING running does not stay exit 0"
else
    fail "🔴 healthy + nothing running does not stay exit 0" \
         "got rc=$QRC — a script reading exit 0 gets a clean bill of health on a stopped pipeline"
fi

if [[ "$QOUT" == *"NOTHING IS RUNNING"* && "$QOUT" == *"0 of 5"* ]]; then
    pass "🔴 it says so in the output, with the counts"
else
    fail "🔴 it says so with counts" "out=$QOUT"
fi

# ⚠️ ops-dev's one assertion: the output must not let a claim about a scheduled
# event stand unqualified when nothing is scheduled.
if [[ "$QOUT" == *"assumes something is"* && "$QOUT" == *"Nothing is."* ]]; then
    pass "⚠️ it names the assumption the application's sentence was making"
else
    fail "⚠️ it names the assumption" \
         "'nothing is running' alone does not tell the reader which sentence above to distrust"
fi

if [[ "$QOUT" == *"not a clean bill of health"* && "$QOUT" == *"undecidable"* ]]; then
    pass "🔵 it says the question is UNANSWERABLE, not that the data is wrong"
else
    fail "🔵 it says the question is unanswerable" \
         "calling the application wrong would be a false alarm replacing a false all-clear: $QOUT"
fi

if [[ "$QOUT" == *"automation --start"* ]]; then
    pass "it names the command that fixes it"
else
    fail "it names the fix" "a warning with no remedy is the correct-and-unreachable shape"
fi

# ── the boundaries where UIS must NOT decide ────────────────────────────────
# 🔴 PARTIAL automation leaves the verdict alone. UIS cannot tell whether the
# stopped instigator is the one this check's claim depended on — only the
# application knows which one its own sentence refers to. Guessing would invent
# a new false alarm to replace the false all-clear.
_q 3 5 healthy
if [[ "$QRC" == "0" && "$QOUT" == *"3 of 5"* && "$QOUT" == *"cannot tell which instigator"* ]]; then
    pass "🔴 PARTIAL automation qualifies the output and does NOT change the verdict"
else
    fail "🔴 partial automation does not change the verdict" "rc=$QRC out=$QOUT"
fi

_q 5 5 healthy
if [[ "$QRC" == "0" && -z "$QOUT" ]]; then
    pass "everything running adds nothing — no noise on the normal path"
else
    fail "everything running adds nothing" "rc=$QRC out=$QOUT"
fi

# ⚠️ An already-unhealthy verdict is not downgraded to could-not-ask: exit 1
# already means look, and turning it into 2 would lose that.
_q 0 5 unhealthy
if [[ "$QRC" == "0" && "$QOUT" == *"NOTHING IS RUNNING"* ]]; then
    pass "⚠️ an unhealthy verdict keeps exit 1 and still gets the warning"
else
    fail "⚠️ unhealthy keeps exit 1" "rc=$QRC — exit 1 already means look; 2 would weaken it"
fi

# 🔴 COULD NOT LOOK IS NOT ZERO RUNNING. Rendering an unreadable state as
# "nothing is running" would be the defect this project has paid for repeatedly.
AUTO_RUNNING=""; AUTO_TOTAL=""
QOUT="$(_check_qualify_by_automation healthy 2>&1)"; QRC=$?
if [[ "$QRC" == "0" && "$QOUT" == *"Could not read"* && "$QOUT" != *"NOTHING IS RUNNING"* ]]; then
    pass "🔴 an unreadable automation state says 'could not look', not 'nothing is running'"
else
    fail "🔴 unreadable is not zero-running" "rc=$QRC out=$QOUT"
fi

if [[ "$QOUT" == *"not 'nothing is running'"* ]]; then
    pass "and it says which of the two it is, in the output"
else
    fail "it distinguishes the two in the output" "the reader cannot otherwise tell"
fi

# ── the read happens, and before the verdict is relayed ─────────────────────
_cmd="$(sed -n '/^cmd_template_check() {/,/^}$/p' "$LIB" | grep -v '^[[:space:]]*#')"
if grep -q '_check_automation_state' <<<"$_cmd"; then
    pass "check reads automation state"
else
    fail "check reads automation state" "the verdict is relayed without ever looking"
fi

_read_line="$(grep -n '_check_automation_state' <<<"$_cmd" | head -1 | cut -d: -f1)"
_healthy_line="$(grep -n 'reported success' <<<"$_cmd" | head -1 | cut -d: -f1)"
if [[ -n "$_read_line" && -n "$_healthy_line" && "$_read_line" -lt "$_healthy_line" ]]; then
    pass "🔴 it looks BEFORE relaying the verdict, not after"
else
    fail "🔴 it looks before relaying the verdict" "read at ${_read_line:-none}, relay at ${_healthy_line:-none}"
fi

# ⚠️ The reader must distinguish "0 running" from "could not look" — the
# function returns 1 rather than setting 0.
_st="$(sed -n '/^_check_automation_state() {/,/^}$/p' "$LIB" | grep -v '^[[:space:]]*#')"
if grep -q 'AUTO_RUNNING=""' <<<"$_st" && grep -qE 'return 1' <<<"$_st"; then
    pass "⚠️ the reader returns failure rather than reporting zero when it cannot look"
else
    fail "⚠️ the reader returns failure when it cannot look" \
         "setting 0 on a failed read is how 'unreachable' becomes 'nothing is running'"
fi

echo ""
echo "  Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
