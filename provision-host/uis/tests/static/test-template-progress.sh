#!/bin/bash
# test-template-progress.sh — `uis template progress <id>`
#
# 🔴 WHY IT EXISTS. Terje asked for status during a cold install and nothing
# answered. `uis template check` correctly returns COULD NOT BE ASKED while the
# marts tables do not exist yet — a red ✗ that reads as breakage to an operator
# whose install is progressing perfectly. Every other status verb reports
# LIVENESS, which is green while the data is absent (ops-dev, urb-agents#1023).
#
# 🔴 THE RED CASE IS THE POINT OF THIS FILE. imac's reference implementation
# handles a FAILED first-data job and said plainly it had never exercised that
# path — no job failed on its run. A failure rendering as "in flight", or
# absorbed into a progress count, is the defect that would make this verb worse
# than silence. So it is driven here against synthetic payloads, which is the
# only surface where a failure can be produced on demand.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
LIB="$REPO_ROOT/provision-host/uis/lib/template.sh"

PASS=0; FAIL=0; SKIP=0
pass() { echo -e "  Testing: $1... \033[0;32mPASS\033[0m"; ((++PASS)); }
fail() { echo -e "  Testing: $1... \033[0;31mFAIL\033[0m"; echo -e "    \033[0;31m→ $2\033[0m"; ((++FAIL)); }
skip() { echo -e "  Testing: $1... \033[0;33mSKIP\033[0m"; ((++SKIP)); }

echo "=== template progress: four states, and a failure that cannot hide ==="

if ! command -v jq >/dev/null 2>&1; then
    skip "jq is available to run the classifier"
    echo ""; echo "  Passed: $PASS  Failed: $FAIL  Skipped: $SKIP"; exit 0
fi

eval "$(sed -n '/^_progress_classify() {/,/^}$/p' "$LIB")"
eval "$(sed -n '/^_progress_summary() {/,/^}$/p' "$LIB")"
eval "$(sed -n '/^_progress_automation_line() {/,/^}$/p' "$LIB")"

if declare -F _progress_classify >/dev/null && declare -F _progress_summary >/dev/null \
   && declare -F _progress_automation_line >/dev/null; then
    pass "control: the classifier, summary and automation line loaded from the real lib"
else
    fail "control: the three functions loaded" "the sed extraction matched nothing — every assertion below is vacuous"
    echo ""; echo "  Passed: $PASS  Failed: $FAIL  Skipped: $SKIP"; exit 1
fi

JOBS="a_refresh b_refresh c_bootstrap d_feed"

_runs() { printf '{"data":{"runsOrError":{"results":[%s]}}}' "$1"; }
_r() { printf '{"jobName":"%s","status":"%s","startTime":%s,"endTime":%s}' "$1" "$2" "${3:-100}" "${4:-null}"; }

# ── 🔴 THE RED CASE ─────────────────────────────────────────────────────────
# ⚠️ CLASSIFY OUTSIDE THE SUBSHELL. `out="$(_progress_classify ...)"` runs it in
# a subshell and discards every PROG_* global it sets — the identical mistake
# this morning's --version test made, where the assertions reading a FILE passed
# and the one reading VARIABLES failed. Four of these failed the same way before
# it was fixed.
_progress_classify "$(_runs "$(_r a_refresh SUCCESS 100 160),$(_r b_refresh FAILURE 200 240)")" "$JOBS"
out="$(_progress_summary)"; rc=$?
if [[ "$PROG_FAILED" == "1" && "$PROG_FAILED_NAMES" == "b_refresh "* ]]; then
    pass "🔴 a FAILED job is counted as failed and NAMED"
else
    fail "🔴 a failed job is counted and named" "failed=$PROG_FAILED names='$PROG_FAILED_NAMES'"
fi

# ⚠️ MATCHES THE CLAIM, NOT A WORD THAT APPEARS NEARBY. The first version
# checked for "stuck", which also occurs in the following sentence ("stuck until
# that job is fixed") — so replacing the CLAIM with "is progressing fine" left
# this green. Third time today an assertion of mine matched something other than
# what it targeted; caught by mutating the sentence it is about.
if [[ "$out" == *"FAILED: b_refresh"* && "$out" == *"NOT progressing"*       && "$out" != *"progressing fine"* && "$out" != *"still loading"* ]]; then
    pass "🔴 the summary says the install is STUCK, not progressing"
else
    fail "🔴 the summary says STUCK" "a failure that reads as progress is worse than no command: $out"
fi

if [[ "$rc" == "1" ]]; then
    pass "🔴 a failed first-data job exits 1 — a script can act on it"
else
    fail "🔴 a failed job exits 1" "got rc=$rc; exit 0 makes the failure invisible to automation"
fi

# ⚠️ And the failure must not be absorbed into another count.
if [[ "$PROG_RUNNING" == "0" && "$PROG_DONE" == "1" && "$PROG_ABSENT" == "2" ]]; then
    pass "⚠️ the failed job is not also counted as in flight, done or absent"
else
    fail "⚠️ the failed job is not double-counted" "done=$PROG_DONE running=$PROG_RUNNING absent=$PROG_ABSENT"
fi

# ── P1: four states, never "N of M" ─────────────────────────────────────────
_progress_classify "$(_runs "$(_r a_refresh SUCCESS 100 160),$(_r b_refresh STARTED 200)")" "$JOBS"
out="$(_progress_summary)"
if [[ "$out" == *"1 succeeded"* && "$out" == *"0 failed"* && "$out" == *"1 in flight"* && "$out" == *"2 not started"* ]]; then
    pass "🔴 all FOUR states are counted, including not-started"
else
    fail "🔴 all four states are counted" "'N of M done' drops what has not started: $out"
fi

if [[ "$out" != *" of 4 "* || "$out" == *"not started"* ]]; then
    pass "it does not reduce the answer to a fraction"
else
    fail "it does not reduce the answer to a fraction" "a fraction hides the state a fresh install lives in"
fi

# ── P2: the red ✗ is expected, and that sentence is the whole point ─────────
if [[ "$out" == *"uis template check"* && "$out" == *"EXPECTED"* ]]; then
    pass "🔴 while loading, it says a red x from \`template check\` is EXPECTED"
else
    fail "🔴 it says a red x from check is expected" "that sentence is the entire reason the command exists: $out"
fi

# ── nothing has run: not-started is a state, not an error ───────────────────
_progress_classify "$(_runs "")" "$JOBS"
out="$(_progress_summary)"; rc=$?
if [[ "$PROG_ABSENT" == "4" && "$rc" == "0" && "$out" == *"do NOT self-trigger"* ]]; then
    pass "a fresh install reads as 'nothing has run yet', exit 0, and says jobs do not self-trigger"
else
    fail "a fresh install reads as nothing-has-run" "absent=$PROG_ABSENT rc=$rc"
fi

# ── all done: loaded is not running ─────────────────────────────────────────
_progress_classify "$(_runs "$(_r a_refresh SUCCESS 1 2),$(_r b_refresh SUCCESS 1 2),$(_r c_bootstrap SUCCESS 1 2),$(_r d_feed SUCCESS 1 2)")" "$JOBS"
out="$(_progress_summary)"
if [[ "$out" == *"Every first-data job has succeeded"* && "$out" == *"STOPPED"* ]]; then
    pass "⚠️ 'every job succeeded' also says automation is still STOPPED"
else
    fail "⚠️ all-succeeded says automation is still stopped" "'loaded' is not 'running': $out"
fi

# ── a re-run after a failure reads as its CURRENT state ─────────────────────
# ⚠️ Latest by startTime, not worst-ever. An operator who fixed and re-ran must
# not be told it is still stuck.
_progress_classify "$(_runs "$(_r b_refresh FAILURE 100 140),$(_r b_refresh SUCCESS 900 960)")" "b_refresh"
if [[ "$PROG_DONE" == "1" && "$PROG_FAILED" == "0" ]]; then
    pass "a job re-run after failing reads as succeeded, not as its worst ever run"
else
    fail "a re-run reads as its current state" "done=$PROG_DONE failed=$PROG_FAILED"
fi

# ── an unknown status is not silently folded into a state it is not ─────────
_progress_classify "$(_runs "$(_r a_refresh SOMETHING_NEW 100)")" "a_refresh"
if [[ "$PROG_DONE" == "0" && "$PROG_FAILED" == "0" && "$PROG_LINES" == *"does not recognise"* ]]; then
    pass "⚠️ a status this release does not know is named, not counted as succeeded"
else
    fail "⚠️ an unknown status is named" "done=$PROG_DONE lines=$PROG_LINES"
fi

# ── P5: a job Dagster ran that the definition does not declare ──────────────
_progress_classify "$(_runs "$(_r a_refresh SUCCESS 1 2),$(_r mystery_job SUCCESS 1 2)")" "$JOBS"
out="$(_progress_summary)"
if [[ "$PROG_UNDECLARED" == *"mystery_job"* && "$out" == *"does not declare"* ]]; then
    pass "🔵 a job Dagster ran that the definition does not declare is NAMED"
else
    fail "🔵 an undeclared job is named" "silently preferring either list hides a real disagreement"
fi

# ── P4: unreadable is not 'nothing running' ─────────────────────────────────
out="$(_progress_automation_line "")"
if [[ "$out" == *"could not read"* && "$out" != *"0 RUNNING"* ]]; then
    pass "🔴 an unreadable automation payload says so — it does not print '0 RUNNING'"
else
    fail "🔴 unreadable automation says so" "'0 running' from no data is a claim, and the wrong one: $out"
fi

_auto='{"data":{"repositoriesOrError":{"nodes":[{"schedules":[{"name":"s1","scheduleState":{"status":"STOPPED"}}],"sensors":[{"name":"x1","sensorState":{"status":"RUNNING"}}]}]}}}'
out="$(_progress_automation_line "$_auto")"
if [[ "$out" == *"1 RUNNING, 1 STOPPED, of 2 declared"* ]]; then
    pass "automation counts schedules and sensors together, as the other verb does"
else
    fail "automation counts both kinds" "got: $out"
fi

_auto0='{"data":{"repositoriesOrError":{"nodes":[{"schedules":[{"name":"s1","scheduleState":{"status":"STOPPED"}}],"sensors":[]}]}}}'
out="$(_progress_automation_line "$_auto0")"
if [[ "$out" == *"Nothing is switched on"* && "$out" == *"--start"* ]]; then
    pass "all-stopped points at the verb that switches them on"
else
    fail "all-stopped points at --start" "got: $out"
fi

# ── P4 in the command itself: the probe's failure must exit 2 ───────────────
_cmd="$(sed -n '/^cmd_template_progress() {/,/^}$/p' "$LIB" | grep -v '^[[:space:]]*#')"
if grep -q 'COULD NOT ASK' <<<"$_cmd" && grep -q 'return 2' <<<"$_cmd"; then
    pass "🔴 an unreachable Dagster exits 2 — not 'nothing has run yet'"
else
    fail "🔴 an unreachable Dagster exits 2" \
         "rendering an unreachable orchestrator as no-progress is the worst failure this verb has"
fi

# ⚠️ P3: the orchestrator, not the code location's defs. Same lesson as the
# default automation sensor, which defs.sensors does not list.
if grep -q 'runsOrError' <<<"$_cmd" || grep -q 'runsOrError' "$LIB"; then
    pass "⚠️ it reads Dagster's run history, not the code location's declarations"
else
    fail "⚠️ it reads the orchestrator" "defs miss what Dagster itself supplies"
fi

# ⚠️ P5's first half: the declared order comes from the ARTIFACT, not a list here.
if grep -q 'first_data.jobs' <<<"$_cmd"; then
    pass "⚠️ the first-data order is read from the artifact, not hardcoded"
else
    fail "⚠️ the order is read from the artifact" \
         "a hardcoded list in the platform is the thing that drifts from the tenant"
fi

# ── measured elapsed, because prose goes stale and wall time does not ───────
# 🔴 A cold install measured 29.5 min against an estimate of ~11. An operator
# told 11 minutes who is 25 minutes in cannot tell SLOW from STUCK (ops-dev,
# #1026) — and that is the same gap Terje hit asking for a status command.
#
# ⚠️ `now` is passed in. A classifier that read the clock could not be tested
# against a fixture twice and get the same answer.
_progress_classify "$(_runs "$(_r a_refresh SUCCESS 1000 1300),$(_r b_refresh STARTED 1400)")" "$JOBS" 2000
if [[ "$PROG_ELAPSED" == "1000" ]]; then
    pass "🔴 elapsed runs from the first start to NOW while anything is in flight"
else
    fail "🔴 elapsed runs to now while in flight" "got '$PROG_ELAPSED', wanted 1000 (2000 - 1000)"
fi

if [[ "$PROG_LINES" == *"600s so far"* ]]; then
    pass "🔴 an in-flight job shows how long it has been running, not a blank"
else
    fail "🔴 an in-flight job shows its elapsed" "a job with no duration is indistinguishable from a stuck one: $PROG_LINES"
fi

_progress_classify "$(_runs "$(_r a_refresh SUCCESS 1000 1300),$(_r b_refresh SUCCESS 1400 1900)")" "$JOBS" 9999
if [[ "$PROG_ELAPSED" == "900" ]]; then
    pass "once nothing is in flight, elapsed is first start to last end — not to now"
else
    fail "elapsed stops at the last end when nothing is running" "got '$PROG_ELAPSED', wanted 900"
fi

# ⚠️ The application's estimate is SHOWN, never corrected. Only the application
# can revise its own figure; the platform's job is to put measured wall time
# beside it so the reader need not trust either alone.
_progress_classify "$(_runs "$(_r a_refresh SUCCESS 1000 1300),$(_r b_refresh STARTED 1400)")" "$JOBS" 2000
out="$(_progress_summary '~11 minutes for the first four')"
if [[ "$out" == *"elapsed so far, measured from Dagster"* && "$out" == *"~11 minutes"* \
      && "$out" == *"prefer it"* ]]; then
    pass "⚠️ measured elapsed is shown beside the application's estimate, and preferred"
else
    fail "⚠️ measured elapsed is shown beside the estimate" "out=$out"
fi

# 🔴 And UIS must not rewrite a tenant's estimate. The figure lives in the
# artifact; only its author can revise it.
# ⚠️ COMMENTS STRIPPED. The first version of this scanned the whole file and
# tripped on the comment EXPLAINING why no estimate is hardcoded — the prose
# about a rule satisfying the check for the rule, inverted. Third time today.
if ! grep -v '^[[:space:]]*#' "$LIB" | grep -qE '11 minutes|29\.5 min'; then
    pass "🔴 no tenant time estimate is hardcoded in the platform"
else
    fail "🔴 no tenant estimate is hardcoded in the platform" \
         "a number copied out of an artifact is a second place that must agree"
fi

# ⚠️ With no runs at all there is nothing to time, and it must not print 0s.
_progress_classify "$(_runs "")" "$JOBS" 5000
out="$(_progress_summary 'some estimate')"
if [[ -z "$PROG_ELAPSED" && "$out" != *"elapsed"* ]]; then
    pass "⚠️ nothing started means no elapsed line, not '0s elapsed'"
else
    fail "⚠️ nothing started prints no elapsed line" "elapsed='$PROG_ELAPSED' out=$out"
fi

# ── still loading is not 'declares nothing' ─────────────────────────
# 🔴 Three minutes after install this said "Dagster declares no schedules or
# sensors — nothing to switch on" with FIVE declared and running. It is wrong in
# exactly the minutes `progress` is run, and it reads as permission to skip the
# step that makes every asset check ever run (imac via ops-dev, #1152/#1146).
_autoload='{"data":{"repositoriesOrError":{"nodes":[]}}}'
out="$(_progress_automation_line "$_autoload")"
if [[ "$out" != *"nothing to switch on"* ]]; then
    pass "🔴 zero code locations is not reported as 'nothing to switch on'"
else
    fail "🔴 zero code locations is not 'nothing to switch on'" \
         "a location that has not loaded declares nothing; that is not the same claim: $out"
fi
if [[ "$out" == *"loading"* || "$out" == *"reported to Dagster yet"* ]]; then
    pass "⚠️ and it tells the operator to wait rather than to move on"
else
    fail "⚠️ it says to wait" \
         "without 'still loading' the operator leaves, and automation never gets switched on: $out"
fi

# ⚠️ AND THE TRUE CASE MUST SURVIVE. A loaded location that really declares
# nothing still has to say so — otherwise this trades one wrong sentence for
# another.
_autonone='{"data":{"repositoriesOrError":{"nodes":[{"schedules":[],"sensors":[]}]}}}'
out="$(_progress_automation_line "$_autonone")"
if [[ "$out" == *"nothing to switch on"* ]]; then
    pass "⚠️ a loaded location that declares none still says 'nothing to switch on'"
else
    fail "⚠️ the genuine 'declares none' case survives" "got: $out"
fi

# 🔴 A payload jq cannot read is not 'none' either. This branch used to catch
# an empty `counts` alongside 'of 0 declared', one line below the comment saying
# an empty payload must never print a count.
out="$(_progress_automation_line '{"data":{"repositoriesOrError":{"nodes":[{"schedules":"not-an-array"}]}}}')"
if [[ "$out" != *"nothing to switch on"* ]]; then
    pass "🔴 an unparseable payload is not reported as 'declares none'"
else
    fail "🔴 unparseable is not 'declares none'" "a claim from a jq failure: $out"
fi

# ── the elapsed window says where it starts ────────────────────────
# 🔴 "143794s elapsed so far (2397 min)" was measured from an install two days
# earlier on an upgraded host, under a line telling the operator to prefer it
# over the estimate. Dagster's run history survives an upgrade; the figure does
# not say so (ops-dev, #1152).
_progress_classify "$(_runs "$(_r a_refresh SUCCESS 1000000 1000600)")" "$JOBS" 2000000
if [[ "$PROG_WINDOW_FROM" == "1000000" ]]; then
    pass "🔴 the classifier reports where the elapsed window opens"
else
    fail "🔴 the window start is reported" "got '$PROG_WINDOW_FROM'; without it the summary cannot say"
fi
out="$(_progress_summary 'about 11 minutes')"
if [[ "$out" == *"1970-01-12"* || "$out" == *"epoch 1000000"* ]]; then
    pass "⚠️ and the summary prints it as an absolute date the reader can check"
else
    fail "⚠️ the summary prints the window start" \
         "a bare duration reads as 'this install' on a host where it is not: $out"
fi
if [[ "$out" == *"not this install"* ]]; then
    pass "⚠️ it says the window is every recorded run, not this install"
else
    fail "⚠️ it names what the window covers" "got: $out"
fi
# 🔴 AND 'PREFER IT' IS NO LONGER UNCONDITIONAL. That instruction is what
# turned a wide window into a wrong conclusion.
if [[ "$out" == *"prefer it"* && "$out" == *"WHEN its window starts at this install"* ]]; then
    pass "🔴 'prefer it' carries the condition under which it is true"
else
    fail "🔴 'prefer it' is qualified" \
         "unconditional, it tells the operator to trust the figure this fix exists to qualify: $out"
fi

# ── 🔴 "COULD NOT ASK" MUST NAME THE LIKELIEST CAUSE ─────────────────
# The message listed an unreachable orchestrator, a wrong kube context and an
# RBAC denial — all real, all rarer than the one it omitted. This query is served
# by the webserver, whose `optimize_for_webserver` pool is 1 + 20 overflow; imac
# measured it pinned at its ceiling for 82% of a check-heavy launch window, with
# unrelated queries DENIED after 30 s (`QueuePool limit of size 1 overflow 20
# reached`), and nearly filed the resulting "hang" of this very command as a
# defect (urb-agents#1179).
#
# ⚠️ A launch in flight is a healthy thing to be doing. Sending the operator to
# look for a broken cluster is the same misattribution this command exists to
# avoid, one layer out.
_cmd_fn="$(sed -n '/^cmd_template_progress() {/,/^}$/p' "$LIB")"
if [[ -z "$_cmd_fn" ]]; then
    fail "the progress command is readable" "sed range matched nothing in $LIB"
elif grep -qi 'launching right now' <<<"$_cmd_fn" && grep -qi 'saturates' <<<"$_cmd_fn"; then
    pass "🔴 'could not ask' names a launch in flight as the likeliest cause"
else
    fail "🔴 'could not ask' names launch saturation" \
         "without it the operator hunts a broken cluster while Dagster is merely busy"
fi

# ⚠️ AND IT MUST NOT CALL THAT A FAULT. The whole point is that this state is
# expected; a message that names the cause and still reads as breakage has moved
# the error rather than fixed it.
if grep -qi 'it is not a fault' <<<"$_cmd_fn"; then
    pass "⚠️ and says plainly that it is not a fault"
else
    fail "⚠️ it says a launch in flight is not a fault" \
         "naming a cause without absolving it still reads as breakage"
fi

echo ""
echo "  Passed: $PASS  Failed: $FAIL  Skipped: $SKIP"
[[ "$FAIL" -eq 0 ]]
