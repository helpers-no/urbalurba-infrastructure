#!/bin/bash
# test-argocd-list-refuses-when-absent.sh — "none" and "could not look" differ
#
# 🔴 `uis argocd list` reported "(0 registered) — No applications registered."
# and exited 0 with ArgoCD ENTIRELY ABSENT: the namespace existed and was
# completely empty, no pods, no deployments (imac via ops-dev, #1575).
#
# The check tested for the NAMESPACE. A namespace outlives everything that was
# ever in it, so its presence answers a different question than the reader is
# asking — and `list` is the command someone runs FIRST to see where they
# stand. The output is indistinguishable from a healthy ArgoCD with nothing
# registered yet.
#
# 🔵 `register` was correct all along: it checks for argocd-server PODS,
# refuses, exits non-zero and names the remedy. imac asked that the working
# case be recorded alongside the defect, so this file asserts BOTH — and
# asserts they select on the SAME label, so the two verbs cannot drift back
# into disagreeing about whether they may speak.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
LIST="$REPO/ansible/playbooks/argocd-list-apps.yml"
REG="$REPO/ansible/playbooks/argocd-register-app.yml"
CLI="$REPO/provision-host/uis/manage/uis-cli.sh"

PASS=0; FAIL=0
pass() { echo -e "  Testing: $1... \033[0;32mPASS\033[0m"; ((++PASS)); }
fail() { echo -e "  Testing: $1... \033[0;31mFAIL\033[0m"; echo -e "    \033[0;31m→ $2\033[0m"; ((++FAIL)); }

echo "=== list refuses when ArgoCD is absent, instead of reporting zero ==="

for f in "$LIST" "$REG" "$CLI"; do
    [[ -f "$f" ]] || { fail "file present" "missing: $f"; echo; echo "  Passed: $PASS  Failed: $FAIL"; exit 1; }
done

# Every assertion runs against the comment-stripped playbooks: the prose above
# and in the playbook names the label, the namespace and the remedy, so a
# file-wide grep would pass with the fix reverted.
lst="$(grep -v '^[[:space:]]*#' "$LIST")"
reg="$(grep -v '^[[:space:]]*#' "$REG")"

if grep -q 'k8s_info' <<<"$lst" && grep -q 'k8s_info' <<<"$reg"; then
    pass "control: the comment-stripped scan still sees tasks in both"
else
    fail "control: the scan sees tasks" "stripping removed everything — all checks below vacuous"
    echo ""; echo "  Passed: $PASS  Failed: $FAIL"; exit 1
fi

# --- list must test for what is RUNNING, not for a namespace ---------------
_SEL='app.kubernetes.io/name=argocd-server'
if grep -qF "$_SEL" <<<"$lst"; then
    pass "list checks for argocd-server pods"
else
    fail "list checks what is running" "a namespace that outlived its contents still passes"
fi

# 🔴 The specific regression: deciding on Namespace existence.
if grep -qE 'kind:[[:space:]]*Namespace' <<<"$lst"; then
    fail "list does not gate on namespace existence" "the empty-namespace case returns 'none' again"
else
    pass "list does not gate on namespace existence"
fi

# --- and it must REFUSE, not report an empty inventory ---------------------
if grep -q 'ansible.builtin.fail' <<<"$lst"; then
    pass "list has a refusal task at all"
else
    fail "list refuses" "it would print a count it was not in a position to take"
fi

# The refusal must be guarded on the pod count being zero — asserting the task
# exists without its condition would pass on a refusal that never fires.
_guard="$(sed -n '/Refuse to report an inventory/,/Get all ArgoCD Application/p' <<<"$lst")"
if grep -qF 'argocd_pods.resources' <<<"$_guard"; then
    pass "the refusal is driven by the pod query, not by something else"
else
    fail "the refusal reads the pod query" "it would fire always, or never"
fi

# ⚠️ The words that stop the next reader misreading it.
if grep -qF 'could not look' <<<"$lst"; then
    pass "the refusal distinguishes 'could not look' from 'nothing registered'"
else
    fail "the two meanings are separated" "a refusal that reads like an empty result"
fi

# --- the two verbs must agree, or they drift apart again -------------------
if grep -qF "$_SEL" <<<"$reg"; then
    pass "register selects on the same label (the working case, recorded)"
else
    fail "both verbs share the condition" "list and register can disagree about whether ArgoCD exists"
fi

# --- a refusal that exits 0 is the defect, not the fix ---------------------
_fn="$(sed -n '/^cmd_argocd_list()/,/^}/p' "$CLI")"
if grep -q 'return "\$EXIT_GENERAL_ERROR"' <<<"$_fn"; then
    pass "the CLI propagates the failure instead of exiting 0"
else
    fail "the exit status reaches the caller" "the playbook refuses and the command still succeeds"
fi

echo ""
echo "  Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
