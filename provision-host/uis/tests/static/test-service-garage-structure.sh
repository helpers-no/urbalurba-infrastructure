#!/bin/bash
# test-service-garage-structure.sh - the Garage service is wired together consistently
#
# 🔴 Written the same day as the service itself, with no cluster to run it
# against. This cannot prove `uis deploy garage` works - only that the files
# agree with each other and repeat none of the mistakes this repository has
# already paid for once (a credential in a displayable command, a missing
# KUBECONFIG, an unpinned image, a hardcoded workload name that does not
# exist on the proxy topology). imac's cluster run is what proves the rest.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
SVC="$REPO/provision-host/uis/services/storage/service-garage.sh"
SETUP="$REPO/ansible/playbooks/047-setup-garage.yml"
REMOVE="$REPO/ansible/playbooks/047-remove-garage.yml"
TEST_PB="$REPO/ansible/playbooks/047-test-garage.yml"
MANIFEST="$REPO/manifests/047-garage-config.yaml"
INGRESS="$REPO/manifests/048-garage-ingressroute.yaml"
ENV_TPL="$REPO/provision-host/uis/templates/secrets-templates/00-common-values.env.template"
YML_TPL="$REPO/provision-host/uis/templates/secrets-templates/00-master-secrets.yml.template"
EXPOSE="$REPO/provision-host/uis/lib/expose.sh"
DOCS="$REPO/website/docs/services/storage/garage.md"
STORAGE_INDEX="$REPO/website/docs/services/storage/index.md"

PASS=0; FAIL=0
pass() { echo -e "  Testing: $1... \033[0;32mPASS\033[0m"; ((++PASS)); }
fail() { echo -e "  Testing: $1... \033[0;31mFAIL\033[0m"; echo -e "    \033[0;31m→ $2\033[0m"; ((++FAIL)); }

echo "Garage service: structural consistency"

# ── the files this service claims to need all exist ──

start=1
if [[ -f "$SVC" && -f "$SETUP" && -f "$REMOVE" && -f "$TEST_PB" && -f "$MANIFEST" && -f "$INGRESS" ]]; then
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
_collisions="$(grep -rl "SCRIPT_PRIORITY=\"$_prio\"" "$REPO"/provision-host/uis/services/*/*.sh | grep -v service-garage.sh)"
if [[ -z "$_collisions" ]]; then
    pass "SCRIPT_PRIORITY ($_prio) collides with no other service"
else
    fail "SCRIPT_PRIORITY ($_prio) collides with no other service" "also used by: $_collisions"
fi

_expport="$(grep -oE 'SCRIPT_EXPOSE_PORT="[0-9]+"' "$SVC" | grep -oE '[0-9]+')"
_portcollisions="$(grep -rl "SCRIPT_EXPOSE_PORT=\"$_expport\"" "$REPO"/provision-host/uis/services/*/*.sh | grep -v service-garage.sh)"
if [[ -z "$_portcollisions" ]]; then
    pass "SCRIPT_EXPOSE_PORT ($_expport) collides with no other service"
else
    fail "SCRIPT_EXPOSE_PORT ($_expport) collides with no other service" "also used by: $_portcollisions"
fi

# ── the image is pinned, which is the whole lesson of the MinIO incident ──

start_test_label="the image is pinned to a real tag, not :latest"
if grep -qE 'image: dxflrs/garage:v[0-9]+\.[0-9]+\.[0-9]+' "$MANIFEST" && ! grep -q 'dxflrs/garage:latest' "$MANIFEST"; then
    pass "$start_test_label"
else
    fail "$start_test_label" "no pinned tag found, or :latest present"
fi

# ── no new instance of the password-in-argv defect this repo already paid for ──

_bad="$(python3 - "$SETUP" "$REMOVE" "$TEST_PB" <<'PYEOF'
import re, sys
CRED = re.compile(r'(--set[^\n]*(pass|secret|key)[^\n]*=|PASSWORD=|SECRET=|--password|\{\{[^}]*(password|secret_key|rpc_secret)[^}]*\}\})', re.I)
# ⚠️ First draft only matched command/shell/raw, reasoning from the Postgres
# leak (urb-agents#1743), which was always a command module echoing argv. But
# Ansible can echo ANY module's arguments on failure, not only command/shell -
# and this file's "10. Build and apply the garage.toml Secret" is a
# `kubernetes.core.k8s` task whose `definition:` carries garage_rpc_secret_fact.
# Mutation-testing this very assertion (remove that task's no_log) proved it:
# the old pattern did not even see the task, so removing no_log changed
# nothing it checked. Exclude only the modules that are PURE PROSE (debug,
# assert, fail, set_fact) rather than allow-listing which modules can leak -
# that list only grows as this file is extended.
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

_missing_kc="$(python3 - "$SETUP" "$REMOVE" "$TEST_PB" <<'PYEOF'
import re, sys
# ⚠️ First draft matched "kubectl" anywhere in a task, including inside a
# debug/assert task's own printed troubleshooting text ("Check layout:
# kubectl exec ..."). That is prose, not an invocation. Only command/shell/
# raw modules actually RUN kubectl, which is the same restriction the
# credential-leak sweep (test-postgres-deploy-does-not-log-the-password.sh)
# already uses, for the same reason.
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

# ── the MinIO s3.* route collision is actually warned about ──

if grep -q "s3.<domain> route collision" "$SETUP" && grep -qi "minio" "$SETUP"; then
    pass "setup warns about the s3.* collision with MinIO"
else
    fail "setup warns about the s3.* collision with MinIO" "no warning task found"
fi

# ── the IngressRoute claims both garage.* and the shared s3.* alias ──

if grep -q 'garage\\\.' "$INGRESS" && grep -q 's3\\\.' "$INGRESS"; then
    pass "the IngressRoute claims garage.* and the s3.* alias"
else
    fail "the IngressRoute claims garage.* and the s3.* alias" "one or both HostRegexp patterns missing"
fi

# ── secrets templates: all three vars present in both template files, consistently ──

_n=0
for v in GARAGE_ACCESS_KEY GARAGE_SECRET_KEY GARAGE_RPC_SECRET; do
    grep -q "^${v}=" "$ENV_TPL" && grep -q "\"\\\${${v}}\"" "$YML_TPL" && _n=$((_n+1))
done
if [[ $_n -eq 3 ]]; then
    pass "GARAGE_ACCESS_KEY / GARAGE_SECRET_KEY / GARAGE_RPC_SECRET are in both secrets templates"
else
    fail "GARAGE_ACCESS_KEY / GARAGE_SECRET_KEY / GARAGE_RPC_SECRET are in both secrets templates" "only $_n of 3 present in both files"
fi

_rpc="$(grep '^GARAGE_RPC_SECRET=' "$ENV_TPL" | cut -d= -f2)"
if [[ "$_rpc" =~ ^[0-9a-f]{64}$ ]]; then
    pass "GARAGE_RPC_SECRET's placeholder is valid 64-char hex, the shape Garage requires"
else
    fail "GARAGE_RPC_SECRET's placeholder is valid 64-char hex, the shape Garage requires" "got: $_rpc"
fi

_derived_from_shared="$(grep '^GARAGE_SECRET_KEY=' "$ENV_TPL" | grep -c 'DEFAULT_DATABASE_PASSWORD')"
if [[ "$_derived_from_shared" -eq 0 ]]; then
    pass "GARAGE_SECRET_KEY does not reuse the already-overloaded DEFAULT_DATABASE_PASSWORD"
else
    fail "GARAGE_SECRET_KEY does not reuse the already-overloaded DEFAULT_DATABASE_PASSWORD" "it does"
fi

# ── expose, docs index, and the service's own doc page ──

if grep -q '\["garage"\]=' "$EXPOSE"; then
    pass "./uis expose garage is wired in expose.sh"
else
    fail "./uis expose garage is wired in expose.sh" "no entry found"
fi

if [[ -f "$DOCS" ]] && grep -qi "what is different from minio" "$DOCS"; then
    pass "the docs page exists and states what differs from MinIO"
else
    fail "the docs page exists and states what differs from MinIO" "missing page or missing section"
fi

if grep -q "garage.md" "$STORAGE_INDEX"; then
    pass "the storage index links to the Garage page"
else
    fail "the storage index links to the Garage page" "no link found"
fi

# ── YAML parses, if a YAML engine is available (prefer the project's own) ──

_YAMLCHECK=""
if [[ -f "$REPO/website/node_modules/js-yaml/package.json" ]]; then
    _YAMLCHECK="node -e \"const y=require('$REPO/website/node_modules/js-yaml');const fs=require('fs');for(const f of process.argv.slice(1)){y.loadAll(fs.readFileSync(f,'utf8'))}\""
fi
if [[ -n "$_YAMLCHECK" ]]; then
    if eval "$_YAMLCHECK" "$SETUP" "$REMOVE" "$TEST_PB" "$MANIFEST" "$INGRESS" 2>/tmp/garage-yaml-err; then
        pass "all five YAML files parse"
    else
        fail "all five YAML files parse" "$(cat /tmp/garage-yaml-err)"
    fi
else
    echo "  Testing: all five YAML files parse... SKIPPED (no js-yaml available on this host)"
fi

# ── urb-agents#1802: the key-creation escalation and its fix ──

# ⚠️ First version matched the bare string "key deny --create-bucket"
# anywhere, including inside the FOLLOWING task's own fail_msg prose ("`garage
# key deny --create-bucket` did not succeed"). That survived the task itself
# being flipped to `allow` - reinstating the exact vulnerability - because
# the next task's message still said "deny". Anchor on the real invocation:
# it always runs the absolute binary path (`/garage key deny ...`); prose
# references it without the leading slash, via backticks.
if grep -qE '/garage key deny --create-bucket' "$SETUP" && ! grep -qE '/garage key allow --create-bucket' "$SETUP"; then
    pass "setup denies create-bucket permission on the bootstrap key"
else
    fail "setup denies create-bucket permission on the bootstrap key" "no 'deny' invocation found, or an 'allow' invocation is also present"
fi

if grep -q "15d\. Confirm the key no longer shows create-bucket permission" "$SETUP" \
   && grep -q "Can create buckets: true" "$SETUP"; then
    pass "the denial is verified by reading the key back, not by trusting the command's exit code"
else
    fail "the denial is verified by reading the key back, not by trusting the command's exit code" "no readback check found"
fi

if grep -q "s3api create-bucket" "$TEST_PB" && grep -q "escalation_test.rc != 0" "$TEST_PB"; then
    pass "the E2E test re-attempts the exact escalation and asserts it is refused"
else
    fail "the E2E test re-attempts the exact escalation and asserts it is refused" "no regression test for the escalation found"
fi

# ⚠️ First version matched the bare substring "HTTP_CODE:403" anywhere in the
# file - which a comment two tasks earlier, QUOTING the garbled-output bug it
# documents ("...reachable (HTTP_CODE:403pod..."), also contains. Mutating
# the real `that:` condition to a vacuous `true` left this check passing.
# Anchor on the exact Ansible expression, which appears nowhere else.
if grep -qF "\"'HTTP_CODE:403' in auth_test.stdout\"" "$TEST_PB"; then
    pass "the unsigned-request test now asserts the confirmed 403, not a soft check"
else
    fail "the unsigned-request test now asserts the confirmed 403, not a soft check" "still soft, or 403 not asserted"
fi

if grep -qi "imac proved it\|imac confirmed it\|imac proved the opposite" "$DOCS"; then
    pass "the docs correct the false 'scoped to one bucket' claim and credit the finding"
else
    fail "the docs correct the false 'scoped to one bucket' claim and credit the finding" "no correction found in garage.md"
fi

echo
echo "Passed: $PASS  Failed: $FAIL"
[[ $FAIL -eq 0 ]]
