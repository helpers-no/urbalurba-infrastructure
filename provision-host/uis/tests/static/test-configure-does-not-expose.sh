#!/bin/bash
# test-configure-does-not-expose.sh — provisioning a database must not open it
#
# 🔴 `uis configure postgresql --namespace <ns>` auto-exposed the SHARED
# PostgreSQL on the host with `kubectl port-forward --address 0.0.0.0`, in the
# background, so it outlived the command. imac measured port 35432 answering on
# the machine's LAN address with the host firewall inactive, while provisioning
# an application's database — the instance holding atlas, open to the local
# network as a side effect (urb-agents#1700 item 1).
#
# ⚠️ `--namespace` is the signal that the consumer is IN-CLUSTER: it is the flag
# that says "write the credential into a Secret here". The host port-forward
# serves the other case, a DCT devcontainer reaching host.docker.internal. They
# are alternatives, so --namespace rules the expose out.
#
# 🔵 The bind address is deliberately unchanged. Narrowing to loopback looks
# like obvious hardening and breaks what expose exists for: on Linux a
# container reaching host.docker.internal arrives at the docker bridge gateway,
# not 127.0.0.1. That is a separate decision.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
PG="$REPO/provision-host/uis/lib/configure-postgresql.sh"
CFG="$REPO/provision-host/uis/lib/configure.sh"

PASS=0; FAIL=0
pass() { echo -e "  Testing: $1... \033[0;32mPASS\033[0m"; ((++PASS)); }
fail() { echo -e "  Testing: $1... \033[0;31mFAIL\033[0m"; echo -e "    \033[0;31m→ $2\033[0m"; ((++FAIL)); }

echo "=== configure provisions without exposing, and without printing secrets ==="

for f in "$PG" "$CFG"; do
    [[ -f "$f" ]] || { fail "file present" "missing: $f"; echo; echo "  Passed: $PASS  Failed: $FAIL"; exit 1; }
done

# Comments in this file and in the source name every string below, so scan the
# comment-stripped source or the fix could be reverted and the prose pass.
pg="$(grep -v '^[[:space:]]*#' "$PG")"
cfg="$(grep -v '^[[:space:]]*#' "$CFG")"

if grep -q 'expose_service' <<<"$pg"; then
    pass "control: the comment-stripped scan still sees the expose call"
else
    fail "control: the scan sees the code" "stripping removed it — every check below is vacuous"
    echo ""; echo "  Passed: $PASS  Failed: $FAIL"; exit 1
fi

# --- 1. the expose must be gated on --namespace being absent ---------------
if grep -q 'elif type expose_service' <<<"$pg"; then
    pass "the auto-expose is an elif on the --namespace branch, not unconditional"
else
    fail "the expose is gated on --namespace" "provisioning for an in-cluster consumer opens the host port again"
fi

# ⚠️ And it must say what it is doing when it DOES expose. The old output
# mentioned it in one informational line that read as progress.
_n=0
grep -qF 'binds ALL interfaces' <<<"$pg" && _n=$((_n+1))
grep -qF 'keeps running after this command exits' <<<"$pg" && _n=$((_n+1))
grep -qF -- '--stop' <<<"$pg" && _n=$((_n+1))
if [[ "$_n" -eq 3 ]]; then
    pass "when it does expose, it says the reach, the persistence and how to stop"
else
    fail "the expose is announced honestly" "only $_n of 3 — it reads as progress rather than an opened port"
fi

# --- 2. the credential must not go to stdout when it has a home -----------
# 🔴 For an agent, stdout IS its transcript. #1676 had to carry "do not post
# the output" because configure printed the password and two URLs holding it.
_human="$(sed -n '/PostgreSQL configured for/,/^    fi$/p' <<<"$pg")"
_pwline="$(grep -c 'echo "  Password: \$app_password"' <<<"$_human")"
if [[ "$_pwline" -eq 1 ]] && grep -q 'else' <<<"$_human"; then
    pass "the password is printed on one branch only, not unconditionally"
else
    fail "the password is conditional" "found $_pwline unconditional password lines"
fi

# The namespace branch must offer the Secret instead — and a way to read it.
_n=0
grep -qF 'Secret:  $secret_name' <<<"$_human" && _n=$((_n+1))
grep -qF 'Read it: kubectl get secret' <<<"$_human" && _n=$((_n+1))
if [[ "$_n" -eq 2 ]]; then
    pass "with --namespace it prints the Secret reference and how to read it"
else
    fail "the Secret is offered in place of the password" "only $_n of 2 — the credential is removed with nothing in its place"
fi

# ⚠️ The local case has nowhere else to put it, so it MUST still print.
if grep -q 'host.docker.internal:\$expose_port' <<<"$_human"; then
    pass "without --namespace the local connection string still prints"
else
    fail "the local case still returns a usable credential" "there is no Secret to read it from"
fi

# --- 4. the Secret must be identifiable as UIS's ---------------------------
_sec="$(sed -n '/_pg_create_secret()/,/^}/p' <<<"$pg")"
_n=0
grep -qF 'app.kubernetes.io/managed-by=uis' <<<"$_sec" && _n=$((_n+1))
grep -qF 'urbalurba.io/generated-by=configure-postgresql' <<<"$_sec" && _n=$((_n+1))
if [[ "$_n" -eq 2 ]]; then
    pass "the Secret is labelled, so a rebuild can tell it from a hand-made one"
else
    fail "the Secret carries labels" "only $_n of 2 — it is indistinguishable from one made by hand"
fi

# --- 3. the flags must be discoverable ------------------------------------
if grep -qE '\-\-help\|-h\)' <<<"$cfg"; then
    pass "configure accepts --help instead of refusing it as unknown"
else
    fail "configure has --help" "'Unknown option: --help' was the only way to find out"
fi

# ⚠️ Scope this to the USAGE FUNCTION. Grepping the whole file matched the
# argument parser's own `--secret-name-prefix)` case label, so the check passed
# with the flag deleted from the help text — vacuous until a mutation found it.
_usage="$(sed -n '/^_configure_usage() {/,/^}/p' "$CFG")"
_n=0
for fl in --init-file --namespace --secret-name-prefix; do
    grep -qE "^  $fl " <<<"$_usage" && _n=$((_n+1))
done
if [[ "$_n" -eq 3 ]]; then
    pass "the usage text lists the three flags that were undiscoverable"
else
    fail "the undiscoverable flags are documented" "only $_n of 3 — the command still has to be handed over"
fi

echo ""
echo "  Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
