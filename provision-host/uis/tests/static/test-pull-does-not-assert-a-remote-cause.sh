#!/bin/bash
# test-pull-does-not-assert-a-remote-cause.sh — a local symptom is not a remote cause
#
# 🔴 `uis pull` landed on the previous version and said:
#
#     "That is a tagging fault in the release, not a fault here …
#      and please report it"
#
# It cannot see what the registry is serving. It observed only that the image
# it received was not the version it wanted — and asserted a remote cause as
# fact, then recruited the operator into filing that claim upstream.
#
# Measured (ops-dev, urb-agents#1580): the registry served ':latest' == the new
# release for the whole window, verified from a second machine sharing no cache
# with the reporter. The stale copy was on the operator's side of the wire.
#
# ⚠️ This is worse than an error naming the wrong object, because it DISPATCHES
# the reader. A wrong attribution that asks to be reported travels.
#
# ✅ `docker manifest inspect` already runs in this code path, so the cause can
# be DETERMINED rather than asserted. When it cannot be, the message must say
# only what was observed — and the request to report must sit behind the check
# that decides whether there is anything to report.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
UIS="$REPO/uis"

PASS=0; FAIL=0
pass() { echo -e "  Testing: $1... \033[0;32mPASS\033[0m"; ((++PASS)); }
fail() { echo -e "  Testing: $1... \033[0;31mFAIL\033[0m"; echo -e "    \033[0;31m→ $2\033[0m"; ((++FAIL)); }

echo "=== pull states what it saw, not what it cannot see ==="

[[ -f "$UIS" ]] || { fail "launcher present" "missing: $UIS"; echo; echo "  Passed: $PASS  Failed: $FAIL"; exit 1; }

# The defect is quoted verbatim in this file's own comments and in the
# launcher's, so every assertion runs against the comment-stripped script.
src="$(grep -v '^[[:space:]]*#' "$UIS")"

if grep -q 'image_tag_published' <<<"$src"; then
    pass "control: the comment-stripped scan still sees code"
else
    fail "control: the scan sees code" "stripping removed everything — all checks below vacuous"
    echo ""; echo "  Passed: $PASS  Failed: $FAIL"; exit 1
fi

# --- the asserted cause must be gone --------------------------------------
if grep -qF 'tagging fault in the release' <<<"$src"; then
    fail "pull no longer asserts a cause it cannot observe" "the remote-cause claim is back"
else
    pass "pull no longer asserts a cause it cannot observe"
fi

# --- it must compare the two tags rather than guess ------------------------
_n=0
grep -qF 'docker manifest inspect "${repo}:latest"' <<<"$src" && _n=$((_n+1))
grep -qF 'docker manifest inspect "${repo}:${remote}"' <<<"$src" && _n=$((_n+1))
if [[ "$_n" -eq 2 ]]; then
    pass "it inspects BOTH tags, which is what makes a verdict possible"
else
    fail "both tags are inspected" "only $_n of 2 — one digest cannot decide which side is stale"
fi

# --- three outcomes, including 'do not know' -------------------------------
_case="$(sed -n '/Expected \$remote, but this machine is on/,/take it by version now/p' <<<"$src")"
_n=0
grep -qF 'SAME image' <<<"$_case" && _n=$((_n+1))
grep -qF 'DIFFERENT images' <<<"$_case" && _n=$((_n+1))
grep -qF 'Cause not determined' <<<"$_case" && _n=$((_n+1))
if [[ "$_n" -eq 3 ]]; then
    pass "all three outcomes exist: local, registry, and undetermined"
else
    fail "the third state survives" "only $_n of 3 — 'could not look' collapses into a claim"
fi

# 🔴 The assertion this file exists for: the report request lives ONLY in the
# branch where the registry was measured to be wrong.
_local="$(sed -n '/SAME image/,/;;/p' <<<"$_case")"
if grep -qiF 'report' <<<"$_local" && ! grep -qF 'Nothing to report' <<<"$_local"; then
    fail "the local branch does not ask for a report" "it dispatches the operator over a local cache"
else
    pass "the local branch does not ask for a report"
fi

_registry="$(sed -n '/DIFFERENT images/,/;;/p' <<<"$_case")"
if grep -qF 'WORTH REPORTING' <<<"$_registry"; then
    pass "the report request sits behind the check that justifies it"
else
    fail "the registry branch still asks for a report" "a real tagging fault would go unreported"
fi

# --- the parts that worked must survive ------------------------------------
# ops-dev and imac both asked that the detection and the remedy be kept: the
# non-zero exit is what stopped imac testing a fix against the wrong version.
if grep -qF 'UIS_IMAGE=${repo}:${remote} ./uis pull' <<<"$src"; then
    pass "the remedy line survives, on every path"
else
    fail "the remedy is still given" "the one instruction that unblocks the operator"
fi

if grep -qE '^[[:space:]]*return 3$' <<<"$src"; then
    pass "the non-zero exit survives"
else
    fail "pull still exits non-zero" "exit 0 is what made this class invisible"
fi

echo ""
echo "  Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
