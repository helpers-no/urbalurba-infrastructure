#!/bin/bash
# test-github-runner-cli-commands.sh — `uis github-runner register/remove/list`
#
# urb-agents#2053's own follow-on ask, after PR #654 made the playbooks safely
# multi-instance: standing up an additional instance still required a raw
# `ansible-playbook ... -e key=value` invocation, because `uis deploy <service>`
# has no general mechanism for passing a service's own per-instance parameters
# through (the same urb-agents#1928-class gap forgejo-runner shares). This adds
# a dedicated `uis github-runner register/remove/list` command family, modeled
# directly on the proven `uis argocd register/remove/list` shape — including
# reading the GitHub PAT from the already-configured GITHUB_ACCESS_TOKEN secret
# rather than asking for one on the command line every time.
#
# This static test can't actually register a runner (no live cluster here), so
# it asserts the STRUCTURE that produces the right behavior.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
CLI="$REPO/provision-host/uis/manage/uis-cli.sh"

PASS=0; FAIL=0
pass() { echo -e "  Testing: $1... \033[0;32mPASS\033[0m"; ((++PASS)); }
fail() { echo -e "  Testing: $1... \033[0;31mFAIL\033[0m"; echo -e "    \033[0;31m→ $2\033[0m"; ((++FAIL)); }

echo "=== uis github-runner register/remove/list (urb-agents#2053 follow-on) ==="

[[ -f "$CLI" ]] || { fail "file present" "missing: $CLI"; echo; echo "  Passed: $PASS  Failed: $FAIL"; exit 1; }

cli="$(grep -v '^[[:space:]]*#' "$CLI")"

if grep -q 'cmd_argocd_register' <<<"$cli"; then
    pass "control: the comment-stripped scan still sees real functions"
else
    fail "control: the scan sees functions" "stripping removed everything — every check below is vacuous"
    echo ""; echo "  Passed: $PASS  Failed: $FAIL"; exit 1
fi

# --- the verb is actually wired into the main dispatcher --------------------
if grep -qE 'github-runner\)[[:space:]]*$' <<<"$cli" && grep -qF 'cmd_github_runner "$@"' <<<"$cli"; then
    pass "'github-runner' is dispatched to cmd_github_runner"
else
    fail "dispatch wired" "'uis github-runner ...' would fall through to 'unknown command'"
fi

_register_fn="$(sed -n '/^cmd_github_runner_register()/,/^}/p' "$CLI")"
[[ -n "$_register_fn" ]] || { fail "cmd_github_runner_register exists" "function not found"; echo; echo "  Passed: $PASS  Failed: $FAIL"; exit 1; }

# --- both instance and repo are mandatory, checked together -----------------
if grep -qE '\[\[ -z "\$instance" \|\| -z "\$repo" \]\]' <<<"$_register_fn"; then
    pass "register requires both <instance> and <owner/repo>"
else
    fail "both args required" "a bare 'uis github-runner register' could reach the playbook with an empty repo or instance"
fi

# --- the instance name is validated BEFORE anything else happens ------------
# 🔴 Order matters: validating after minting a token would waste a real
# GitHub API call (and a 1-hour-lived token) on a name that was always invalid.
_before_pat="$(sed -n '1,/_github_runner_pat/p' <<<"$_register_fn")"
if grep -qE "instance.*=~.*\^\[a-z0-9\]" <<<"$_before_pat"; then
    pass "instance name is validated before minting a registration token"
else
    fail "instance validated first" "an invalid instance name would only surface after a token was already minted and discarded"
fi

# --- the repo must be owner/repo shaped --------------------------------------
if grep -qE 'repo.*=~.*\^\[\^/\[:space:\]\]\+/\[\^/\[:space:\]\]\+\$' <<<"$_register_fn"; then
    pass "repo is validated as 'owner/repo'"
else
    fail "repo shape validated" "a malformed repo string would only fail deep inside the playbook, with a worse error"
fi

# --- the PAT comes from the shared secret, never a CLI flag ------------------
if grep -qF '_github_runner_pat' <<<"$_register_fn" && ! grep -qE -- '--pat\)' <<<"$cli"; then
    pass "PAT is read from the configured secret, not typed on the command line"
else
    fail "PAT via secret" "a --pat flag (or missing _github_runner_pat call) would put a token in shell history/process args"
fi

_pat_fn="$(sed -n '/^_github_runner_pat()/,/^}/p' "$CLI")"
if grep -qF 'GITHUB_ACCESS_TOKEN' <<<"$_pat_fn"; then
    pass "reads the SAME GITHUB_ACCESS_TOKEN secret 'uis argocd register' already uses"
else
    fail "shared PAT secret" "a second, different place to configure a GitHub token would be a worse UX than reusing the one that exists"
fi

# --- --force is the ONLY way to retarget, and it must reach the playbook ----
if grep -qF 'github_runner_force=true' <<<"$_register_fn"; then
    pass "--force is forwarded as github_runner_force=true"
else
    fail "--force forwarded" "the playbook's own collision-refusal (task 3c) could never be overridden from the CLI"
fi

# --- remove is instance-scoped, never touches another instance --------------
_remove_fn="$(sed -n '/^cmd_github_runner_remove()/,/^}/p' "$CLI")"
[[ -n "$_remove_fn" ]] || { fail "cmd_github_runner_remove exists" "function not found"; echo; echo "  Passed: $PASS  Failed: $FAIL"; exit 1; }

if grep -qF 'github_runner_instance=$instance' <<<"$_remove_fn"; then
    pass "remove passes the SAME instance it was given, nothing implicit"
else
    fail "remove is instance-scoped" "remove could default to the wrong instance, or the unnamed one"
fi

# 🔴 NOT just '[[ -z "$instance" ]]' — the arg-parsing loop above ALSO
# contains that exact substring ('[[ -z "$instance" ]] && instance="$1"'),
# so a bare substring check here would pass even with the refusal deleted
# outright. The refusal is the one followed by '; then', the loop's own use
# of the same test is followed by '&&' instead.
if grep -qE '\[\[ -z "\$instance" \]\]; then' <<<"$_remove_fn"; then
    pass "remove refuses with no instance given, rather than guessing one"
else
    fail "remove requires an instance" "a bare 'uis github-runner remove' could remove the wrong (or the default) instance"
fi

# --- list selects on the same label the setup/remove playbooks already use --
_list_fn="$(sed -n '/^cmd_github_runner_list()/,/^}/p' "$CLI")"
[[ -n "$_list_fn" ]] || { fail "cmd_github_runner_list exists" "function not found"; echo; echo "  Passed: $PASS  Failed: $FAIL"; exit 1; }

# 🔴 Not a bare substring check — 'app=github-runner' is itself a substring of
# 'app=github-runner-wrong', so a selector quietly pointed at the wrong label
# would still pass a plain grep -F here.
if grep -qE 'app=github-runner([^-a-zA-Z0-9]|$)' <<<"$_list_fn"; then
    pass "list selects on 'app=github-runner' — the same label every instance carries"
else
    fail "list selector matches" "list could silently miss instances the setup playbook actually created"
fi

echo ""
echo "  Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
