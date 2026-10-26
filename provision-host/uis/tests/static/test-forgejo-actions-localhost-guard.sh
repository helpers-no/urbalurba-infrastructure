#!/bin/bash
# test-forgejo-actions-localhost-guard.sh — forgejo_actions_default_url=self must be
# refused on a .localhost domain, not left to fail deep inside a workflow run.
#
# urb-agents#2028 (imac, live on Rancher Desktop): the forgejo-runner Pod's hostAliases
# entry for a .localhost hostname only patches the Pod's own /etc/hosts — the actual
# git-clone-for-actions step runs inside a container spawned through the dind sidecar's
# own inner Docker engine, a separate network namespace with no hostAlias entries, so
# every clone fails to connect (mirrored action or not). No real fix exists yet (a
# genuine design call, see 635-setup-forgejo.yml's own comment) — this guards the
# refusal added in its place, so the failure is immediate and named, not a cryptic
# "Could not connect to server" minutes into a real workflow run.
#
# Runs ansible-playbook for real, not a grep proxy — task 1b fails before anything
# touches a cluster, so this needs no inventory/kubeconfig, same as a plain
# --syntax-check, but actually exercises the `when:` condition's real Jinja evaluation
# (Ansible's own `search` test, not available in a bare jinja2.Environment).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"

if [[ -d "/mnt/urbalurbadisk/provision-host/uis" ]]; then
    ROOT="/mnt/urbalurbadisk"
else
    ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
fi
PB="$ROOT/ansible/playbooks/635-setup-forgejo.yml"

print_test_section "urb-agents#2028: self-mirror opt-in refused on a .localhost domain"

start_test "the playbook is where this test thinks it is"
[[ -f "$PB" ]] && pass_test || { fail_test "missing: $PB"; print_summary; exit $?; }

command -v ansible-playbook >/dev/null 2>&1 || {
    start_test "ansible-playbook available for a real run"
    skip_test "no ansible-playbook on this host"
    print_summary
    exit 0
}

start_test "🔴 refuses when the opt-in is set against the default .localhost domain"
_out="$(ansible-playbook "$PB" -e target_host=rancher-desktop \
        -e forgejo_actions_default_url=self 2>&1)"
if echo "$_out" | grep -q "1b\. Refuse the actions-self-mirror opt-in" \
   && echo "$_out" | grep -q "urb-agents#2028"; then
    pass_test
else
    fail_test "expected task 1b to fire and name urb-agents#2028, got:\n$_out"
fi

start_test "...and does NOT refuse when the opt-in is left unset (the default, working path)"
_out="$(ansible-playbook "$PB" -e target_host=rancher-desktop \
        -e forgejo_actions_default_url= 2>&1)"
if echo "$_out" | grep -qF "TASK [1b. Refuse the actions-self-mirror opt-in"; then
    if echo "$_out" | grep -A2 "TASK \[1b\." | grep -q "^skipping:"; then
        pass_test
    else
        fail_test "task 1b ran instead of skipping with the opt-in unset:\n$_out"
    fi
else
    fail_test "task 1b not found in the run at all:\n$_out"
fi

start_test "...and does NOT refuse against a real, routable domain (Proxmox-shaped) even with the opt-in set"
_out="$(ansible-playbook "$PB" -e target_host=proxmox \
        -e forgejo_domain=forgejo.lab.example.net \
        -e forgejo_actions_default_url=self 2>&1)"
if echo "$_out" | grep -A2 "TASK \[1b\." | grep -q "^skipping:"; then
    pass_test
else
    fail_test "task 1b fired against a non-.localhost domain:\n$_out"
fi

print_summary
