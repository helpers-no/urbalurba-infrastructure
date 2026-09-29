#!/bin/bash
# test-authentik-waits-for-outpost.sh — deploy must not fail a race it can wait out
#
# 🔴 `uis deploy authentik` EXITED 1 on a cluster where authentik was fine.
# authentik's embedded outpost binds new providers about 1.5-2 minutes after the
# blueprint applies; tasks 50 and 51 probed ONCE, at roughly 0s and 17s, and
# task 52 turned the single 404 into a failed install (imac, urb-agents#1721).
#
# imac's log is what makes this a race rather than a guess — same request,
# nothing changed in between, only waiting:
#
#     11:51:06  404   <- task 50
#     11:51:23  404   <- task 51, then exit 1 at 11:51:30
#     11:52:58  302   <- outpost now has the providers bound
#
# ⚠️ Retry until the 302, not a longer fixed wait. A fixed wait is a guess that
# is too short on a loaded cluster and wasted on a fast one — and task 49
# already waits for the wrong thing, the middleware rather than the binding.
#
# 🔵 It also absorbs a known flakiness in this probe shape: `kubectl run --rm -i`
# can return rc=0 with empty stdout when the container outlives the attach,
# which reads as a failure. Retrying makes one bad sample harmless.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
PB="$REPO/ansible/playbooks/070-setup-authentik.yml"

PASS=0; FAIL=0
pass() { echo -e "  Testing: $1... \033[0;32mPASS\033[0m"; ((++PASS)); }
fail() { echo -e "  Testing: $1... \033[0;31mFAIL\033[0m"; echo -e "    \033[0;31m→ $2\033[0m"; ((++FAIL)); }

echo "=== the auth probe waits for the outpost instead of failing the install ==="

[[ -f "$PB" ]] || { fail "playbook present" "missing: $PB"; echo; echo "  Passed: $PASS  Failed: $FAIL"; exit 1; }

# The comments in this file and the playbook name every string below, so parse
# the YAML rather than grepping text — and that also proves it still parses.
_probe="$(python3 - "$PB" <<'PYEOF'
import sys, json
try:
    import yaml
except ImportError:
    print("NOYAML"); sys.exit(0)
d = yaml.safe_load(open(sys.argv[1]))
out = []
for t in d[0].get("tasks", []):
    n = t.get("name", "")
    if n.startswith("50.") or n.startswith("51."):
        out.append({"name": n, "until": t.get("until"), "retries": t.get("retries"),
                    "delay": t.get("delay"), "register": t.get("register")})
print(json.dumps(out))
PYEOF
)"

if [[ "$_probe" == "NOYAML" ]]; then
    # ⚠️ Fall back to text, but say so — a silent skip is how two unparseable
    # templates once shipped green.
    echo "  (no pyyaml here — falling back to a text scan, CI parses it properly)"
    _n=0
    grep -qF "until: \"'HTTP_STATUS:302' in whoami_auth_test.stdout\"" "$PB" && _n=$((_n+1))
    grep -qF "until: \"'HTTP_STATUS:302' in whoami_internal_auth_test.stdout\"" "$PB" && _n=$((_n+1))
    if [[ "$_n" -eq 2 ]]; then
        pass "both auth probes retry until a 302 (text scan)"
    else
        fail "both probes retry until a 302" "only $_n of 2"
    fi
else
    _count="$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1])))" "$_probe")"
    if [[ "$_count" == "2" ]]; then
        pass "control: both probe tasks were found and the playbook parses"
    else
        fail "control: both probe tasks found" "found $_count — the checks below would be vacuous"
        echo ""; echo "  Passed: $PASS  Failed: $FAIL"; exit 1
    fi

    # Each probe must retry on its OWN registered variable. Asserting only that
    # an `until` exists would pass on two tasks both watching the same one.
    _bad="$(python3 -c "
import json,sys
bad=[]
for t in json.loads(sys.argv[1]):
    u = t.get('until') or ''
    if '302' not in u: bad.append(t['name']+': until does not test for 302')
    elif t.get('register') and t['register'] not in u:
        bad.append(t['name']+': until watches '+u+' not its own '+t['register'])
    if not t.get('retries'): bad.append(t['name']+': no retries')
print('; '.join(bad))" "$_probe")"
    if [[ -z "$_bad" ]]; then
        pass "each probe retries until its OWN result shows a 302"
    else
        fail "each probe retries on its own result" "$_bad"
    fi

    # 🔴 The window must cover the delay imac measured (~112s). Too short and
    # this is the same defect with extra steps.
    _short="$(python3 -c "
import json,sys
bad=[]
for t in json.loads(sys.argv[1]):
    w=(t.get('retries') or 0)*(t.get('delay') or 0)
    if w < 180: bad.append(f\"{t['name']}: {w}s window\")
print('; '.join(bad))" "$_probe")"
    if [[ -z "$_short" ]]; then
        pass "the retry window is at least 180s, covering the ~112s measured"
    else
        fail "the window covers the measured delay" "$_short — the outpost took ~112s on one cluster"
    fi
fi

# --- and task 52 must still be able to fail -------------------------------
# ⚠️ The fix must not turn a real failure into a pass. If the 302 never comes,
# the install should still stop.
# ⚠️ Take the whole `when:` line, not just a substring of it. Checking that
# the text "not in whoami_auth_test.stdout" appears somewhere passes on a
# condition that has been disabled in front of it.
_w52="$(grep -F 'not in whoami_auth_test.stdout' "$PB" | head -1)"
if [[ -n "$_w52" ]] && ! grep -qE '\bfalse\b' <<<"$_w52"; then
    pass "task 52 still fails the install when no 302 ever appears"
else
    fail "a genuine failure is still caught" "the gate is '${_w52:-missing}' — the retry would mask a broken auth flow"
fi

# --- 🔴 match the STATUS, not the body ------------------------------------
# `'302' in stdout` also matches a 404 page whose HTML contains "302" — an
# asset hash, say. The command already appends HTTP_STATUS:%{http_code}, so
# the stricter form is free (imac, urb-agents#1725).
if grep -qE "until:.*'302' in" "$PB" && ! grep -qE "until:.*'HTTP_STATUS:302' in" "$PB"; then
    fail "the retry matches the status line" "'302' alone matches anywhere in the response body"
else
    pass "the retry matches HTTP_STATUS:302, not any 302 in the body"
fi

# ⚠️ And the gate must agree with the retry, or they disagree about what a
# pass is: the probe could stop retrying on a body match the gate then rejects.
_g="$(grep -F 'not in whoami_auth_test.stdout' "$PB" | head -1)"
if grep -qF 'HTTP_STATUS:302' <<<"$_g"; then
    pass "task 52's gate uses the same match as the retry"
else
    fail "the gate and the retry agree" "gate is '$_g' — it can reject what the retry accepted"
fi

# --- the delete remedy must be runnable as printed ------------------------
# 🔴 `undeploy` printed a bare relative path with no confirm flag, so the
# documented remedy failed with "Deletion aborted by user" when no user had
# aborted anything — it just had no TTY.
_RM="$REPO/ansible/playbooks/070-remove-authentik.yml"
_U09="$REPO/ansible/playbooks/utility/u09-authentik-create-postgres.yml"
# ⚠️ Require confirm=yes on the COMMAND line, not just mentioned in prose —
# the explanatory sentence beneath it also contains the word.
_SVC="$REPO/provision-host/uis/services/identity/service-authentik.sh"
_note="$(sed -n '/^SCRIPT_UNDEPLOY_NOTE="/,/"$/p' "$_SVC")"
_n=0
grep -qF 'ansible-playbook playbooks/utility/u09-authentik-create-postgres.yml -e operation=delete -e confirm=yes' <<<"$_note" && _n=$((_n+1))
grep -qF '/mnt/urbalurbadisk/ansible' <<<"$_note" && _n=$((_n+1))
grep -qF './uis shell' <<<"$_note" && _n=$((_n+1))
# Neither of the two shapes that failed to paste may come back.
grep -qF '\' <<<"$_note" && _n=0
grep -qE '^\s*".*",\s*$' <<<"$_note" && _n=0
# And the playbook must not print a command again: its output cannot be pasted.
grep -qF 'ansible-playbook playbooks/utility/u09' "$_RM" && _n=0
if [[ "$_n" -eq 3 ]]; then
    pass "the remedy is pasteable, and comes from uis rather than an Ansible debug task"
else
    fail "the remedy is runnable as printed" "only $_n of 3 — an agent cannot follow it"
fi

# 🔴 The guard must be on BOTH tasks — the prompt AND the abort. With it on
# only one, either the prompt still blocks an agent, or the abort fires after
# a confirmed run. Count them; one is not enough.
_guards="$(grep -cF "(confirm | default('')) | lower != 'yes'" "$_U09")"
_n=0
[[ "$_guards" -eq 2 ]] && _n=$((_n+1))
grep -qF 'Deletion NOT confirmed' "$_U09" && _n=$((_n+1))
if [[ "$_n" -eq 2 ]]; then
    pass "delete mode has a non-interactive path and no longer blames the user"
else
    fail "delete mode is usable without a TTY" "only $_n of 2 — confirm guard on $_guards of 2 tasks"
fi

# ⚠️ Comment-stripped: the comment explaining this defect QUOTES the old
# message, so a file-wide grep matches the explanation rather than the code.
if grep -v '^[[:space:]]*#' "$_U09" | grep -qF 'Deletion aborted by user'; then
    fail "the message does not blame a user who did nothing" "the old wording is back in the code"
else
    pass "the message does not blame a user who did nothing"
fi

echo ""
echo "  Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
