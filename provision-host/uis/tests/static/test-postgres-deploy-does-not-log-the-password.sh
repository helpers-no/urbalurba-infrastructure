#!/bin/bash
# test-postgres-deploy-does-not-log-the-password.sh
#
# Ansible echoes a failed command task's whole `cmd`. 040-database-postgresql.yml
# passes the Postgres SUPERUSER password in argv in two tasks, so a failure
# printed it (imac, urb-agents#1743): once from 8d, and — measured on a clean
# cluster after a DNS timeout — from the base `helm install` in task 7, which
# predates the extensions work and went unnoticed because it only shows on a
# failed first attempt.
#
# A task that hides its command must still explain its failure, or the leak
# is traded for "the output has been hidden" and no cause. So this checks both.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"
if [[ -d "/mnt/urbalurbadisk/provision-host/uis" ]]; then ROOT="/mnt/urbalurbadisk"
else ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"; fi
PB="$ROOT/ansible/playbooks/040-database-postgresql.yml"

print_test_section "040-database-postgresql: no credential in a displayable command"

start_test "No command task carries the password without no_log"
bad="$(python3 - "$PB" <<'PYEOF'
import re, sys
s = open(sys.argv[1]).read()
CRED = re.compile(r'(--set[^\n]*(pass|secret|token|key)[^\n]*=|PGPASSWORD=|--password|\{\{[^}]*(password|passwd|secret|token)[^}]*\}\})', re.I)
RUN = re.compile(r'^\s+(ansible\.builtin\.)?(command|shell|raw):', re.M)
out = []
for t in re.split(r'(?m)^(?=\s*- name:)', s):
    m = re.match(r'\s*- name:\s*(.*)', t)
    if not m or not RUN.search(t) or not CRED.search(t): continue
    # `set_fact`-style reads of the password are not commands; only commands are listed.
    if not re.search(r'(?m)^\s+no_log:\s*true', t):
        out.append(m.group(1).strip()[:60])
print(' | '.join(out))
PYEOF
)"
if [[ -z "$bad" ]]; then pass_test; else fail_test "Credential-carrying commands without no_log: $bad"; fi

start_test "🔴 The base helm install is hidden — the one imac actually leaked from"
blk="$(awk '/- name: 7. Deploy PostgreSQL using Helm/,/- name: "7a/' "$PB")"
if echo "$blk" | grep -q "no_log: true" && echo "$blk" | grep -q "auth.postgresPassword"; then
    pass_test
else
    fail_test "Task 7 still passes the superuser password without no_log"
fi

start_test "…and its failure is still reported with a cause, not censored"
if grep -q '7a. Fail if the PostgreSQL install did not succeed' "$PB"; then
    pass_test
else
    fail_test "no_log with no follow-up failure task: a failed install would be silent or unexplained"
fi

start_test "That failure gates on the return code and tolerates the already-installed (skipped) case"
f7a="$(awk '/7a. Fail if the PostgreSQL install did not succeed/,/- name: 8\./' "$PB")"
n=0
echo "$f7a" | grep -qF "pg_helm_install.rc != 0" && n=$((n+1))
echo "$f7a" | grep -qF "pg_helm_install.rc is defined" && n=$((n+1))
if [[ $n -eq 2 ]]; then pass_test; else fail_test "only $n of 2 guards (rc != 0, rc is defined): $f7a"; fi

start_test "Task 7 must not swallow the failure: failed_when false is only safe next to 7a"
if echo "$blk" | grep -q "failed_when: false"; then
    if echo "$f7a" | grep -qF "pg_helm_install.rc != 0"; then pass_test
    else fail_test "failed_when: false without a rc check — a failed install would pass"; fi
else
    pass_test
fi

start_test "Both failure reports redact the password rather than trusting stderr to omit it"
n=$(grep -c "replace(postgres_password, '\*\*\*\*\*\*\*\*')" "$PB")
if [[ "$n" -ge 3 ]]; then pass_test; else fail_test "Expected redaction in 7a, 8d2 stderr and stdout (3); found $n"; fi

start_test "Task 7 keeps its KUBECONFIG — adding no_log must not strip the environment"
if echo "$blk" | grep -q 'KUBECONFIG: "{{ merged_kubeconf_file }}"'; then pass_test
else fail_test "Task 7 lost its KUBECONFIG environment"; fi

print_summary
