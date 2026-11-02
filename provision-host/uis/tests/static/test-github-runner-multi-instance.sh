#!/bin/bash
# test-github-runner-multi-instance.sh — a second instance can never collide with the first
#
# urb-agents#2053 (bifrost's billing finding) ended with a second github-runner instance
# wanted on the same cluster urb-agents' own already runs on. The original regression here
# (PR #654) fixed the static-Deployment design: github_runner_namespace/the Deployment
# name/the Secret name were all hardcoded literals, and the remove playbook deleted the
# WHOLE NAMESPACE, so removing a second instance would have deleted the first one's too.
#
# urb-agents#2073/#2075 then replaced that static-Deployment design with ARC (Actions
# Runner Controller) entirely — scale-to-zero + capacity-aware scheduling,
# PLAN-service-github-runner-arc-migration.md. This asserts the SAME guarantees
# (resource-name agreement between setup/remove, a collision check that runs before
# anything is applied, a remove that only deletes the namespace once empty) re-expressed
# against the new Helm-release shape, so none of the original regressions can silently
# come back under the new design. It cannot prove two real instances actually coexist on a
# live cluster (that needs ops) — only that the files agree with each other and repeat
# neither mistake.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
SETUP="$REPO/ansible/playbooks/645-setup-github-runner.yml"
REMOVE="$REPO/ansible/playbooks/645-remove-github-runner.yml"
VALUES="$REPO/manifests/645-github-runner-values.yaml.j2"

PASS=0; FAIL=0
pass() { echo -e "  Testing: $1... \033[0;32mPASS\033[0m"; ((++PASS)); }
fail() { echo -e "  Testing: $1... \033[0;31mFAIL\033[0m"; echo -e "    \033[0;31m→ $2\033[0m"; ((++FAIL)); }

echo "=== github-runner: a second instance can never collide with or delete the first (ARC) ==="

[[ -f "$SETUP" && -f "$REMOVE" && -f "$VALUES" ]] || {
    fail "every file this check needs exists" "missing: $SETUP / $REMOVE / $VALUES"
    echo; echo "  Passed: $PASS  Failed: $FAIL"; exit 1
}

# ── both playbooks compute the resource name (= this instance's Helm release name) the
# SAME way — a real risk since this logic is duplicated in two files; if they ever drift,
# remove would uninstall a different release than setup actually created ──

_setup_calc="$(grep -oF "github-runner{{ ('-' + github_runner_instance) if github_runner_instance | length > 0 else '' }}" "$SETUP")"
_remove_calc="$(grep -oF "github-runner{{ ('-' + github_runner_instance) if github_runner_instance | length > 0 else '' }}" "$REMOVE")"
if [[ -n "$_setup_calc" && "$_setup_calc" == "$_remove_calc" ]]; then
    pass "setup and remove compute github_runner_resource_name identically"
else
    fail "setup and remove compute github_runner_resource_name identically" "setup='$_setup_calc' remove='$_remove_calc'"
fi

# ── the collision check exists, and runs BEFORE the Secret/Helm release is ever applied ──
# (asking "does a release with this name already exist, and does it serve a different repo"
# after the Secret is already written and the chart already installed would be too late —
# the point is to refuse before touching anything live)

_collision_line="$(grep -n '5b\. If it does, it must already be serving the SAME repo' "$SETUP" | head -1 | cut -d: -f1)"
_secret_apply_line="$(grep -n "7\. Apply (or update) this instance's PAT Secret" "$SETUP" | head -1 | cut -d: -f1)"
if [[ -n "$_collision_line" && -n "$_secret_apply_line" && "$_collision_line" -lt "$_secret_apply_line" ]]; then
    pass "the collision check runs before the Secret or the Helm release is ever applied"
else
    fail "the collision check runs before the Secret or the Helm release is ever applied" "collision check at line ${_collision_line:-?}, Secret apply at line ${_secret_apply_line:-?}"
fi

# ── the collision check actually compares repos (as a githubConfigUrl, not a bare repo
# string — that's what `helm get values` actually returns), and has a named escape hatch ──

if grep -qF "existing_repo == ('https://github.com/' + github_runner_repo)" "$SETUP" && grep -qF 'github_runner_force | bool' "$SETUP"; then
    pass "the collision check compares the existing githubConfigUrl and has a github_runner_force escape hatch"
else
    fail "the collision check compares the existing githubConfigUrl and has a github_runner_force escape hatch" "comparison or force flag not found"
fi

if grep -qF 'github_runner_force: false' "$SETUP"; then
    pass "github_runner_force defaults to false, not true"
else
    fail "github_runner_force defaults to false, not true" "default missing or not false"
fi

# ── the collision check itself reads a Helm release, not a Deployment — the old shape no
# longer exists, so a check still anchored on `kind: Deployment` here would always pass
# vacuously (nothing to compare against) rather than actually protecting anything ──

if grep -qF 'helm get values {{ github_runner_resource_name }}' "$SETUP"; then
    pass "the collision check reads the Helm release's own values, not a retired Deployment shape"
else
    fail "collision check reads a Helm release" "no 'helm get values' collision check found — it may still be looking for a Deployment that no longer exists"
fi

# ── remove no longer deletes the whole namespace unconditionally ──
# ⚠️ the OLD bug (pre-#654) was a single unconditional 'state: absent, kind: Namespace' task
# with no 'when:' guard at all. Anchor on there being NO such unguarded task, not on text
# that could coincidentally also match the new, correctly-guarded one.

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

# ── and the namespace delete that DOES exist is gated on no other instance (now an
# AutoscalingRunnerSet CR, not a Deployment) remaining ──

if grep -qF 'when: github_runner_remaining.resources | default([]) | length == 0' "$REMOVE" \
   && grep -qF 'kind: AutoscalingRunnerSet' "$REMOVE"; then
    pass "the namespace delete is gated on no other AutoscalingRunnerSet remaining"
else
    fail "the namespace delete is gated on no other AutoscalingRunnerSet remaining" "guard or resource kind missing"
fi

# ── remove uninstalls the Helm release AND deletes the Secret (helm uninstall doesn't own
# the Secret — this playbook applies it directly in setup, task 7, outside the chart) ──

if grep -qF 'helm uninstall {{ github_runner_resource_name }}' "$REMOVE" \
   && grep -qF 'kind: Secret' "$REMOVE" \
   && grep -qF '{{ github_runner_resource_name }}-token' "$REMOVE"; then
    pass "remove uninstalls this instance's Helm release AND deletes its own Secret by name"
else
    fail "remove uninstalls this instance's Helm release AND deletes its own Secret by name" "uninstall command or Secret-deletion task not found"
fi

# ── the shared ARC controller is never uninstalled by the remove playbook — a deliberate
# simplification (PLAN-service-github-runner-arc-migration.md), not an oversight; if remove
# ever starts touching arc-systems, every OTHER instance on the cluster breaks with it. A
# comment or a line of operator-facing display text may legitimately mention the name (and
# do) — only an actual field reference (`namespace: arc-systems` / `--namespace arc-systems`,
# the shapes a real task would use to target it) is the regression this guards against.

_live_arc_systems_ref="$(grep -nE '(namespace:|--namespace)[[:space:]]+"?arc-systems' "$REMOVE" || true)"
if [[ -z "$_live_arc_systems_ref" ]]; then
    pass "the remove playbook never touches the shared ARC controller (arc-systems), by design"
else
    fail "the remove playbook never touches the shared ARC controller" "found a task-level reference targeting arc-systems: $_live_arc_systems_ref"
fi

# ── the instance name is validated as a safe k8s name fragment before it's folded into
# anything (a Helm release name, a Secret name) ──

if grep -qF "github_runner_instance is match('^[a-z0-9]([a-z0-9-]*[a-z0-9])?\$')" "$SETUP"; then
    pass "github_runner_instance is validated as a safe Kubernetes name fragment"
else
    fail "github_runner_instance is validated as a safe Kubernetes name fragment" "no validation assertion found"
fi

# ── both charts (controller + scale-set) are version-pinned, not floating — the exact
# incident class PLAN-system-helm-chart-version-pinning.md exists to prevent. Count, not a
# bare presence check — one pinned install and one left floating would still pass a plain
# grep -q here.

_version_pin_count="$(grep -cF -- '--version {{ arc_chart_version }}' "$SETUP")"
if grep -qF 'arc_chart_version: "0.15.1"' "$SETUP" && [[ "$_version_pin_count" -ge 2 ]]; then
    pass "both ARC charts are pinned to a specific version, not left floating"
else
    fail "both ARC charts are pinned to a specific version, not left floating" "pin missing, or only passed to $_version_pin_count of the 2 helm install commands"
fi

echo
echo "Passed: $PASS  Failed: $FAIL"
[[ $FAIL -eq 0 ]]
