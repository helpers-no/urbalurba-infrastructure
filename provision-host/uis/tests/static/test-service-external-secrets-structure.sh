#!/bin/bash
# test-service-external-secrets-structure.sh - the ESO service is wired together consistently
#
# Written with no cluster to run it against. This cannot prove `uis deploy external-secrets`
# actually works - only that the files agree with each other. imac's cluster run is what proves
# the rest.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
SVC="$REPO/provision-host/uis/services/management/service-external-secrets.sh"
SETUP="$REPO/ansible/playbooks/026-setup-external-secrets.yml"
REMOVE="$REPO/ansible/playbooks/026-remove-external-secrets.yml"
DOCS="$REPO/website/docs/services/management/external-secrets.md"
MGMT_INDEX="$REPO/website/docs/services/management/index.md"

PASS=0; FAIL=0
pass() { echo -e "  Testing: $1... \033[0;32mPASS\033[0m"; ((++PASS)); }
fail() { echo -e "  Testing: $1... \033[0;31mFAIL\033[0m"; echo -e "    \033[0;31m→ $2\033[0m"; ((++FAIL)); }

echo "External Secrets Operator service: structural consistency"

# ── the files this service claims to need all exist ──

if [[ -f "$SVC" && -f "$SETUP" && -f "$REMOVE" && -f "$DOCS" ]]; then
    pass "every file the service references exists"
else
    fail "every file the service references exists" "one or more missing"
fi

# ── the service definition's own cross-references are real ──

_pb="$(grep -oE 'SCRIPT_PLAYBOOK="[^"]+"' "$SVC" | cut -d'"' -f2)"
_rm="$(grep -oE 'SCRIPT_REMOVE_PLAYBOOK="[^"]+"' "$SVC" | cut -d'"' -f2)"
if [[ -f "$REPO/ansible/playbooks/$_pb" && -f "$REPO/ansible/playbooks/$_rm" ]]; then
    pass "SCRIPT_PLAYBOOK and SCRIPT_REMOVE_PLAYBOOK point at real files"
else
    fail "SCRIPT_PLAYBOOK and SCRIPT_REMOVE_PLAYBOOK point at real files" "$_pb / $_rm"
fi

_prio="$(grep -oE 'SCRIPT_PRIORITY="[0-9]+"' "$SVC" | grep -oE '[0-9]+')"
_collisions="$(grep -rl "SCRIPT_PRIORITY=\"$_prio\"" "$REPO"/provision-host/uis/services/*/*.sh | grep -v service-external-secrets.sh)"
if [[ -z "$_collisions" ]]; then
    pass "SCRIPT_PRIORITY ($_prio) collides with no other service"
else
    fail "SCRIPT_PRIORITY ($_prio) collides with no other service" "also used by: $_collisions"
fi

# ── no un-no_log'd credential-carrying command task (none expected, but keep the sweep) ──

_bad="$(python3 - "$SETUP" "$REMOVE" <<'PYEOF'
import re, sys
CRED = re.compile(r'(--set[^\n]*(pass|secret|key)[^\n]*=|PASSWORD=|SECRET=|--password|\{\{[^}]*(password|secret_key|token)[^}]*\}\})', re.I)
PROSE_ONLY = re.compile(r'^\s+(ansible\.builtin\.)?(debug|assert|fail|set_fact):', re.M)
bad = []
for path in sys.argv[1:]:
    s = open(path).read()
    for t in re.split(r'(?m)^(?=\s*- name:)', s):
        m = re.match(r'\s*- name:\s*(.*)', t)
        if not m or PROSE_ONLY.search(t) or not CRED.search(t):
            continue
        if not re.search(r'(?m)^\s+no_log:\s*true', t):
            bad.append(f"{path}: {m.group(1).strip()[:50]}")
print(' | '.join(bad))
PYEOF
)"
if [[ -z "$_bad" ]]; then
    pass "no credential-carrying command task is missing no_log"
else
    fail "no credential-carrying command task is missing no_log" "$_bad"
fi

# ── every kubectl-invoking command task carries KUBECONFIG ──

_missing_kc="$(python3 - "$SETUP" "$REMOVE" <<'PYEOF'
import re, sys
RUN = re.compile(r'^\s+(ansible\.builtin\.)?(command|shell|raw):', re.M)
bad = []
for path in sys.argv[1:]:
    s = open(path).read()
    for t in re.split(r'(?m)^(?=\s*- name:)', s):
        if 'kubectl' not in t or not RUN.search(t):
            continue
        m = re.match(r'\s*- name:\s*(.*)', t)
        if m and 'KUBECONFIG' not in t:
            bad.append(f"{path}: {m.group(1).strip()[:50]}")
print(' | '.join(bad))
PYEOF
)"
if [[ -z "$_missing_kc" ]]; then
    pass "every kubectl-invoking task carries KUBECONFIG"
else
    fail "every kubectl-invoking task carries KUBECONFIG" "$_missing_kc"
fi

# ── the repo-wide "helm repo update must force" rule ──

if grep -q 'helm repo update --force-update' "$SETUP"; then
    pass "helm repo update uses --force-update"
else
    fail "helm repo update uses --force-update" "not found in $SETUP"
fi

# ── docs index links to this service's page ──

if grep -q "external-secrets.md" "$MGMT_INDEX"; then
    pass "the management index links to the External Secrets page"
else
    fail "the management index links to the External Secrets page" "no link found"
fi

# ── YAML parses, if a YAML engine is available (prefer the project's own) ──

_YAMLCHECK=""
if [[ -f "$REPO/website/node_modules/js-yaml/package.json" ]]; then
    _YAMLCHECK="node -e \"const y=require('$REPO/website/node_modules/js-yaml');const fs=require('fs');for(const f of process.argv.slice(1)){y.loadAll(fs.readFileSync(f,'utf8'))}\""
fi
if [[ -n "$_YAMLCHECK" ]]; then
    if eval "$_YAMLCHECK" "$SETUP" "$REMOVE" 2>/tmp/eso-yaml-err; then
        pass "both YAML files parse"
    else
        fail "both YAML files parse" "$(cat /tmp/eso-yaml-err)"
    fi
else
    echo "  Testing: both YAML files parse... SKIPPED (no js-yaml available on this host)"
fi

echo
echo "Passed: $PASS  Failed: $FAIL"
[[ $FAIL -eq 0 ]]
