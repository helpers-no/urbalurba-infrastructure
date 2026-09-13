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
_producers="$(grep -rhoE 'uses:[[:space:]]*(actions/upload-artifact|docker/build-push-action)[^[:space:]]*' "$WF" | sort -u)"
if grep -q 'upload-artifact' <<<"$_producers"; then
    fail "every artifact producer is covered" \
         "an actions/upload-artifact step appeared; give it retention-days or exempt it here"
else
    pass "every artifact producer is covered"
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

echo ""
echo "  Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
