#!/bin/bash
# test-cloudflare-multi-env.sh — one installation, more than one Cloudflare Tunnel.
#
# WHY THIS EXISTS. CLOUDFLARE_TUNNEL_TOKEN was a single slot: one token, one
# .uis.secrets/service-keys/cloudflare.env file, one hardcoded cloudflare-tunnel
# Deployment. An installation managing two clusters from the same
# provision-host container (switching CLUSTER_TYPE) had nowhere to put a
# second token — handing over a second one just overwrote the first.
#
# --env <name> adds named environments (DEV/TEST/PROD) without touching the
# bare, single-tunnel behavior every existing installation (including the
# one that predates this change) depends on. These tests pin the two halves
# of that promise:
# a given --env is validated against the same canonical list everywhere, and
# every script/playbook computes its names/keys from cf_env rather than
# hardcoding them — so omitting --env is provably unchanged, not just assumed
# unchanged.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"

if [[ -d "/mnt/urbalurbadisk/networking/cloudflare/scripts" ]]; then
    CF_SCRIPTS="/mnt/urbalurbadisk/networking/cloudflare/scripts"
    PLAYBOOKS="/mnt/urbalurbadisk/ansible/playbooks"
    LIB_DIR="/mnt/urbalurbadisk/provision-host/uis/lib"
else
    CF_SCRIPTS="$(cd "$SCRIPT_DIR/../../../../networking/cloudflare/scripts" && pwd)"
    PLAYBOOKS="$(cd "$SCRIPT_DIR/../../../../ansible/playbooks" && pwd)"
    LIB_DIR="$(cd "$SCRIPT_DIR/../../lib" && pwd)"
fi

ENVS_SH="$LIB_DIR/cloudflare-envs.sh"
INIT_SH="$CF_SCRIPTS/init.sh"
UP_SH="$CF_SCRIPTS/up.sh"
DOWN_SH="$CF_SCRIPTS/down.sh"
VERIFY_SH="$CF_SCRIPTS/verify.sh"
STATUS_SH="$CF_SCRIPTS/status.sh"
DEPLOY_PB="$PLAYBOOKS/820-deploy-network-cloudflare-tunnel.yml"
REMOVE_PB="$PLAYBOOKS/821-remove-network-cloudflare-tunnel.yml"
VERIFY_PB="$PLAYBOOKS/822-verify-cloudflare.yml"

print_test_section "Cloudflare multi-env Tests"

# ---------------------------------------------------------------------------
# cloudflare-envs.sh: the one place the canonical list is defined.
# ---------------------------------------------------------------------------
start_test "cloudflare-envs.sh exists"
if [[ -f "$ENVS_SH" ]]; then
    pass_test
else
    fail_test "missing at $ENVS_SH"
fi

start_test "cloudflare-envs.sh defines UIS_CLOUDFLARE_ENVS containing DEV, TEST, PROD"
# shellcheck source=/dev/null
source "$ENVS_SH"
if [[ " ${UIS_CLOUDFLARE_ENVS[*]} " == *" DEV "* ]] \
   && [[ " ${UIS_CLOUDFLARE_ENVS[*]} " == *" TEST "* ]] \
   && [[ " ${UIS_CLOUDFLARE_ENVS[*]} " == *" PROD "* ]]; then
    pass_test
else
    fail_test "UIS_CLOUDFLARE_ENVS is [${UIS_CLOUDFLARE_ENVS[*]:-unset}], expected DEV TEST PROD"
fi

start_test "_cf_env_is_valid rejects a name outside the canonical list"
if ! _cf_env_is_valid "BOGUS"; then
    pass_test
else
    fail_test "_cf_env_is_valid accepted an unknown name"
fi

start_test "_cf_name_suffix of empty is empty (the bare/backward-compat case)"
if [[ "$(_cf_name_suffix "")" == "" ]]; then
    pass_test
else
    fail_test "expected no suffix for an empty env, got: $(_cf_name_suffix "")"
fi

start_test "_cf_name_suffix lowercases the env for the suffix"
if [[ "$(_cf_name_suffix "TEST")" == "-test" ]]; then
    pass_test
else
    fail_test "expected -test, got: $(_cf_name_suffix "TEST")"
fi

# ---------------------------------------------------------------------------
# Every cloudflare script rejects an unknown --env, before any TTY/cluster
# interaction, and sources the ONE canonical list rather than its own copy.
# ---------------------------------------------------------------------------
for script_name in init.sh up.sh down.sh verify.sh status.sh; do
    script_path="$CF_SCRIPTS/$script_name"

    start_test "$script_name sources cloudflare-envs.sh (one canonical list, not its own copy)"
    if grep -q 'cloudflare-envs.sh' "$script_path"; then
        pass_test
    else
        fail_test "$script_name does not source the canonical env list"
    fi

    start_test "$script_name rejects an unknown --env"
    out="$(bash "$script_path" --env not-a-real-env < /dev/null 2>&1)"; rc=$?
    if [[ $rc -ne 0 ]] && grep -qi "Unknown --env" <<<"$out"; then
        pass_test
    else
        fail_test "$script_name did not cleanly reject --env not-a-real-env (rc=$rc): $out"
    fi
done

# ---------------------------------------------------------------------------
# -e cf_env=... must be appended ONLY when --env was actually given. Always
# passing it, even empty, would hand Ansible a DEFINED-BUT-EMPTY cf_env —
# subtly different from undefined, and not the same code path the bare
# installations have always run.
# ---------------------------------------------------------------------------
start_test "up.sh passes -e cf_env only when --env is given"
if grep -q 'cf_env=\$CF_ENV' "$UP_SH" && grep -qE '\[\[ -n "\$CF_ENV" \]\]' "$UP_SH"; then
    pass_test
else
    fail_test "up.sh does not conditionally gate -e cf_env on CF_ENV being set"
fi

start_test "down.sh passes -e cf_env only when --env is given"
if grep -q 'cf_env=\$CF_ENV' "$DOWN_SH" && grep -qE '\[\[ -n "\$CF_ENV" \]\]' "$DOWN_SH"; then
    pass_test
else
    fail_test "down.sh does not conditionally gate -e cf_env on CF_ENV being set"
fi

start_test "verify.sh passes -e cf_env only when --env is given"
if grep -q 'cf_env=\$CF_ENV' "$VERIFY_SH" && grep -qE '\[\[ -n "\$CF_ENV" \]\]' "$VERIFY_SH"; then
    pass_test
else
    fail_test "verify.sh does not conditionally gate -e cf_env on CF_ENV being set"
fi

# ---------------------------------------------------------------------------
# 820/821/822 compute their names/keys from cf_env rather than hardcoding the
# literal strings in the task bodies — the mechanism that makes a bare run
# collapse to today's exact names and a named run collapse to suffixed ones.
# ---------------------------------------------------------------------------
for pb_name in "820-deploy|$DEPLOY_PB" "821-remove|$REMOVE_PB" "822-verify|$VERIFY_PB"; do
    label="${pb_name%%|*}"
    path="${pb_name##*|}"

    start_test "$label validates cf_env against the canonical list"
    if grep -q "Supported: DEV TEST PROD" "$path"; then
        pass_test
    else
        fail_test "$label does not validate cf_env — an unknown name would silently fall through"
    fi

    start_test "$label computes cf_deployment_name/cf_pod_label from cf_env, not a literal"
    if grep -qE 'cf_(deployment_name|pod_label): "cloudflare' "$path" \
       && ! grep -qE "name: cloudflare-tunnel$" "$path" \
       && ! grep -qE "app=cloudflared$" "$path"; then
        pass_test
    else
        fail_test "$label still has a hardcoded cloudflare-tunnel/cloudflared literal in a task body"
    fi
done

print_summary
