#!/bin/bash
# test-deploy-dagster-refreshes-handle.sh — a deploy must not leave a stale handle
#
# 🔴 Dagster resolves a run's image from the WEBSERVER's cached code-location
# handle, not from the live Deployment. Roll the code location and leave the
# webserver alone, and every subsequent run executes the PREVIOUS image and
# reports SUCCESS.
#
# The INSTALL path has restarted the two servers for a while
# (_refresh_dagster_handle_after_install). The DEPLOY path never did — and
# `uis deploy dagster` is how a hand-edited code-location tag actually reaches
# a cluster. ops-dev confirmed that is exactly the path #1540 took: hand-edit
# plus `uis deploy dagster`, never `template install`. Ten commits and a day
# were lost to a job running yesterday's build while three commands reported
# success.
#
# ⚠️ Conditional, not unconditional: restarting on every deploy would interrupt
# the UI and the run queue for a condition that is usually absent.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
PB="$REPO_ROOT/ansible/playbooks/360-setup-dagster.yml"
VERIFY="$REPO_ROOT/ansible/playbooks/360-test-dagster.yml"

PASS=0; FAIL=0
pass() { echo -e "  Testing: $1... \033[0;32mPASS\033[0m"; ((++PASS)); }
fail() { echo -e "  Testing: $1... \033[0;31mFAIL\033[0m"; echo -e "    \033[0;31m→ $2\033[0m"; ((++FAIL)); }

echo "=== uis deploy dagster refreshes a handle it made stale ==="

for f in "$PB" "$VERIFY"; do
    [[ -f "$f" ]] || { fail "file present" "missing: $f"; echo; echo "  Passed: $PASS  Failed: $FAIL"; exit 1; }
done

# This file's own comments name every term below, and so do the playbook's.
# Scan the comment-stripped playbook or the fix could be reverted and the
# prose alone would keep these green.
pb="$(grep -v '^[[:space:]]*#' "$PB")"

if grep -q 'ansible.builtin.shell' <<<"$pb"; then
    pass "control: the comment-stripped scan still sees tasks"
else
    fail "control: the scan sees tasks" "stripping removed everything — every check below is vacuous"
    echo ""; echo "  Passed: $PASS  Failed: $FAIL"; exit 1
fi

# 🔴 Scope every restart assertion to the REFRESH TASK, not the whole file.
# The Z4 remediation message tells the operator to run `kubectl rollout
# restart deploy/dagster-dagster-webserver` by hand — so a file-wide grep for
# those words passes even with the actual restart deleted. Both of these
# assertions did exactly that until a mutation run caught them.
_refresh="$(sed -n '/Refresh the handle when the deploy left it stale/,/Re-read the verdict/p' <<<"$pb")"

# --- it must restart BOTH, or the daemon keeps launching on the old handle --
_n=0
grep -q 'dagster-dagster-webserver' <<<"$_refresh" && _n=$((_n+1))
grep -q 'dagster-daemon' <<<"$_refresh" && _n=$((_n+1))
grep -q 'rollout restart' <<<"$_refresh" && _n=$((_n+1))
if [[ "$_n" -eq 3 ]]; then
    pass "the refresh task itself restarts the webserver and the daemon"
else
    fail "both servers are restarted" "only $_n of 3 — the daemon launches scheduled runs from its own handle"
fi

# --- conditional, not unconditional ----------------------------------------
if grep -q "is search('STALE')" <<<"$_refresh"; then
    pass "the restart is gated on the handle actually being stale"
else
    fail "the restart is conditional" "restarting on every deploy interrupts the UI and the run queue"
fi

# --- the outcome, not the action -------------------------------------------
# 🔵 "We restarted them" is an action. "The handle is fresh" is the outcome,
# and only the second is worth telling someone about to trust a run.
if grep -q 'Re-read the verdict after refreshing' <<<"$pb"; then
    pass "it re-queries the verdict instead of reporting the restart"
else
    fail "the verdict is re-queried" "a failed restart would report as a successful refresh"
fi

if grep -q 'STILL STALE after restarting' <<<"$pb"; then
    pass "a refresh that did not take is said out loud"
else
    fail "a failed refresh is reported" "silence here is the same lie one layer up"
fi

# --- the two paths must use the SAME test ----------------------------------
# ⚠️ Two places that must agree. If the deploy path and `uis dagster verify`
# compared pods differently, one could say FRESH while the other said STALE
# and an operator would have no way to choose between them.
_n=0
for pat in 'code-location|user-deployments' 'webserver|daemon'; do
    grep -qF "$pat" <<<"$pb" && grep -qF "$pat" "$VERIFY" && _n=$((_n+1))
done
if [[ "$_n" -eq 2 ]]; then
    pass "deploy and verify compare the same pods, so they cannot disagree"
else
    fail "the two paths share the comparison" "only $_n of 2 — deploy and verify could contradict each other"
fi

# ⚠️ An empty read must not read as FRESH. That is how a renamed chart label
# turns a missing check into a passing one.
if grep -q 'UNREADABLE' <<<"$pb"; then
    pass "an unreadable comparison is its own verdict, not FRESH"
else
    fail "unreadable is distinguished from fresh" "a label rename would silently disable this"
fi

echo ""
echo "  Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
