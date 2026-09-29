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
# 🔴 COUNT THE CALL SITES. DO NOT CHECK THAT A GUARDED ONE EXISTS.
#
# This test was 9/9 green while the security fix did not hold. It asserted that
# `elif type expose_service` matched — that *a* guarded call existed — and said
# nothing about the unguarded one 240 lines earlier, on the
# database-already-exists path. So first-time provisioning was fixed and every
# RE-RUN reopened the port (imac, urb-agents#1704).
#
# ⚠️ This file has two parallel tails and its own comments record the init file
# having the same bug. The guard is now a function, `_pg_maybe_expose`, and the
# rule is that exactly ONE `expose_service` call may exist in the file: the one
# inside it. imac's suggestion, and it is the right shape — a bare call is a
# defect by construction rather than something a reviewer has to notice.
_ex_calls="$(grep -cE '(^|[^_[:alnum:]])expose_service[[:space:]]+"' <<<"$pg")"
_ex_in_fn="$(sed -n '/^_pg_maybe_expose() {/,/^}/p' <<<"$pg" | grep -cE '(^|[^_[:alnum:]])expose_service[[:space:]]+"')"
if [[ "$_ex_calls" -eq 1 && "$_ex_in_fn" -eq 1 ]]; then
    pass "exactly one expose_service call exists, and it is inside the guard"
else
    fail "every expose_service call is inside the guard" \
         "$_ex_calls call(s) in the file, $_ex_in_fn of them inside _pg_maybe_expose — an unguarded call reopens the port"
fi

# And both tails must actually route through it, or one of them exposes nothing
# and the other is unprotected.
_via="$(grep -cE '^[[:space:]]*_pg_maybe_expose "' <<<"$pg")"
if [[ "$_via" -ge 2 ]]; then
    pass "both the create and the reuse tail call the guard ($_via call sites)"
else
    fail "both tails call the guard" "found $_via — the reuse path is what runs on every re-run"
fi

if grep -q 'if \[\[ -n "\$namespace" \]\]; then' <<<"$(sed -n '/^_pg_maybe_expose() {/,/^}/p' <<<"$pg")"; then
    pass "the guard decides on --namespace"
else
    fail "the guard decides on --namespace" "it would expose for in-cluster consumers again"
fi

# ⚠️ And it must say what it is doing when it DOES expose. The old output
# mentioned it in one informational line that read as progress.
_n=0
grep -qF 'keeps running after this command exits' <<<"$pg" && _n=$((_n+1))
grep -qF -- '--stop' <<<"$pg" && _n=$((_n+1))
if [[ "$_n" -eq 2 ]]; then
    pass "when it does expose, it says it persists and how to stop it"
else
    fail "the expose is announced honestly" "only $_n of 2 — it reads as progress rather than an opened port"
fi

# --- 5. the bind address, now that it has been measured -------------------
# 🔵 imac measured on Rancher Desktop that a LOOPBACK listener is reachable
# from a devcontainer via host.docker.internal (Lima's resolver points at the
# host, not the bridge gateway) and closed on the LAN — so all-interfaces
# bought the devcontainer case nothing (#1704).
#
# ⚠️ Bare-Linux native Docker was NOT measured, and there the bridge-gateway
# reasoning would apply. So the default is loopback and the escape hatch must
# be named in the output, not only in a document.
_exp="$(grep -v '^[[:space:]]*#' "$REPO/provision-host/uis/lib/expose.sh")"
_n=0
grep -qF 'UIS_EXPOSE_ADDRESS:-127.0.0.1' <<<"$_exp" && _n=$((_n+1))
grep -qF -- '--address "$bind_address"' <<<"$_exp" && _n=$((_n+1))
if [[ "$_n" -eq 2 ]]; then
    pass "expose binds loopback by default, through a single variable"
else
    fail "the bind address defaults to loopback" "only $_n of 2 — an exposed service is on the network again"
fi

_n=0
grep -qF 'NOT reachable from your network' <<<"$_exp" && _n=$((_n+1))
grep -qF 'UIS_EXPOSE_ADDRESS=0.0.0.0' <<<"$_exp" && _n=$((_n+1))
grep -qF 'reachable from your network' <<<"$_exp" && _n=$((_n+1))
if [[ "$_n" -eq 3 ]]; then
    pass "the output states the reach either way and names the override"
else
    fail "the reach and the override are in the output" "only $_n of 3 — the remedy arrives separately from the symptom"
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

# --- 2b. the REUSE tail must say what happened and where the credential is -
# ⚠️ It said "password reset" on a re-run that reused the credential — imac
# compared the Secret by hash and found it byte-identical (#1704) — and it
# offered no Secret reference at all, because 1.6.166 added that to the create
# tail only.
_reuse="$(sed -n '/already existed/,/^        return 0$/p' <<<"$pg")"
_n=0
grep -qF 'existing credential reused' <<<"$_reuse" && _n=$((_n+1))
grep -qF 'password ROTATED' <<<"$_reuse" && _n=$((_n+1))
grep -qF 'Read it: kubectl get secret' <<<"$_reuse" && _n=$((_n+1))
if [[ "$_n" -eq 3 ]]; then
    pass "the reuse tail distinguishes reuse from rotation and names the Secret"
else
    fail "the reuse tail is accurate and useful" "only $_n of 3 — it claimed a reset that did not happen"
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
# ⚠️ And the one thing the #1676 command actually depended on: `--init-file -`
# reads stdin. The flag was listed without it, so a reader would look for a path.
grep -qF 'read the SQL from stdin' <<<"$_usage" || _n=0
if [[ "$_n" -eq 3 ]]; then
    pass "the usage text lists the three flags that were undiscoverable"
else
    fail "the undiscoverable flags are documented" "only $_n of 3 — the command still has to be handed over"
fi

echo ""
echo "  Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
