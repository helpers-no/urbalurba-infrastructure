#!/bin/bash
# test-config-comments-match-upstream.sh — a comment that misdescribes a setting
# becomes the basis of a decision.
#
# 🔴 `manifests/360-dagster-config.yaml` carried the comment "Run-history
# retention is left at the chart default". The setting is TICK retention — the
# Dagster chart's own header says "data types such as schedule / sensor ticks",
# and the chart has no run-purge at all.
#
# ⚠️ The cost was not confusion. I reasoned from my own label instead of the
# chart and told ops-dev that enabling it would reap 35,040 run records a year,
# on a question they were about to put to Terje. It would not have removed one
# (#811).
#
# A wrong comment is more expensive than no comment: it is read as evidence.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
CFG="$REPO_ROOT/manifests/360-dagster-config.yaml"

PASS=0; FAIL=0
pass() { echo -e "  Testing: $1... \033[0;32mPASS\033[0m"; ((++PASS)); }
fail() { echo -e "  Testing: $1... \033[0;31mFAIL\033[0m"; echo -e "    \033[0;31m→ $2\033[0m"; ((++FAIL)); }

echo "=== config comments must describe what the setting does ==="

if [[ ! -f "$CFG" ]]; then
    fail "the dagster config is present" "missing: $CFG"
    echo ""; echo "  Passed: $PASS  Failed: $FAIL"; exit 1
fi

# The retention block and the comment immediately above it.
_block="$(awk '/^# .*TICK RETENTION|^# Run-history retention/,/^  enabled:/' "$CFG")"
[[ -z "$_block" ]] && _block="$(grep -B25 '^retention:' "$CFG")"

if grep -qi 'tick' <<< "$_block"; then
    pass "🔴 the retention comment says it governs TICKS"
else
    fail "🔴 the retention comment says it governs TICKS" \
         "the chart's header is 'data types such as schedule / sensor ticks'"
fi

# ⚠️ Matches the CLAIM, not the words. "Run-history retention is left at..." is
# the wrong claim; "this is not run-history retention" is the right one and
# contains the same words.
if grep -qiE '^#[^\n]*Run-history retention is' <<< "$_block"; then
    fail "the comment does not claim to be run-history retention" \
         "this setting removes no run records; no chart setting does"
else
    pass "the comment does not claim to be run-history retention"
fi

if grep -qiE 'no run-purge|NOT RUN-HISTORY|separate, unsolved' <<< "$_block"; then
    pass "it says run growth is a separate problem this does not solve"
else
    fail "it says run growth is a separate problem this does not solve" \
         "without that, the next reader re-derives the same wrong recommendation"
fi

# ── enabling it is a measured decision, and the values must be readable here ──
if grep -qE '^  enabled: true' <<< "$_block"; then
    pass "retention is enabled"
else
    fail "retention is enabled" "measured at 5.4% of the DB and left off"
fi

# ⚠️ Written out rather than inherited. A reader must not have to fetch the
# chart to learn what this deletes — which is the failure the comment records.
# ⚠️ NOT an awk range ending on `^[a-zA-Z#]`: `retention:` matches that pattern
# itself, so the range closed on its own start line and captured one line. It
# reported the config as missing values the config plainly had — a test failing
# against correct code, which is the third time tonight.
_ret="$(sed -n '/^retention:/,/^$/p' "$CFG")"
if grep -q 'skipped: 7' <<< "$_ret" && grep -q 'failure: -1' <<< "$_ret"; then
    pass "🔴 what it purges is stated in this file, not inherited"
else
    fail "🔴 what it purges is stated in this file, not inherited"          "enabled: true with no visible sub-values hides what gets deleted"
fi

if grep -q 'autoMaterialize' <<< "$_ret"; then
    pass "auto-materialize ticks are covered — the high-volume writer"
else
    fail "auto-materialize ticks are covered"          "a sensor-driven tenant's ticks are autoMaterialize, not sensor"
fi

# The concurrency cap comment makes a claim about a shared database; that one is
# correct and load-bearing, so it should stay.
if grep -q 'maxConcurrentRuns' "$CFG" && grep -qi 'shared\|hammer' "$CFG"; then
    pass "the concurrency cap still explains WHY it is a platform policy"
else
    fail "the concurrency cap still explains why" "the reason is what stops it being raised on request"
fi

# ── the run pods have a floor of their own ──────────────────────────────────
# 🔴 THEY USED TO INHERIT THE CODE LOCATION'S. The chart propagates a user
# deployment's resources to the run pods it launches, so the ephemeral pods
# doing the work were scheduled against 384Mi/100m — a number measured on a
# long-lived pod peaking at 300 MiB. imac measured four run pods from inside
# their own cgroups: 590 MiB and ~628m average, 45-54% and 528% over
# (ops-dev, urb-agents#1010).
_rl="$(sed -n '/^runLauncher:/,/^[a-z]/p' "$CFG" | grep -v '^[[:space:]]*#')"

if grep -q 'k8sRunLauncher' <<<"$_rl" && grep -q 'requests' <<<"$_rl"; then
    pass "🔴 run pods have their own requests, not the code location's"
else
    fail "🔴 run pods have their own requests" \
         "inheriting a floor measured on a different pod doing a different thing"
fi

_mem="$(grep -oE 'memory: *[0-9]+Mi' <<<"$_rl" | grep -oE '[0-9]+' | head -1)"
if [[ -n "$_mem" && "$_mem" -ge 590 ]]; then
    pass "the memory request covers the largest MEASURED run (590 MiB), with headroom"
else
    fail "the memory request covers the largest measured run" "got ${_mem:-<none>}Mi against 590 MiB measured"
fi

# 🔴 NO LIMITS. The memory limit is BLOCKED on a bootstrap measurement:
# brreg_bootstrap is the job an operator runs FIRST and the one most likely to
# exceed anything chosen from today's numbers, so a limit from 590 MiB could
# turn it into an OOM kill on a new operator's first action. The CPU limit is
# DECIDED AGAINST: it throttles rather than fails, converting a resourcing
# problem into a mysterious performance problem.
if ! grep -q 'limits' <<<"$_rl"; then
    pass "🔴 no run-pod limits — a sampled figure is a floor, never a ceiling"
else
    fail "🔴 no run-pod limits" \
         "a memory limit set from a sample that excludes the largest workload is a kill threshold"
fi

# ⚠️ THE REQUEST IS MULTIPLIED BY THE CONCURRENCY CAP, and that coupling is the
# thing a future reader will not know. A pod that cannot be SCHEDULED reads as a
# hang; one that bursts above its request is requests working as intended.
_cpu="$(grep -oE 'cpu: *[0-9]+m' <<<"$_rl" | grep -oE '[0-9]+' | head -1)"
_cap="$(grep -oE 'maxConcurrentRuns: *[0-9]+' "$CFG" | grep -oE '[0-9]+' | head -1)"
if [[ -n "$_cpu" && -n "$_cap" ]] && (( _cpu * _cap <= 2000 )); then
    pass "⚠️ cpu request x maxConcurrentRuns ($_cpu m x $_cap) still fits a laptop profile"
else
    fail "⚠️ cpu request x maxConcurrentRuns fits a laptop profile" \
         "${_cpu:-?}m x ${_cap:-?} reserves more than 2 cores before the last pod can be placed"
fi

if grep -qi 'coupled to the run-pod request' "$CFG"; then
    pass "and the concurrency cap says it is coupled to that request"
else
    fail "the concurrency cap says it is coupled to that request" \
         "raising one without the other is how pods become unschedulable"
fi

echo ""
echo "  Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
