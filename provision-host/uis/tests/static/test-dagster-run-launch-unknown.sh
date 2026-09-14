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
_empty="$(sed -n '/7a\. Distinguish/,/7b\./p' "$PB")"
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

# 🔴 REPLACED, AND THIS ONE ENFORCED THE REGRESSION.
#
# It required the rejected branch to say "no run was started and re-running is
# safe". Dagster created a run TWELVE SECONDS after such a failure, one per
# invocation (imac via ops-dev, urb-agents#1075) — so this assertion was
# demanding the unsafe wording and would have BLOCKED the fix.
#
# ⚠️ Fourth time today an assertion was right about the file and wrong about the
# world, and the first that actively required a defect. Replaced rather than
# deleted: a deleted control and a satisfied control look identical.
#
# 🔵 The rule it should have encoded: UIS must not assert the ABSENCE of a side
# effect it did not check — and here it cannot check, because the row may appear
# after any query it makes.
if ! grep -qi 'no run was started' <<<"$_reject"; then
    pass "🔴 a rejected launch NO LONGER claims no run was started"
else
    fail "🔴 a rejected launch does not claim no run was started" \
         "a PythonError can leave a run row; one appeared 12 s later, one per invocation"
fi

if ! grep -qi 're-running is safe' <<<"$_reject"; then
    pass "🔴 and does not tell the operator a retry is safe"
else
    fail "🔴 it does not call a retry safe" \
         "the conservative wording it replaced was the CORRECT one"
fi

# ⚠️ Both non-success branches must now give the same conservative instruction.
if grep -qi 'DO NOT RE-RUN WITHOUT LOOKING' <<<"$_reject" \
   && grep -qi 'DO NOT RUN THIS AGAIN WITHOUT LOOKING' <<<"$_empty"; then
    pass "⚠️ both non-success branches say check before retrying"
else
    fail "⚠️ both branches say check before retrying" \
         "one confident branch beside one conservative one is where the operator guesses wrong"
fi

# 🔵 ASKED, BUT NOT AS PROOF. The run list is queried and reported; "saw none"
# is stated as "none YET" because the row appeared 12 s after the call.
if grep -q 'runsOrError(limit' <<<"$pb"; then
    pass "🔵 the run list is queried after a failed launch"
else
    fail "🔵 the run list is queried" "asking is one call to the endpoint the launch just used"
fi

if grep -qi 'none YET' <<<"$_reject"; then
    pass "🔴 and an empty result is reported as 'none YET', not as 'none'"
else
    fail "🔴 an empty result is 'none yet'" \
         "a query that can be wrong seconds later cannot justify a safety claim"
fi

if grep -q '__unreadable__' <<<"$pb"; then
    pass "⚠️ an unreadable run list is its own outcome, not folded into 'none'"
else
    fail "⚠️ an unreadable run list is its own outcome" \
         "collapsing it is how an unread list becomes a claim of absence"
fi

# 🔴 ORPHANS DO NOT STAY INERT. ops-dev left three as a before-picture and
# Dagster reaped them to FAILURE — so an orphan pollutes the failure count
# without ever having executed, and anything reading run history as health sees
# it.
if grep -qi 'reaped to FAILURE' <<<"$_reject"; then
    pass "🔴 it warns that an orphan is later reaped to FAILURE"
else
    fail "🔴 it warns about the reaped orphan" \
         "a failure that never ran, counted as a failure, is a false signal nobody attributed"
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

# ── "Launched" must be an observation, not an assertion ─────────────────────
# 🔴 The launch call returning a run id was observed; that the run would be
# ENQUEUED and RUN was asserted and never checked. imac reported a run sitting
# at NOT_STARTED indefinitely, so "Launched" was the last thing the CLI said
# about a job that never moved (ops-dev, urb-agents#1052).
#
# 🔵 Same correction as 7a/7b, on the other side of the same command: an
# unverified consequence must not be printed as a fact.
if grep -q 'runOrError' <<<"$pb"; then
    pass "🔴 the run's own status is read after launching"
else
    fail "🔴 the status is read after launching" \
         "'Launched' asserts an outcome the launch call does not control"
fi

_msg="$(sed -n '/9\. Launched/,/^    # 🔴 --timeout/p' "$PB")"
if grep -q 'Dagster reports this run as' <<<"$_msg"; then
    pass "and the message reports what Dagster said, not what UIS hoped"
else
    fail "the message reports the status" "out=$_msg"
fi

# 🔴 NOT_STARTED gets its own explanation: created and not submitted, which is
# not a launch failure and not something UIS diagnoses.
if grep -q 'NOT_STARTED means the run was CREATED and not submitted' <<<"$_msg"; then
    pass "🔴 NOT_STARTED is explained as created-not-submitted"
else
    fail "🔴 NOT_STARTED is explained" \
         "a status an operator cannot interpret is the same as no status"
fi

# ⚠️ Pattern taken from the file, not from memory: the text reads "reporting it
# rather than diagnosing it", so 'not diagnosing it' matched nothing and failed
# a correct message. Eighth pattern-versus-target mismatch today — and the first
# where I had written the sentence myself minutes earlier.
# 🔵 REPLACED, NOT DELETED. This asserted that the message claims no cause,
# which was right while no cause was known. imac has since MEASURED it — a
# launch cut off mid-flight leaves an unsubmitted run — so the message now names
# that, and the assertion would otherwise enforce a weaker truth than the world
# has. Third time today an assertion was correct about the file and wrong about
# the world; replacing beats deleting, because a deleted control and a satisfied
# one look identical.
#
# ⚠️ THE LINE IS BETWEEN THE TWO CAUSES. Why the run is unsubmitted is
# measured. WHY THE CALL IS SLOW is imac's guess — 679 asset checks, plan
# resolution — and is labelled a guess, so the product must not assert it.
if grep -qF 'MEASURED CAUSE' <<<"$_msg"; then
    pass "🔵 it names the measured cause of an unsubmitted run"
else
    fail "🔵 it names the measured cause" "the mechanism is established and withholding it helps nobody"
fi

if ! grep -qiE 'asset check|plan resolution' <<<"$_msg"; then
    pass "⚠️ and still does NOT assert why the call is slow — that remains a guess"
else
    fail "⚠️ it does not assert the unestablished half" \
         "679 asset checks is imac's labelled guess; the product must not print it as fact"
fi

# 🔴 UNREADABLE IS ITS OWN VALUE. Collapsing it into a status would make an
# unreadable state indistinguishable from a real one — and the run WAS created,
# so the advice has to be 'do not relaunch'.
if grep -q "else 'unreadable'" <<<"$pb"; then
    pass "🔴 an unreadable status is its own value, not folded into a real one"
else
    fail "🔴 unreadable is its own value" "folding it in is the could-not-look defect again"
fi

if grep -q 'do not launch it again' <<<"$_msg"; then
    pass "and an unreadable status still says the run WAS created"
else
    fail "an unreadable status says the run was created" \
         "the id came back from Dagster; a relaunch would double the work"
fi

# ── the launch must not be cut off mid-flight ───────────────────────────────
# 🔴 THE MEASURED CAUSE OF EVERYTHING ON #1052. imac timed it:
# `launchPipelineExecution` returned in 0.5 s for api_v1_checks and had NOT
# returned after 300 s for transform_checks — 600x apart, against a hardcoded
# `curl -m 60`. A call cut off mid-flight leaves Dagster holding a run it never
# submitted, which then sits at NOT_STARTED forever (ops-dev, #1068).
#
# 🔵 So the reporting fixes were right and could never have fixed it. This is
# the cause; those were the symptom described honestly.
if ! grep -qE 'curl -s -m 60 -X POST' <<<"$pb"; then
    pass "🔴 the launch no longer has a hardcoded 60-second budget"
else
    fail "🔴 the launch has no hardcoded 60s budget" \
         "0.5 s for one job and >300 s for another, with 60 s between them"
fi

if grep -q 'curl -s -m {{ _launch_budget }}' <<<"$pb"; then
    pass "the budget comes from a variable, not a literal"
else
    fail "the budget comes from a variable" "a literal cannot follow the operator's deadline"
fi

# ⚠️ THE SECOND HARDCODED CAP. Raising the curl alone would not have helped:
# the pod-wait loop gave up after 60 x 2 s = 120 s and then read logs from a pod
# that had not finished, which returns nothing.
if ! grep -qE 'for i in \$\(seq 1 60\); do' <<<"$pb"; then
    pass "⚠️ the pod-wait loop is no longer capped at 120s either"
else
    fail "⚠️ the pod-wait loop is not separately capped" \
         "two independent caps, either of which cuts the launch off"
fi

# 🔴 AND THE POLL WINDOW MUST EXCEED THE CURL BUDGET, or the pod is still
# running when its logs are read — which is the empty body.
_vars="$(sed -n '/^  vars:/,/^  tasks:/p' "$PB")"
if grep -q '_launch_polls' <<<"$_vars" && grep -q '_launch_budget' <<<"$_vars"; then
    pass "🔴 the poll count is derived from the budget, in one place"
else
    fail "🔴 the poll count is derived from the budget" \
         "two numbers that must agree, computed apart, will not agree for long"
fi

# ⚠️ THE DIVISOR AND OFFSET ARE READ OUT OF THE PLAYBOOK, not retyped here.
#
# 🔴 The first version recomputed the invariant with its OWN formula — so it
# proved that MY arithmetic was sound and said nothing about the playbook's.
# Changing the playbook to `// 4`, which halves the poll window, left it green.
# That is the same defect as asserting a port against a file I also wrote:
# a test of a copy of the logic is not a test of the logic.
# ⚠️ ALL THREE NUMBERS, and the extraction was checked against the real line
# before being written here. A first attempt matched the INNER `+ 1` as the
# offset and a second matched nothing at all — so the positions are taken
# explicitly: first `+ N` is the inner term, last is the outer, and `// N` is
# the divisor.
_pollexpr="$(grep -F '_launch_polls:' "$PB")"
_pluses="$(grep -oE '\+ [0-9]+' <<<"$_pollexpr" | grep -oE '[0-9]+')"
_inner="$(head -1 <<<"$_pluses")"
_outer="$(tail -1 <<<"$_pluses")"
_div="$(grep -oE '// [0-9]+' <<<"$_pollexpr" | grep -oE '[0-9]+' | head -1)"
_bad=""
if [[ -z "$_div" || -z "$_inner" || -z "$_outer" || "$_inner" == "$_outer" ]]; then
    _bad="could not read three distinct numbers out of: $_pollexpr"
else
    for _t in 3600 900 300 61 30 2 1; do
        _b=$(( _t < 900 ? _t : 900 ))
        _p=$(( ((_b + _inner) / _div) + _outer ))
        (( _p * 2 > _b )) || _bad+="timeout=$_t (polls=$_p covers $((_p*2))s vs budget ${_b}s) "
    done
fi
if [[ -z "$_bad" ]]; then
    pass "⚠️ poll window exceeds the curl budget for every deadline (+$_inner ÷$_div +$_outer, read from the playbook)"
else
    fail "⚠️ poll window exceeds the curl budget" "fails at: ${_bad% }"
fi

# 🔵 The 900s cap is not invented — it is the number this platform already chose
# for this tenant's plan size, and the file has to say so or the next reader
# treats it as arbitrary.
if grep -q 'startTimeoutSeconds: 900' "$PB"; then
    pass "🔵 the cap cites the existing 900s precedent rather than asserting a number"
else
    fail "🔵 the cap cites its precedent" \
         "an unexplained timeout is the next thing someone raises without asking why"
fi

# ⚠️ And a smaller operator deadline must still win.
if grep -qF "[(_timeout | int), 900] | min" <<<"$_vars"; then
    pass "⚠️ a smaller --timeout is honoured, not silently overridden"
else
    fail "⚠️ a smaller --timeout is honoured" "someone who says 'give up after 30s' means it"
fi

# 🔴 Now that the cause is measured, the NOT_STARTED message names it — and says
# the orphan never starts, which changes what the operator should do.
if grep -q 'MEASURED CAUSE' <<<"$pb"; then
    pass "🔴 the messages attribute the measured cause, now that there is one"
else
    fail "🔴 the messages attribute the cause" \
         "1.6.103 correctly refused to guess; the guess is now a measurement"
fi

if grep -q 'never starts and is not retried' <<<"$pb"; then
    pass "and says an orphaned run never starts on its own"
else
    fail "it says an orphan never starts" "an operator who waits for it waits forever"
fi

# ── a diagnostic placed after the abort it diagnoses is not a diagnostic ────
# 🔴 1.6.105 put the run-list query AFTER 7a — an `assert` that fails hard and
# ends the play. So in the one branch that actually creates an orphan (empty
# body, the timeout path) the query never executed and the message could not
# name the run. imac proved it twice: a run created 18 s after the invocation,
# and ZERO run-id-shaped strings in the output (ops-dev, urb-agents#1078).
#
# ⚠️ And the "none YET, not none" wording — which came from imac's own +12 s
# measurement — lived past that abort and had never once been reached.
_probe_line="$(grep -n '7a1\. Ask whether a run' "$PB" | cut -d: -f1)"
_a_line="$(grep -n '7a\. Distinguish' "$PB" | cut -d: -f1)"
_b_line="$(grep -n '7b\. The launch must' "$PB" | cut -d: -f1)"
if [[ -n "$_probe_line" && -n "$_a_line" && "$_probe_line" -lt "$_a_line" ]]; then
    pass "🔴 the run-list query runs BEFORE the assertion that can end the play"
else
    fail "🔴 the query runs before the first assertion" \
         "query at ${_probe_line:-none}, first assert at ${_a_line:-none} — behind an abort it never executes"
fi

if [[ -n "$_probe_line" && -n "$_b_line" && "$_probe_line" -lt "$_b_line" ]]; then
    pass "and before the second one too, so both branches can name the run"
else
    fail "it runs before both assertions" "query at ${_probe_line:-none}, 7b at ${_b_line:-none}"
fi

# 🔴 THE EMPTY-BODY BRANCH IS THE ONE THAT CREATES THE ORPHAN, so it is the one
# that most needs to name it.
if grep -q '_recent_runs' <<<"$_empty"; then
    pass "🔴 the empty-body branch reports the run list, not just the rejected branch"
else
    fail "🔴 the empty-body branch reports the run list" \
         "that is the branch where an orphan is actually created"
fi

if grep -qi 'A RUN ALREADY EXISTS' <<<"$_empty"; then
    pass "and names it outright when one is found"
else
    fail "it names a found run outright" "a generic 'may have' when the id is known is a withheld answer"
fi

# ── silence is what makes an operator do the thing the message warns against ─
# 🔴 A bare `uis dagster run <job>` sat in the launch task at TEN MINUTES with
# nothing printed. imac killed it at 900 s having seen no message at all — and
# the kill is what created an orphan.
#
# ⚠️ The wait itself is correct: shortening the budget is what cut the launch off
# in the first place. What was wrong is that it was experienced as silence.
_pre="$(sed -n '/5c\. Say how long/,/6\. Launch the run/p' "$PB")"
if [[ -n "$_pre" ]] && grep -q 'waiting up to' <<<"$_pre"; then
    pass "🔴 the wait is announced BEFORE it is waited"
else
    fail "🔴 the wait is announced before it happens" \
         "up to 900s of silence, and the impatient response creates an orphan"
fi

if grep -qi 'not a hang' <<<"$_pre"; then
    pass "and says explicitly that it is not a hang"
else
    fail "it says it is not a hang" "an operator cannot distinguish a long wait from a hang without being told"
fi

if grep -qi 'If you interrupt this' <<<"$_pre"; then
    pass "🔴 and warns that interrupting may leave a run behind"
else
    fail "🔴 it warns about interrupting" \
         "the kill is what created the orphan; the warning belongs before the wait, not after"
fi

# ⚠️ The announced number must be the budget actually used, not a literal.
if grep -q '_launch_budget' <<<"$_pre"; then
    pass "⚠️ it announces the budget variable, so the number cannot drift"
else
    fail "⚠️ it announces the budget variable" "a hardcoded number in the notice will disagree with the wait"
fi

echo ""
echo "  Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
