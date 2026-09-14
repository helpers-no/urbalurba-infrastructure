#!/bin/bash
# test-dagster-automation-start.sh — `uis dagster automation --start|--stop`
#
# 🔴 THE CLI USED TO SEND THE OPERATOR TO A WEB UI. Its own banner said UIS
# "can report that state but cannot change it", so a correctly installed
# application fetched nothing until someone clicked — while every UIS signal
# read green (ops-dev, urb-agents#991).
#
# 🔴 AND THE SCHEMA CANNOT CATCH A WRONG CALL. imac introspected dagster-1.13.19:
# every argument of `stopRunningSchedule` and `stopSensor` is NULLABLE, so a call
# supplying none of them type-checks, does nothing, and reports success. The
# re-read is not a nicety — it is the only detector.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
PB="$REPO_ROOT/ansible/playbooks/361-dagster-automation.yml"
CLI="$REPO_ROOT/provision-host/uis/manage/uis-cli.sh"

PASS=0; FAIL=0
pass() { echo -e "  Testing: $1... \033[0;32mPASS\033[0m"; ((++PASS)); }
fail() { echo -e "  Testing: $1... \033[0;31mFAIL\033[0m"; echo -e "    \033[0;31m→ $2\033[0m"; ((++FAIL)); }

echo "=== dagster automation can be switched on, and cannot lie about it ==="

for f in "$PB" "$CLI"; do
    [[ -f "$f" ]] || { fail "files present" "missing: $f"; echo; echo "  Passed: $PASS  Failed: $FAIL"; exit 1; }
done

# Comments name the defects; they must not satisfy the assertions.
pb="$(grep -v '^[[:space:]]*#' "$PB")"
cli="$(grep -v '^[[:space:]]*#' "$CLI")"

if grep -q 'ansible.builtin.assert' <<<"$pb" && grep -q 'cmd_dagster_automation' <<<"$cli"; then
    pass "control: the comment-stripped scans still see code"
else
    fail "control: the comment-stripped scans still see code" "stripping removed everything"
    echo; echo "  Passed: $PASS  Failed: $FAIL"; exit 1
fi

# ── the signatures imac measured, not the ones symmetry suggests ─────────────
if grep -q 'stopRunningSchedule' <<<"$pb" && ! grep -qE 'stopSchedule\(' <<<"$pb"; then
    pass "🔴 stop uses stopRunningSchedule — stopSchedule does not exist on 1.13.19"
else
    fail "🔴 stop uses stopRunningSchedule" "stopSchedule would fail on the deployed chart"
fi

if grep -q 'startSchedule(scheduleSelector' <<<"$pb" && grep -q 'startSensor(sensorSelector' <<<"$pb"; then
    pass "start uses the selector inputs, one per kind"
else
    fail "start uses the selector inputs" "the two are not interchangeable"
fi

# ⚠️ repositoryName is the literal __repository__ for a code location that
# declares no repository, and repositoryLocationName is the CODE-LOCATION name.
# Neither is the application id, and neither is guessable.
if grep -q 'repositoryName:' <<<"$pb" && grep -q 'repositoryLocationName:' <<<"$pb"; then
    pass "the selector carries both repository and location names"
else
    fail "the selector carries both names" "a selector missing either is rejected"
fi

# 🔴 Not hardcoded: the values come from the enumeration, because __repository__
# is what THIS install produces and another may differ.
_sel="$(grep -o 'repositoryName:[^,]*' <<<"$pb" | head -1)"
if [[ "$_sel" == *'{{'* || "$_sel" == *'i.repo'* ]]; then
    pass "🔴 the repository name is READ from the enumeration, not hardcoded"
else
    fail "🔴 the repository name is read from the enumeration" \
         "hardcoding __repository__ makes this work on one install only: $_sel"
fi

# ── the re-read, which is the whole guarantee ───────────────────────────────
if grep -q '_gql2' <<<"$pb"; then
    pass "the state is RE-READ from Dagster after acting"
else
    fail "the state is re-read after acting" \
         "every stop argument is nullable — a no-op reports success and only a re-read sees it"
fi

# 🔴 THE COMPARISON MUST BE AGAINST THE RE-READ, NOT AGAINST THE ACTION LIST.
# The default automation-condition sensor is not in a code location's declared
# sensors; if enumeration ever misses it, checking only what was acted on would
# report "all started" with one still stopped.
_a11="$(sed -n '/A11\./,/A12\./p' "$PB")"
if grep -q '_after_all' <<<"$_a11" && grep -q '_want' <<<"$_a11"; then
    pass "🔴 it compares the RE-READ against the requested state, not the action list"
else
    fail "🔴 it compares the re-read against the requested state" \
         "checking only what was acted on is how a partial start looks complete"
fi

_a13="$(sed -n '/A13\./,/A14\./p' "$PB")"
if grep -q '_wrong | length) == 0' <<<"$_a13"; then
    pass "🔴 a partial change REFUSES success, naming what did not take"
else
    fail "🔴 a partial change refuses success" "a green that could not have gone red is not evidence"
fi

# ⚠️ An unreadable re-read is neither success nor failure — it is unknown.
_a8="$(sed -n '/A8\./,/A9\./p' "$PB")"
if grep -qi 'could NOT be re-read\|is unknown' <<<"$_a8"; then
    pass "⚠️ an unreadable re-read is reported as unknown, not as either outcome"
else
    fail "⚠️ an unreadable re-read is reported as unknown" \
         "claiming success or failure there is the could-not-look defect"
fi

# ── confirmation, and what it says ──────────────────────────────────────────
if grep -q 'ansible.builtin.pause' <<<"$pb" && grep -q '_assume_yes' <<<"$pb"; then
    pass "it confirms before acting, with a scripted bypass"
else
    fail "it confirms before acting" "a web UI supplied deliberateness incidentally; a flag removes it"
fi

if grep -qF '! -t 0' <<<"$cli" && grep -q 'Refusing rather than assuming' <<<"$cli"; then
    pass "⚠️ non-interactive without --yes REFUSES rather than assuming consent"
else
    fail "⚠️ non-interactive without --yes refuses" "assuming consent for an outward-facing action"
fi

# 🔴 The warning must state the mechanism, in the platform's own words, rather
# than quoting the application. Two sources agreeing because one copies the
# other is a single point of failure with two faces (atlas, #991).
_a3="$(sed -n '/A3\./,/A4\./p' "$PB")"
if grep -q 'on_cron' <<<"$_a3" && grep -qi 'does not backfill' <<<"$_a3"; then
    pass "🔴 it says the sensor may fire promptly, and why — not just 'no backfill'"
else
    fail "🔴 it says the sensor may fire promptly, and why" \
         "'starts the next scheduled run' reads as 'nothing for a while', which is wrong for on_cron"
fi

if grep -qi "APPLICATION'S setting" <<<"$_a3" || grep -qi "not the$" <<<"$_a3"; then
    pass "it does not imply it started everything at once"
else
    fail "it does not imply it started everything at once" \
         "'it started' and 'it started everything' are different fears"
fi

if grep -qi 'first_data' <<<"$_a3"; then
    pass "⚠️ it points at the application's documented first-data ORDER before asking"
else
    fail "⚠️ it points at the documented first-data order" \
         "the verb is what makes 'enable, then discover order mattered' the easy mistake"
fi

# ── --stop means stopped, not reset ─────────────────────────────────────────
if ! grep -qE 'resetSchedule|resetSensor' <<<"$pb"; then
    pass "--stop does not silently become reset-to-default"
else
    fail "--stop does not silently become reset" \
         "reset reverts to defaultStatus, which would be RUNNING for a tenant that declares it"
fi

# ── the CLI surface ─────────────────────────────────────────────────────────
if grep -q -- '--start)' <<<"$cli" && grep -q -- '--stop)' <<<"$cli"; then
    pass "the CLI exposes --start and --stop"
else
    fail "the CLI exposes --start and --stop" "the playbook cannot be reached"
fi

if grep -q 'action=start\|action=\$action' <<<"$cli"; then
    pass "the flag reaches the playbook as action="
else
    fail "the flag reaches the playbook as action=" "a flag that changes nothing is worse than none"
fi

_act="$(sed -n '/0b\./,/1\./p' "$PB")"
if grep -q "_action in \['', 'start', 'stop'\]" <<<"$_act"; then
    pass "an action typo is refused, not read as report-only"
else
    fail "an action typo is refused" "a typo becoming a silent no-op that reports success"
fi

# ⚠️ A name goes into a single-quoted shell string inside the pod.
if grep -q 'escape the shell quoting' "$PB"; then
    pass "⚠️ a name containing a shell metacharacter is refused, not interpolated"
else
    fail "⚠️ a name with a shell metacharacter is refused" "a name that closes the quote becomes arbitrary shell"
fi

if grep -q 'b64encode' <<<"$pb"; then
    pass "the mutation script is base64'd into the pod — one layer of quoting"
else
    fail "the mutation script is base64'd into the pod" \
         "JSON inside -d inside sh -c inside YAML is how a mutation becomes a different one"
fi

# 🔴 The stale note must be gone: it said these verbs were NOT implemented.
if ! grep -q 'WHY THIS ONLY REPORTS' "$PB"; then
    pass "🔴 the note saying this only reports is gone, not left to contradict the code"
else
    fail "🔴 the stale 'only reports' note is gone" "a comment asserting the opposite of the code"
fi

if grep -q 'STILL UNOBSERVED' "$PB"; then
    pass "and it records what is still unobserved: no mutation has been called"
else
    fail "it records what is still unobserved" \
         "signatures are not proof a start works, and the file should say so"
fi

echo ""
echo "  Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
