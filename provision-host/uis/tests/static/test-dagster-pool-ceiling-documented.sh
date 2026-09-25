#!/bin/bash
# test-dagster-pool-ceiling-documented.sh — a read can exhaust the webserver pool
#
# 🔴 Dagster's webserver sizes its own pool: pool_size=1, max_overflow=20, a
# hard ceiling of 21 that DENIES after 30 s rather than queueing.
#
# Measured twice from opposite directions — once under a check-heavy launch
# (imac), and once by a single GraphQL fan-out with NOTHING running (ops-dev,
# urb-agents#1545). The second is the one to plan around: anyone verifying a
# deploy through GraphQL can degrade the thing they are verifying.
#
# ⚠️ And there is no platform setting. pool_size is a SQLAlchemy engine kwarg
# set at the call site; the chart's postgresqlParams urlencodes into the
# connection URL, which is libpq. The two never meet. A page that describes
# the ceiling without saying that invites someone to go looking for a value
# to raise, and they will not find one.
#
# 🔵 The aftermath matters more than the cause: stale pooled connections
# report "server terminated abnormally" when nothing terminated. During an
# incident that sends a reader to the database instead of the pool.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
DOC="$REPO/website/docs/services/analytics/dagster.md"

PASS=0; FAIL=0
pass() { echo -e "  Testing: $1... \033[0;32mPASS\033[0m"; ((++PASS)); }
fail() { echo -e "  Testing: $1... \033[0;31mFAIL\033[0m"; echo -e "    \033[0;31m→ $2\033[0m"; ((++FAIL)); }

echo "=== the webserver DB pool ceiling is documented ==="

[[ -f "$DOC" ]] || { fail "doc present" "missing: $DOC"; echo; echo "  Passed: $PASS  Failed: $FAIL"; exit 1; }

if grep -qF 'Dagster' "$DOC"; then
    pass "control: the doc is readable and non-empty"
else
    fail "control: the doc is readable" "every check below would be vacuous"
    echo ""; echo "  Passed: $PASS  Failed: $FAIL"; exit 1
fi

# The numbers are the code's, so they must be stated, not paraphrased.
_n=0
grep -qF 'pool_size=1' "$DOC" && _n=$((_n+1))
grep -qF 'max_overflow=20' "$DOC" && _n=$((_n+1))
if [[ "$_n" -eq 2 ]]; then
    pass "the ceiling names both numbers it is made of"
else
    fail "both pool numbers are given" "only $_n of 2 — 'a small pool' is not diagnosable"
fi

# 🔴 The new trigger class: no job required.
if grep -qF 'You do not need a job running to hit it' "$DOC"; then
    pass "a read with nothing running is named as a trigger"
else
    fail "the read-only trigger is documented" "it reads as a launch-time problem only"
fi

if grep -qF 'degrade the thing they are verifying' "$DOC"; then
    pass "it warns that verifying through GraphQL is itself load"
else
    fail "the verification hazard is stated" "the person most likely to hit this is unwarned"
fi

# ⚠️ Without this, a reader hunts for a config value that does not exist.
_n=0
grep -qF 'no platform setting for this' "$DOC" && _n=$((_n+1))
grep -qF 'never meet' "$DOC" && _n=$((_n+1))
if [[ "$_n" -eq 2 ]]; then
    pass "it says the ceiling is unreachable from platform config, and why"
else
    fail "the absent lever is explained" "only $_n of 2 — someone goes looking for a value to raise"
fi

# The misleading aftermath, and the reason it looks deterministic.
_n=0
grep -qF 'Nothing terminated' "$DOC" && _n=$((_n+1))
grep -qF 'first fails, second succeeds' "$DOC" && _n=$((_n+1))
if [[ "$_n" -eq 2 ]]; then
    pass "the stale-connection error is named as not a crash"
else
    fail "the misleading error is corrected" "only $_n of 2 — reads as a database crash"
fi

if grep -qF 'before going anywhere near the database' "$DOC"; then
    pass "it says what to check before suspecting the database"
else
    fail "the incident-time redirect is given" "an accurate error about the wrong object"
fi

echo ""
echo "  Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
