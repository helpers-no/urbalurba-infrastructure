#!/bin/bash
# test-helm-repo-failures-are-non-fatal.sh — one flaky external helm repo must not fail the build
#
# 🔴 Found live, 2026-10-28: helm.runix.net was transiently unreachable from GitHub's own
# runners (Azure's internal resolver failing on its CNAME chain). Neither the Ansible task
# nor the container-build fallback script tolerated it, so the ONE bad repo failed the whole
# Docker build — blocking every merge to main, not just whatever PR happened to trigger the
# next build. Same class of defect as the --force-update fix this script's own header
# already documents (1.6.55, a second `helm repo add` on an existing name). Pre-seeding these
# repos is a build-time convenience only: every service that actually needs one (e.g.
# pgadmin/runix in 641-adm-pgadmin.yml) re-adds its own repo at deploy time anyway.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
PLAYBOOK="$REPO/ansible/playbooks/05-install-helm-repos.yml"
SCRIPT="$REPO/provision-host/provision-host-04-helmrepo.sh"

PASS=0; FAIL=0
pass() { echo -e "  Testing: $1... \033[0;32mPASS\033[0m"; ((++PASS)); }
fail() { echo -e "  Testing: $1... \033[0;31mFAIL\033[0m"; echo -e "    \033[0;31m→ $2\033[0m"; ((++FAIL)); }

echo "=== one flaky external helm repo cannot fail the whole build ==="

[[ -f "$PLAYBOOK" && -f "$SCRIPT" ]] || {
    fail "both files exist" "missing: $PLAYBOOK / $SCRIPT"
    echo; echo "  Passed: $PASS  Failed: $FAIL"; exit 1
}

# ── the Ansible task tolerates one repo failing ──
# ⚠️ Anchor on the task block itself, not a bare grep for "ignore_errors: true" anywhere in
# the file — a later task could carry that flag instead and this would pass vacuously.
_add_task="$(awk '/- name: Add Helm repositories/,/^$/' "$PLAYBOOK")"
if [[ -n "$_add_task" ]] && grep -qE '^\s*ignore_errors:\s*true' <<<"$_add_task"; then
    pass "the 'Add Helm repositories' task has ignore_errors: true"
else
    fail "the 'Add Helm repositories' task has ignore_errors: true" "task block not found, or ignore_errors is missing/false"
fi

# ── and a failed repo is still reported, not silently swallowed ──
if grep -qF 'when: item is failed' "$PLAYBOOK" && grep -qiE 'failed to register' "$PLAYBOOK"; then
    pass "a failed repo is still reported loudly, not silently dropped"
else
    fail "a failed repo is still reported loudly, not silently dropped" "no warning task found for a failed loop item"
fi

# ── the container-build fallback script: each repo add tolerates failure under set -e ──
# `set -eo pipefail` is active (line 5) — any bare `helm repo add ...` with no `||` guard
# aborts the whole script on the first repo that fails to resolve/reach.
_repo_lines="$(grep -E '^\s*helm repo add --force-update' "$SCRIPT")"
_n_lines="$(wc -l <<<"$_repo_lines")"
_n_guarded="$(grep -cE '\|\| echo "WARNING: failed to add helm repo' <<<"$_repo_lines")"
if [[ "$_n_lines" -ge 5 && "$_n_guarded" -eq "$_n_lines" ]]; then
    pass "every direct 'helm repo add' line ($_n_lines of them) tolerates its own failure"
else
    fail "every direct 'helm repo add' line tolerates its own failure" "$_n_guarded of $_n_lines guarded"
fi

if grep -qE '^\s*helm repo update \|\| echo' "$SCRIPT"; then
    pass "'helm repo update' also tolerates a failure, not just the individual adds"
else
    fail "'helm repo update' also tolerates a failure, not just the individual adds" "no guard found on the update call"
fi

# ── runix specifically (the repo that actually broke) is among the guarded ones ──
if grep -qE "helm repo add --force-update runix .*\|\| echo" "$SCRIPT"; then
    pass "runix specifically is guarded (the repo that actually broke the build)"
else
    fail "runix specifically is guarded (the repo that actually broke the build)" "no guard found on the runix line"
fi

echo
echo "Passed: $PASS  Failed: $FAIL"
[[ $FAIL -eq 0 ]]
