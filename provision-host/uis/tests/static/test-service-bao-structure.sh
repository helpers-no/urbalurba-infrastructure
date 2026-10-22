#!/bin/bash
# test-service-bao-structure.sh - the OpenBao service is wired together consistently
#
# Written with no cluster to run it against. This cannot prove `uis deploy bao` actually works -
# only that the files agree with each other and that a secret-carrying task is never missing
# no_log. imac's cluster run is what proves the rest, including whether the chart's actual
# Service/Pod/PVC names match the "bao" assumption this service's files make throughout - see
# 027-setup-bao.yml's own header for exactly what is unverified.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
SVC="$REPO/provision-host/uis/services/management/service-bao.sh"
SETUP="$REPO/ansible/playbooks/027-setup-bao.yml"
REMOVE="$REPO/ansible/playbooks/027-remove-bao.yml"
VALUES="$REPO/manifests/027-bao-config.yaml"
DOCS="$REPO/website/docs/services/management/bao.md"
MGMT_INDEX="$REPO/website/docs/services/management/index.md"

PASS=0; FAIL=0
pass() { echo -e "  Testing: $1... \033[0;32mPASS\033[0m"; ((++PASS)); }
fail() { echo -e "  Testing: $1... \033[0;31mFAIL\033[0m"; echo -e "    \033[0;31m→ $2\033[0m"; ((++FAIL)); }

echo "OpenBao service: structural consistency"

# ── the files this service claims to need all exist ──

if [[ -f "$SVC" && -f "$SETUP" && -f "$REMOVE" && -f "$VALUES" && -f "$DOCS" ]]; then
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

if grep -q 'SCRIPT_REQUIRES="external-secrets"' "$SVC"; then
    pass "SCRIPT_REQUIRES names external-secrets"
else
    fail "SCRIPT_REQUIRES names external-secrets" "not found"
fi

_prio="$(grep -oE 'SCRIPT_PRIORITY="[0-9]+"' "$SVC" | grep -oE '[0-9]+')"
_collisions="$(grep -rl "SCRIPT_PRIORITY=\"$_prio\"" "$REPO"/provision-host/uis/services/*/*.sh | grep -v service-bao.sh)"
if [[ -z "$_collisions" ]]; then
    pass "SCRIPT_PRIORITY ($_prio) collides with no other service"
else
    fail "SCRIPT_PRIORITY ($_prio) collides with no other service" "also used by: $_collisions"
fi

# ── the priority actually runs bao after external-secrets (dependency order, not just metadata) ──

_eso_prio="$(grep -oE 'SCRIPT_PRIORITY="[0-9]+"' "$REPO/provision-host/uis/services/management/service-external-secrets.sh" | grep -oE '[0-9]+')"
if [[ "$_prio" -gt "$_eso_prio" ]]; then
    pass "bao's priority ($_prio) runs after external-secrets' ($_eso_prio)"
else
    fail "bao's priority ($_prio) runs after external-secrets' ($_eso_prio)" "bao would be attempted first"
fi

# ── no credential-carrying command/k8s_exec task is missing no_log, with one documented,
# structural exception: tasks authenticating as BAO_TOKEN inline cannot use the @file trick
# (unlike the one reviewer-JWT task this file explicitly does fix that way) because BAO_TOKEN is
# the CLI's own auth credential, not a parameter value - same tradeoff k3s-bao-ensure.yml's own
# root-token-authenticated tasks already accept. ──

_bad="$(python3 - "$SETUP" "$REMOVE" <<'PYEOF'
import re, sys
CRED = re.compile(r'(BAO_TOKEN=|--set[^\n]*(pass|secret|key)[^\n]*=|PASSWORD=|SECRET=|\{\{[^}]*(root_token|reviewer_jwt|seal_key|generated_seal_key)[^}]*\}\})', re.I)
PROSE_ONLY = re.compile(r'^\s+(ansible\.builtin\.)?(debug|assert|fail|set_fact):', re.M)
bad = []
for path in sys.argv[1:]:
    s = open(path).read()
    for t in re.split(r'(?m)^(?=\s*- name:)', s):
        m = re.match(r'\s*- name:\s*"?(.*)', t)
        if not m or PROSE_ONLY.search(t) or not CRED.search(t):
            continue
        if not re.search(r'(?m)^\s+no_log:\s*true', t):
            bad.append(f"{path}: {m.group(1).strip()[:50]}")
print(' | '.join(bad))
PYEOF
)"
if [[ -z "$_bad" ]]; then
    pass "no credential-carrying task is missing no_log"
else
    fail "no credential-carrying task is missing no_log" "$_bad"
fi

# ── the seal key and reviewer JWT are supplied as files, not inlined onto a command line
# (reviewer JWT: this session's own urb-agents#1947 fix, applied here from the start) ──

if grep -q 'k8s_cp' "$SETUP" && grep -q 'remote_path: "/tmp/reviewer.jwt"' "$SETUP"; then
    pass "the reviewer JWT is copied into the pod as a file, not inlined into a command"
else
    fail "the reviewer JWT is copied into the pod as a file, not inlined into a command" "no k8s_cp-to-/tmp/reviewer.jwt step found"
fi

if grep -q 'current_key    = "file:///bao-seal/seal.key"' "$VALUES"; then
    pass "the seal config references the mounted key by file, not inline"
else
    fail "the seal config references the mounted key by file, not inline" "not found in $VALUES"
fi

# ── urb-agents#1956 regression checks: the 5 real bugs a live cluster run found ──

if grep -q "SCRIPT_CHECK_COMMAND=\"kubectl get pods -n bao -l app.kubernetes.io/instance=bao" "$SVC"; then
    pass "SCRIPT_CHECK_COMMAND uses a label selector, not a hardcoded pod name"
else
    fail "SCRIPT_CHECK_COMMAND uses a label selector, not a hardcoded pod name" "found a literal pod name, or the check changed shape"
fi

if grep -qF 'bao_init.stdout | string' "$SETUP"; then
    pass "the persisted root token is cast with | string before serializing as a Secret"
else
    fail "the persisted root token is cast with | string before serializing as a Secret" "missing | string filter"
fi

if grep -qF 'eso_crd_api_version: "external-secrets.io/v1beta1"' "$SETUP" \
   && grep -qF 'eso_crd_api_version: "external-secrets.io/v1beta1"' "$REMOVE" \
   && ! grep -qE 'apiVersion: external-secrets\.io/v1[^b"]' "$SETUP" \
   && ! grep -qE 'api_version: external-secrets\.io/v1[^b"]' "$REMOVE"; then
    pass "ClusterSecretStore/ExternalSecret use v1beta1, matching the pinned ESO chart"
else
    fail "ClusterSecretStore/ExternalSecret use v1beta1, matching the pinned ESO chart" "v1beta1 var missing, or a bare v1 apiVersion still present"
fi

if grep -q 'label_selectors:' "$REMOVE" && grep -q 'PersistentVolumeClaim' "$REMOVE" && ! grep -qE 'name: "data-\{\{ bao_release \}\}-0"' "$REMOVE"; then
    pass "the purged PVC is found by label, not a hardcoded 'data-bao-0' name"
else
    fail "the purged PVC is found by label, not a hardcoded 'data-bao-0' name" "still hardcodes the PVC name, or the label lookup is missing"
fi

# ── the seal key and root token are never regenerated once they exist ──

if grep -q '(existing_seal_secret.resources | default(\[\]) | length) == 0' "$SETUP" \
   && grep -q '(existing_init_secret.resources | default(\[\]) | length) == 0' "$SETUP"; then
    pass "the seal key and root-token init are both guarded against regeneration"
else
    fail "the seal key and root-token init are both guarded against regeneration" "one or both guards missing"
fi

# ── remove preserves state by default, purges only when asked ──

if grep -q '_purge is defined and (_purge | bool)' "$REMOVE" && grep -q 'bao-seal-key' "$REMOVE" && grep -q 'bao-dev-init' "$REMOVE"; then
    pass "remove preserves the seal key/root token/data unless -e _purge=true"
else
    fail "remove preserves the seal key/root token/data unless -e _purge=true" "purge guard or one of the preserved resources missing"
fi

# ── `helm repo update` takes no --force-update flag (that belongs on `helm repo add`) -
# urb-agents#1956: this exact mistake blocked the playbook outright on a real cluster ──

if grep -qE 'helm repo update\s*$' "$SETUP" && ! grep -q 'helm repo update --force-update' "$SETUP"; then
    pass "helm repo update carries no --force-update flag"
else
    fail "helm repo update carries no --force-update flag" "found --force-update on 'helm repo update' in $SETUP"
fi

# ── docs index and cross-links ──

if grep -q "bao.md" "$MGMT_INDEX"; then
    pass "the management index links to the OpenBao page"
else
    fail "the management index links to the OpenBao page" "no link found"
fi

if grep -qi "dev-only deviations" "$DOCS"; then
    pass "the docs page states the dev-only deviations from production"
else
    fail "the docs page states the dev-only deviations from production" "missing section"
fi

# ── YAML parses, if a YAML engine is available (prefer the project's own) ──

_YAMLCHECK=""
if [[ -f "$REPO/website/node_modules/js-yaml/package.json" ]]; then
    _YAMLCHECK="node -e \"const y=require('$REPO/website/node_modules/js-yaml');const fs=require('fs');for(const f of process.argv.slice(1)){y.loadAll(fs.readFileSync(f,'utf8'))}\""
fi
if [[ -n "$_YAMLCHECK" ]]; then
    if eval "$_YAMLCHECK" "$SETUP" "$REMOVE" "$VALUES" 2>/tmp/bao-yaml-err; then
        pass "all three YAML files parse"
    else
        fail "all three YAML files parse" "$(cat /tmp/bao-yaml-err)"
    fi
else
    echo "  Testing: all three YAML files parse... SKIPPED (no js-yaml available on this host)"
fi

echo
echo "Passed: $PASS  Failed: $FAIL"
[[ $FAIL -eq 0 ]]
