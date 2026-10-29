#!/bin/bash
# test-github-runner-multi-instance.sh — a second instance can never collide with the first
#
# urb-agents#2053 (bifrost's billing finding) ended with a second github-runner instance
# wanted on the same cluster urb-agents' own already runs on. Checked directly: the service
# was NOT ready for that — github_runner_namespace/the Deployment name/the Secret name were
# all hardcoded literals, and the remove playbook deleted the WHOLE NAMESPACE, so removing a
# second instance would have deleted the first one's too. This is the regression test for
# both fixes. It cannot prove two real instances actually coexist on a live cluster (that
# needs imac/ops) — only that the files agree with each other and repeat neither mistake.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
SETUP="$REPO/ansible/playbooks/645-setup-github-runner.yml"
REMOVE="$REPO/ansible/playbooks/645-remove-github-runner.yml"
MANIFEST="$REPO/manifests/645-github-runner.yaml.j2"

PASS=0; FAIL=0
pass() { echo -e "  Testing: $1... \033[0;32mPASS\033[0m"; ((++PASS)); }
fail() { echo -e "  Testing: $1... \033[0;31mFAIL\033[0m"; echo -e "    \033[0;31m→ $2\033[0m"; ((++FAIL)); }

echo "=== github-runner: a second instance can never collide with or delete the first ==="

[[ -f "$SETUP" && -f "$REMOVE" && -f "$MANIFEST" ]] || {
    fail "every file this check needs exists" "missing: $SETUP / $REMOVE / $MANIFEST"
    echo; echo "  Passed: $PASS  Failed: $FAIL"; exit 1
}

# ── both playbooks compute the resource name the SAME way — a real risk since this logic is
# duplicated in two files; if they ever drift, remove would target a different Deployment/Secret
# than setup actually created ──

_setup_calc="$(grep -oF "github-runner{{ ('-' + github_runner_instance) if github_runner_instance | length > 0 else '' }}" "$SETUP")"
_remove_calc="$(grep -oF "github-runner{{ ('-' + github_runner_instance) if github_runner_instance | length > 0 else '' }}" "$REMOVE")"
if [[ -n "$_setup_calc" && "$_setup_calc" == "$_remove_calc" ]]; then
    pass "setup and remove compute github_runner_resource_name identically"
else
    fail "setup and remove compute github_runner_resource_name identically" "setup='$_setup_calc' remove='$_remove_calc'"
fi

# ── the collision check exists, and runs BEFORE the registration token is minted/applied ──
# (asking "does this already exist, and does it serve a different repo" after already minting a
# token and writing the Secret would be too late — the point is to refuse before touching
# anything live)

_collision_line="$(grep -n '3c\. If it does, it must already be serving the SAME repo' "$SETUP" | head -1 | cut -d: -f1)"
_secret_apply_line="$(grep -n '5\. Apply the registration token Secret' "$SETUP" | head -1 | cut -d: -f1)"
if [[ -n "$_collision_line" && -n "$_secret_apply_line" && "$_collision_line" -lt "$_secret_apply_line" ]]; then
    pass "the collision check runs before the Secret is ever applied"
else
    fail "the collision check runs before the Secret is ever applied" "collision check at line ${_collision_line:-?}, Secret apply at line ${_secret_apply_line:-?}"
fi

# ── the collision check actually compares repos, and has a named escape hatch ──

if grep -qF 'existing_repo == github_runner_repo' "$SETUP" && grep -qF 'github_runner_force | bool' "$SETUP"; then
    pass "the collision check compares the existing repo and has a github_runner_force escape hatch"
else
    fail "the collision check compares the existing repo and has a github_runner_force escape hatch" "comparison or force flag not found"
fi

if grep -qF 'github_runner_force: false' "$SETUP"; then
    pass "github_runner_force defaults to false, not true"
else
    fail "github_runner_force defaults to false, not true" "default missing or not false"
fi

# ── remove no longer deletes the whole namespace unconditionally ──
# ⚠️ the OLD bug was a single unconditional 'state: absent, kind: Namespace' task with no
# 'when:' guard at all. Anchor on there being NO such unguarded task, not on text that could
# coincidentally also match the new, correctly-guarded one.

_unconditional_ns_delete="$(python3 - "$REMOVE" <<'PYEOF'
import re, sys
s = open(sys.argv[1]).read()
for t in re.split(r'(?m)^(?=\s*- name:)', s):
    if 'kind: Namespace' not in t or 'state: absent' not in t:
        continue
    if not re.search(r'(?m)^\s+when:', t):
        print(t[:200])
PYEOF
)"
if [[ -z "$_unconditional_ns_delete" ]]; then
    pass "no unconditional 'delete the namespace' task remains"
else
    fail "no unconditional 'delete the namespace' task remains" "found one with no when: guard: $_unconditional_ns_delete"
fi

# ── and the namespace delete that DOES exist is gated on no other instance remaining ──

if grep -qF 'when: github_runner_remaining.resources | default([]) | length == 0' "$REMOVE" \
   && grep -qF "label_selectors:" "$REMOVE" \
   && grep -qF '"app=github-runner"' "$REMOVE"; then
    pass "the namespace delete is gated on no other app=github-runner Deployment remaining"
else
    fail "the namespace delete is gated on no other app=github-runner Deployment remaining" "guard, selector, or both missing"
fi

# ── remove deletes the Secret too, not just the Deployment (both must go, or a `uis deploy`
# retry after a partial remove would pick up a stale token Secret belonging to a dead pod) ──

if grep -qF 'kind: Secret' "$REMOVE" && grep -qF '{{ github_runner_resource_name }}-token' "$REMOVE"; then
    pass "remove deletes this instance's Secret, by its own computed name, not just its Deployment"
else
    fail "remove deletes this instance's Secret, by its own computed name, not just its Deployment" "no matching Secret-deletion task found"
fi

# ── the instance name is validated as a safe k8s name fragment before it's folded into anything ──

if grep -qF "github_runner_instance is match('^[a-z0-9]([a-z0-9-]*[a-z0-9])?\$')" "$SETUP"; then
    pass "github_runner_instance is validated as a safe Kubernetes name fragment"
else
    fail "github_runner_instance is validated as a safe Kubernetes name fragment" "no validation assertion found"
fi

echo
echo "Passed: $PASS  Failed: $FAIL"
[[ $FAIL -eq 0 ]]
