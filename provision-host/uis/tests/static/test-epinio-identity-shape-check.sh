#!/bin/bash
# test-epinio-identity-shape-check.sh — a wrongly-shaped teams/groups list fails CLEARLY
#
# 🔴 Found live by ops (urb-agents#2040, Proxmox pass): 627-setup-epinio-identity.yml only
# checked that epinio_identity_*.teams/groups was a NON-EMPTY LIST. The old PoC's flat list of
# strings passed that, then died deep in the values template with a raw
# "'str object' has no attribute 'name'" — a message about Jinja, not about the input.
#
# ⚠️ This runs the REAL tasks under REAL Ansible, on purpose. A first draft of the check used a
# truthiness test on a possibly-missing attribute and passed every plain-Jinja check — then
# crashed with that exact raw error under Ansible, whose undefined handling is stricter than
# Jinja's default. Only the real engine shows it, so a text match would have been worthless here.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
PB="$REPO/ansible/playbooks/627-setup-epinio-identity.yml"

PASS=0; FAIL=0; SKIP=0
pass() { echo -e "  Testing: $1... \033[0;32mPASS\033[0m"; ((++PASS)); }
fail() { echo -e "  Testing: $1... \033[0;31mFAIL\033[0m"; echo -e "    \033[0;31m→ $2\033[0m"; ((++FAIL)); }

echo "=== epinio identity: teams/groups shape is validated with a clear message ==="

[[ -f "$PB" ]] || { fail "playbook present" "missing: $PB"; echo; echo "Passed: $PASS  Failed: $FAIL"; exit 1; }

if ! command -v ansible-playbook >/dev/null 2>&1 || ! python3 -c 'import yaml' 2>/dev/null; then
    if [[ -n "${CI:-}${GITHUB_ACTIONS:-}" ]]; then
        fail "ansible-playbook and pyyaml are available (required in CI)" "this check would skip, and a skipped check is how a crash-in-the-engine bug ships green"
        echo; echo "Passed: $PASS  Failed: $FAIL"; exit 1
    fi
    echo "  Testing: shape check under real Ansible... SKIPPED (no ansible-playbook/pyyaml on this host — CI runs it)"
    echo; echo "Passed: $PASS  Failed: $FAIL  Skipped: 1"; exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Lift the three real shape-check tasks out of the playbook into a scratch play, so the text
# under test is the playbook's own and not a copy that could drift from it.
_ntasks="$(python3 - "$PB" "$TMP/play.yml" <<'PYEOF'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
tasks = [t for t in d[0]["tasks"] if t["name"][:2] in ("3b", "4b", "5b")]
play = [{"name": "shape", "hosts": "localhost", "gather_facts": False,
         "vars": {"epinio_identity_github": {"enabled": False},
                  "epinio_identity_authentik": {"enabled": False},
                  "epinio_identity_okta": {"enabled": False}},
         "tasks": tasks}]
yaml.safe_dump(play, open(sys.argv[2], "w"))
print(len(tasks))
PYEOF
)"
if [[ "$_ntasks" == "3" ]]; then
    pass "control: the three shape-check tasks (3b, 4b, 5b) exist in the playbook"
else
    fail "control: the three shape-check tasks exist" "found $_ntasks — every check below would be vacuous"
    echo; echo "Passed: $PASS  Failed: $FAIL"; exit 1
fi

# _run <extra-vars-json>  ->  prints "OK", "CLEAR" (our message) or "RAW:<text>" (anything else)
_run() {
    local out
    out="$(cd "$TMP" && ANSIBLE_NOCOLOR=1 ansible-playbook play.yml -e "$1" 2>&1)"
    if grep -q 'failed=0' <<<"$out"; then echo OK
    elif grep -q 'must be a list of mappings' <<<"$out"; then echo CLEAR
    else echo "RAW:$(grep -m1 -E 'Task failed|fatal' <<<"$out" | cut -c1-120)"; fi
}

G='"enabled":true,"client_id":"a","org":"o"'
A='"enabled":true'

expect() {  # <label> <expected> <json>
    local got; got="$(_run "$3")"
    if [[ "$got" == "$2" ]]; then pass "$1"; else fail "$1" "expected $2, got $got"; fi
}

expect "a correct list of {name, roles} mappings passes" OK \
    '{"epinio_identity_github":{'"$G"',"teams":[{"name":"HQ","roles":["admin:workspace"]},{"name":"Ops","roles":["admin:ops","view:x"]}]}}'
expect "🔴 a flat list of strings (the old PoC shape, ops' exact case) fails CLEARLY, not with a Jinja error" CLEAR \
    '{"epinio_identity_github":{'"$G"',"teams":["HQ","Ops"]}}'
expect "a list mixing a mapping and a bare string fails clearly" CLEAR \
    '{"epinio_identity_github":{'"$G"',"teams":[{"name":"HQ","roles":["a"]},"Ops"]}}'
expect "a mapping with no roles fails clearly" CLEAR \
    '{"epinio_identity_github":{'"$G"',"teams":[{"name":"HQ"}]}}'
expect "a mapping with no name fails clearly" CLEAR \
    '{"epinio_identity_github":{'"$G"',"teams":[{"roles":["a"]}]}}'
expect "roles given as a string instead of a list fails clearly" CLEAR \
    '{"epinio_identity_github":{'"$G"',"teams":[{"name":"HQ","roles":"admin:ws"}]}}'
expect "an empty roles list fails clearly" CLEAR \
    '{"epinio_identity_github":{'"$G"',"teams":[{"name":"HQ","roles":[]}]}}'
expect "an empty name fails clearly" CLEAR \
    '{"epinio_identity_github":{'"$G"',"teams":[{"name":"","roles":["a"]}]}}'
expect "the Authentik connector's groups are checked too" CLEAR \
    '{"epinio_identity_authentik":{'"$A"',"groups":["HQ"]}}'
expect "the Okta connector's groups are checked too" CLEAR \
    '{"epinio_identity_okta":{'"$A"',"groups":["HQ"]}}'
expect "a correct Authentik groups list passes" OK \
    '{"epinio_identity_authentik":{'"$A"',"groups":[{"name":"HQ","roles":["admin:ws"]}]}}'

echo
echo "Passed: $PASS  Failed: $FAIL"
[[ $FAIL -eq 0 ]]
