#!/bin/bash
# test-argocd-register-private-repo-label.sh — the credentials Secret must be labeled
#
# 🔴 The GitHub credentials Secret `uis argocd register` creates for private repos had
# every field ArgoCD's declarative repository Secret contract documents — type, url,
# username, password, the right namespace — EXCEPT the one that makes ArgoCD notice it:
# `argocd.argoproj.io/secret-type: repository`. ArgoCD's repo-server finds repository
# credentials by scanning Secrets in its namespace BY THAT LABEL, not by name or content.
# Without it, a private repo passes both GitHub API pre-flight checks (they already
# authenticate with the same token) and then the Application sits unable to clone,
# timing out ~5 minutes later with no hint that the Secret was ever the problem.
#
# `PLAN-argocd-register-redesign.md`'s own acceptance checklist had this unchecked —
# "Private repos work when a GitHub PAT is configured in secrets (not tested — requires
# private repo)" — which is exactly how a Secret with the wrong shape went unnoticed.
#
# This static test can't reach a live ArgoCD in CI, so it asserts the structure that
# makes it work: the label is present on the credentials Secret, with the exact value
# ArgoCD's declarative-setup docs specify, and it sits on the SAME Secret the repo_url
# and github_pat are written to (not a different, unrelated resource).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
REG="$REPO/ansible/playbooks/argocd-register-app.yml"

PASS=0; FAIL=0
pass() { echo -e "  Testing: $1... \033[0;32mPASS\033[0m"; ((++PASS)); }
fail() { echo -e "  Testing: $1... \033[0;31mFAIL\033[0m"; echo -e "    \033[0;31m→ $2\033[0m"; ((++FAIL)); }

echo "=== the credentials Secret carries the label ArgoCD requires ==="

[[ -f "$REG" ]] || { fail "file present" "missing: $REG"; echo; echo "  Passed: $PASS  Failed: $FAIL"; exit 1; }

# Comment-stripped: the prose above and in the playbook names the label repeatedly,
# so a file-wide grep would pass with the fix reverted.
reg="$(grep -v '^[[:space:]]*#' "$REG")"

if grep -qF 'github_secret_name' <<<"$reg"; then
    pass "control: the comment-stripped scan still sees the credentials Secret task"
else
    fail "control: the scan sees the task" "stripping removed everything — the check below is vacuous"
    echo ""; echo "  Passed: $PASS  Failed: $FAIL"; exit 1
fi

# --- isolate the credentials Secret task, not the whole file ---------------
_secret_block="$(sed -n '/Create GitHub credentials secret/,/when: has_github_token/p' <<<"$reg")"

if grep -qF 'password: "{{ github_pat }}"' <<<"$_secret_block"; then
    pass "isolated the right task — it writes github_pat"
else
    fail "isolated the right task" "the sed range missed the credentials task entirely"
    echo ""; echo "  Passed: $PASS  Failed: $FAIL"; exit 1
fi

# --- the actual regression: the label, on THIS secret, with the exact value ---
if grep -qF 'argocd.argoproj.io/secret-type: repository' <<<"$_secret_block"; then
    pass "credentials Secret carries the ArgoCD repository label"
else
    fail "credentials Secret carries the label" "ArgoCD's repo-server will never see this Secret — private repos time out with no hint why"
fi

# The label must live under THIS Secret's own metadata, not float elsewhere in the
# file where it would satisfy a bare grep without actually labeling the resource.
# Comment-stripped ($reg), not the raw file — a prose line explaining the fix (like
# the one above this task) would otherwise be mistaken for the label's real position.
# 16-space indent picks resource_definition.metadata.name, not the task's own
# top-level `name:` module argument (12-space indent) — both match the bare string.
_label_line=$(grep -n 'argocd.argoproj.io/secret-type: repository' <<<"$reg" | head -1 | cut -d: -f1)
_metadata_line=$(grep -nE '^ {16}name: "\{\{ github_secret_name \}\}"' <<<"$reg" | head -1 | cut -d: -f1)
if [[ -n "$_label_line" && -n "$_metadata_line" ]] && (( _label_line > _metadata_line )) && (( _label_line - _metadata_line < 6 )); then
    pass "the label sits inside this Secret's own metadata block"
else
    fail "label is actually inside the Secret's metadata" "a label elsewhere in the file would pass a bare grep without labeling the resource ArgoCD reads"
fi

echo ""
echo "  Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
