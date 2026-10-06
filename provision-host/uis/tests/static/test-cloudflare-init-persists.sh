#!/bin/bash
# test-cloudflare-init-persists.sh — `uis network init cloudflare` must not accept a
# value at the prompt and then fail to record it.
#
# WHY THIS EXISTS. init.sh wrote the master template with
# `sed -i "s|^KEY=.*|KEY=value|"`. sed exits 0 whether or not the pattern matched,
# so when the key was absent the edit did nothing, and the wizard still printed
# "✓ Cloudflare config ready" listing the domain the operator had just typed. The
# value was echoed back and dropped in the same breath.
#
# That is reachable, not hypothetical: two code paths produce
# .uis.secrets/secrets-config/00-common-values.env.template and they do not agree
# on which keys exist.
#
#   first-run.sh::copy_secrets_templates  copies templates/secrets-templates/
#   secrets-management.sh::init_secrets   copies templates/default-secrets.env
#
# Only the first has BASE_DOMAIN_CLOUDFLARE. On a machine seeded by the second,
# `uis network verify cloudflare` then skipped its end-to-end probe with no
# explanation, because the domain it needed had never been written.
#
# These tests run the real _set_kv from init.sh. The discriminating case is the
# absent key: the old sed passed the present-key case perfectly well, so a test
# that only checked that would not have caught the bug.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"

if [[ -d "/mnt/urbalurbadisk/networking/cloudflare/scripts" ]]; then
    INIT_SH="/mnt/urbalurbadisk/networking/cloudflare/scripts/init.sh"
else
    INIT_SH="$(cd "$SCRIPT_DIR/../../../../networking/cloudflare/scripts" && pwd)/init.sh"
fi

print_test_section "Cloudflare init persistence Tests"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Run the real _set_kv lifted from init.sh.
_run_set_kv() {
    local file="$1" key="$2" value="$3"
    bash -c '
        set -euo pipefail
        '"$(sed -n '/^_set_kv() {/,/^}/p' "$INIT_SH")"'
        _set_kv "'"$file"'" "'"$key"'" "'"$value"'"
    '
}

start_test "init.sh defines _set_kv instead of a bare in-place sed"
if grep -q '^_set_kv() {' "$INIT_SH"; then
    pass_test
else
    fail_test "no _set_kv — a silent sed no-op can drop the operator's input again"
fi

start_test "init.sh no longer seds the master template in place"
if grep -qE 'sed -i.*\^(CLOUDFLARE_TUNNEL_TOKEN|BASE_DOMAIN_CLOUDFLARE)=' "$INIT_SH"; then
    fail_test "the in-place sed is back; it succeeds when it matches nothing"
else
    pass_test
fi

# --- the case the old code handled ---
start_test "_set_kv replaces a key that is present"
printf 'A=1\nBASE_DOMAIN_CLOUDFLARE=your-domain.com\nB=2\n' > "$TMP/present.env"
_run_set_kv "$TMP/present.env" BASE_DOMAIN_CLOUDFLARE "example.com"
if [[ "$(grep -c '^BASE_DOMAIN_CLOUDFLARE=' "$TMP/present.env")" -eq 1 ]] \
   && grep -q '^BASE_DOMAIN_CLOUDFLARE=example.com$' "$TMP/present.env"; then
    pass_test
else
    fail_test "expected exactly one replaced line, got: $(grep '^BASE_DOMAIN_CLOUDFLARE=' "$TMP/present.env")"
fi

# --- THE DISCRIMINATING CASE: what the old code silently dropped ---
start_test "_set_kv appends a key that is absent (the dropped-domain bug)"
printf 'A=1\nB=2\n' > "$TMP/absent.env"
_run_set_kv "$TMP/absent.env" BASE_DOMAIN_CLOUDFLARE "example.com"
if grep -q '^BASE_DOMAIN_CLOUDFLARE=example.com$' "$TMP/absent.env"; then
    pass_test
else
    fail_test "value was accepted and lost — the file has: $(cat "$TMP/absent.env" | tr '\n' ' ')"
fi

start_test "_set_kv leaves the rest of the file alone"
printf 'A=1\nBASE_DOMAIN_CLOUDFLARE=old\nB=2\n# comment\n' > "$TMP/rest.env"
cp "$TMP/rest.env" "$TMP/rest.before"
_run_set_kv "$TMP/rest.env" BASE_DOMAIN_CLOUDFLARE "example.com"
if [[ "$(diff "$TMP/rest.before" "$TMP/rest.env" | grep -c '^[<>]')" -eq 2 ]]; then
    pass_test
else
    fail_test "collateral edits: $(diff "$TMP/rest.before" "$TMP/rest.env" | tr '\n' ' ')"
fi

start_test "_set_kv does not match a commented-out key"
printf '# BASE_DOMAIN_CLOUDFLARE=commented\nA=1\n' > "$TMP/comment.env"
_run_set_kv "$TMP/comment.env" BASE_DOMAIN_CLOUDFLARE "example.com"
if grep -q '^# BASE_DOMAIN_CLOUDFLARE=commented$' "$TMP/comment.env" \
   && grep -q '^BASE_DOMAIN_CLOUDFLARE=example.com$' "$TMP/comment.env"; then
    pass_test
else
    fail_test "comment was overwritten or the key was not appended"
fi

# sed's replacement side treats & and \ specially and init.sh only escaped |,
# so a value containing them would have been corrupted. Tunnel tokens are
# base64url and cannot, but the function should not depend on that.
start_test "_set_kv writes values containing sed metacharacters verbatim"
printf 'KEY=old\n' > "$TMP/meta.env"
_run_set_kv "$TMP/meta.env" KEY 'a&b\c|d'
if [[ "$(cat "$TMP/meta.env")" == 'KEY=a&b\c|d' ]]; then
    pass_test
else
    fail_test "value was mangled: $(cat "$TMP/meta.env")"
fi

start_test "_set_kv keeps the file owner-only"
printf 'KEY=old\n' > "$TMP/perm.env"
chmod 600 "$TMP/perm.env"
_run_set_kv "$TMP/perm.env" KEY new
if [[ "$(stat -c '%a' "$TMP/perm.env" 2>/dev/null || stat -f '%Lp' "$TMP/perm.env")" == "600" ]]; then
    pass_test
else
    fail_test "mode is now $(stat -c '%a' "$TMP/perm.env" 2>/dev/null || stat -f '%Lp' "$TMP/perm.env") — this file holds a tunnel token"
fi

# --- --env: multiple named tunnels on one installation ---
# Omitting --env must stay byte-identical to the original single-tunnel
# behavior (the backward-compatibility hinge of the whole multi-env design);
# a given --env must validate against the canonical list in cloudflare-envs.sh
# and ride the SAME _set_kv append mechanism already proven above, not a new
# ad-hoc writer.

start_test "_set_kv appends a new env-suffixed key exactly like BASE_DOMAIN_CLOUDFLARE"
printf 'A=1\n' > "$TMP/envsuffix.env"
_run_set_kv "$TMP/envsuffix.env" CLOUDFLARE_TUNNEL_TOKEN_TEST "abc123"
if grep -q '^CLOUDFLARE_TUNNEL_TOKEN_TEST=abc123$' "$TMP/envsuffix.env"; then
    pass_test
else
    fail_test "env-suffixed key was not appended: $(cat "$TMP/envsuffix.env" | tr '\n' ' ')"
fi

start_test "init.sh sources cloudflare-envs.sh"
if grep -q 'cloudflare-envs.sh' "$INIT_SH"; then
    pass_test
else
    fail_test "init.sh does not source the canonical env list"
fi

start_test "init.sh rejects an unknown --env before any TTY interaction"
out="$(bash "$INIT_SH" --env bogus < /dev/null 2>&1)"; rc=$?
if [[ $rc -ne 0 ]] && grep -q "Unknown --env" <<<"$out"; then
    pass_test
else
    fail_test "expected a clean rejection, got (rc=$rc): $out"
fi

start_test "init.sh omitting --env writes the bare cloudflare.env path"
out="$(bash "$INIT_SH" < /dev/null 2>&1)"; rc=$?
if [[ $rc -ne 0 ]] && grep -q "requires an interactive terminal" <<<"$out" \
   && ! grep -q "environment:" <<<"$out"; then
    pass_test
else
    fail_test "bare invocation printed an environment banner — --env default changed behavior: $out"
fi

start_test "init.sh --env test selects the suffixed path before the TTY guard"
out="$(bash "$INIT_SH" --env test < /dev/null 2>&1)"; rc=$?
if [[ $rc -ne 0 ]] && grep -q "environment: TEST" <<<"$out"; then
    pass_test
else
    fail_test "expected the TEST environment banner, got (rc=$rc): $out"
fi

print_summary
