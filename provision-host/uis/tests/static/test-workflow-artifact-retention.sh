#!/bin/bash
# test-workflow-artifact-retention.sh — an artifact nobody reads must not be
# kept for ninety days.
#
# 🔴 urb-agents reached 1,513 artifacts and 47.38 GB before anyone looked. This
# repository is nowhere near that — 149 artifacts, 0.51 GB — but the SHAPE was
# the same: nothing set a retention anywhere, so everything inherited the
# 90-day repository default.
#
# ⚠️ The `.dockerbuild` build record is uploaded BY docker/build-push-action
# itself, not by any `upload-artifact` step — so grepping the workflows for
# artifact uploads does not find it. That is why it accumulated unnoticed.
#
# The `github-pages` artifacts are NOT covered here on purpose: measured, they
# expire the same day (upload-pages-artifact sets its own short retention), so
# their 490 MB is transient rather than accumulating. Adding a setting there
# would look like diligence and change nothing.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
WF="$REPO_ROOT/.github/workflows"

PASS=0; FAIL=0
pass() { echo -e "  Testing: $1... \033[0;32mPASS\033[0m"; ((++PASS)); }
fail() { echo -e "  Testing: $1... \033[0;31mFAIL\033[0m"; echo -e "    \033[0;31m→ $2\033[0m"; ((++FAIL)); }

echo "=== workflow artifacts are not kept for 90 days ==="

if [[ ! -d "$WF" ]]; then
    fail "workflows directory present" "missing: $WF"
    echo ""; echo "  Passed: $PASS  Failed: $FAIL"; exit 1
fi

# Comments name the defect and must not satisfy the assertions.
_build_code="$(grep -v '^\s*#' "$WF/build-uis-container.yml" 2>/dev/null)"

if grep -q 'DOCKER_BUILD_RECORD_RETENTION_DAYS' <<<"$_build_code"; then
    pass "🔴 the build record has an explicit retention"
else
    fail "🔴 the build record has an explicit retention" \
         "unset inherits 90 days — ~694 artifacts in steady state, read by nobody"
fi

_days="$(grep -oE 'DOCKER_BUILD_RECORD_RETENTION_DAYS:[[:space:]]*[0-9]+' <<<"$_build_code" | grep -oE '[0-9]+$')"
if [[ -n "$_days" && "$_days" -ge 1 && "$_days" -le 14 ]]; then
    pass "it is a short window ($_days days)"
else
    fail "it is a short window" "got '${_days:-unset}'; 0 or unset means 'inherit 90 days'"
fi

# ⚠️ Every producer must be accounted for. A new one that uploads artifacts
# without a retention is the same defect arriving by a different route.
#
# 🔵 This assertion used to REJECT any `actions/upload-artifact` at all, which
# was honest while none existed and became wrong the moment one did: the arm64
# split hands digests between jobs that way. It fired on the legitimate producer
# — correctly, as a "someone must look at this" — and the looking is this
# rewrite. It now checks the property (does each upload declare a retention?)
# rather than the proxy (does any upload exist?).
_uploads=$(grep -c 'uses:[[:space:]]*actions/upload-artifact' "$WF"/*.yml 2>/dev/null | awk -F: '{n+=$2} END {print n+0}')
# Each upload-artifact step must carry retention-days within its own `with:`
# block. Counted rather than matched positionally: a step is ~10 lines and the
# key may be anywhere in it.
_retentions=$(grep -c '^[[:space:]]*retention-days:' "$WF"/*.yml 2>/dev/null | awk -F: '{n+=$2} END {print n+0}')
if [[ "$_uploads" -eq 0 ]]; then
    pass "every artifact producer declares a retention (no upload-artifact steps)"
elif [[ "$_retentions" -ge "$_uploads" ]]; then
    pass "every artifact producer declares a retention ($_uploads upload(s), $_retentions retention(s))"
else
    fail "every artifact producer declares a retention" \
         "$_uploads upload-artifact step(s) but only $_retentions retention-days — one uploads into the 90-day default"
fi

# 🔵 Not a retention policy at the repository level, deliberately: that setting
# is `artifact-and-log-retention` — ONE knob for both — and shortening log
# retention would discard the run logs of a release while it is still current.
# ⚠️ Comment-stripped, like every other scan in this file. The first version
# grepped the raw files and failed against correct code, because the comment
# EXPLAINING why the repo-level knob is avoided contains its name. Sixth time
# tonight a check matched prose about the thing instead of the thing — and this
# time I had already stripped comments four lines above and did not here.
_all_code="$(grep -vh '^\s*#' "$WF"/*.yml 2>/dev/null)"
if grep -qi 'artifact-and-log-retention' <<<"$_all_code"; then
    fail "logs are not shortened along with artifacts" \
         "the repo-level knob covers logs too; set retention per producer instead"
else
    pass "logs are not shortened along with artifacts"
fi

# ── CI must not fail a TEST job because a download blipped ──────────────────
# 🔴 A 504 from the yq release host failed the Unit Tests job with `exit 22`,
# and the PR reported "Unit Tests fail" — a third-party blip reading as a test
# failure, with the tests never having run. I introduced that in 1.6.84 by
# adding an unretried download to two jobs.
_wf="$REPO_ROOT/.github/workflows/test-uis.yml"
if [[ -f "$_wf" ]]; then
    # ⚠️ COMMENTS STRIPPED BEFORE COUNTING. `retry-all-errors` appears four
    # times in this file — twice in `run:` blocks and twice in the comments
    # explaining why — so an uncommented count of 4 satisfied `>= 2` even after
    # one of the two real invocations was removed. The prose about a rule
    # satisfying the check for the rule, in COUNT form this time.
    _n_yq="$(grep -c 'name: Install yq' "$_wf")"
    _n_retry="$(grep -v '^[[:space:]]*#' "$_wf" | grep -c 'retry-all-errors')"
    # ⚠️ Counted, not merely present: TWO jobs install it and both must retry.
    # A count check is what catches the second one being left behind.
    if [[ "$_n_yq" -ge 1 && "$_n_retry" -ge "$_n_yq" ]]; then
        pass "🔴 every yq install step retries ($_n_yq step(s), $_n_retry retry mention(s))"
    else
        fail "🔴 every yq install step retries" \
             "$_n_yq install step(s) and only $_n_retry with --retry-all-errors"
    fi

    # ⚠️ `--retry-all-errors` specifically: a 504 is an HTTP RESPONSE, not a
    # transport error, so plain `--retry` would not have covered the failure
    # that prompted this.
    if grep -q 'retry-all-errors' "$_wf"; then
        pass "⚠️ it retries HTTP errors, not only transport errors"
    else
        fail "⚠️ it retries HTTP errors too" "a 504 is a response; plain --retry does not cover it"
    fi

    # 🔵 And when it does fail, it must say the tests did not run — otherwise
    # the next person reads a red Unit Tests job as a code defect.
    if grep -q 'not a test failure' "$_wf"; then
        pass "🔵 a fetch failure says so, rather than looking like a test failure"
    else
        fail "🔵 a fetch failure says so" "a red test job that was never a test is the wrong signal"
    fi

    # ⚠️ The status must be CAPTURED. Tested: inside `if ! cmd; then`, `$?` is
    # the negation's 0, not the command's status — so a message built that way
    # reports "exit 0" for a failure.
    if ! grep -qE 'curl exit \$\?' "$_wf"; then
        pass "⚠️ the reported exit status is captured, not read from \$? after if-!"
    else
        fail "⚠️ the exit status is captured" "inside 'if ! cmd', \$? is 0 and the message would say exit 0"
    fi
else
    fail "the workflow file is present" "missing: $_wf"
fi

echo ""
echo "  Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
