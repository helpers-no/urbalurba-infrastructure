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

echo ""
echo "  Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
