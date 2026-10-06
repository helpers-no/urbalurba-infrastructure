#!/bin/bash
# test-phase6-secrets.sh - Tests for Phase 6 secrets management
#
# Tests the secrets-management.sh library and init command

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"

# Determine library path (works both in container and on host)
if [[ -d "/mnt/urbalurbadisk/provision-host/uis/lib" ]]; then
    LIB_DIR="/mnt/urbalurbadisk/provision-host/uis/lib"
    UIS_ROOT="/mnt/urbalurbadisk/provision-host/uis"
else
    LIB_DIR="$(cd "$SCRIPT_DIR/../../lib" && pwd)"
    UIS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi

print_test_section "Phase 6: Secrets Management Tests"

# ============================================================
# Test: secrets-management.sh loading
# ============================================================

start_test "secrets-management.sh exists"
assert_file_exists "$LIB_DIR/secrets-management.sh" && pass_test

# Source dependencies first
source "$LIB_DIR/logging.sh" 2>/dev/null
source "$LIB_DIR/utilities.sh" 2>/dev/null
source "$LIB_DIR/first-run.sh" 2>/dev/null

start_test "secrets-management.sh loads without error"
if source "$LIB_DIR/secrets-management.sh" 2>/dev/null; then
    pass_test
else
    fail_test "Failed to source secrets-management.sh"
fi

# ============================================================
# Test: secrets-management.sh functions exist
# ============================================================

for fn in get_user_secrets_dir get_secrets_templates_dir has_user_secrets init_secrets show_secrets_status generate_secrets apply_secrets validate_secrets edit_secrets; do
    start_test "secrets-management.sh defines $fn"
    assert_function_exists "$fn" && pass_test
done

# ============================================================
# Test: Path detection functions
# ============================================================

start_test "get_user_secrets_dir returns a path"
path=$(get_user_secrets_dir)
if [[ -n "$path" ]]; then
    pass_test
else
    fail_test "get_user_secrets_dir returned empty"
fi

start_test "get_secrets_templates_dir returns a path"
path=$(get_secrets_templates_dir)
if [[ -n "$path" ]]; then
    pass_test
else
    fail_test "get_secrets_templates_dir returned empty"
fi

# ============================================================
# Test: First-run.sh auto-detection
# ============================================================

start_test "TEMPLATES_DIR is defined and not empty"
if [[ -n "$TEMPLATES_DIR" ]]; then
    pass_test
else
    fail_test "TEMPLATES_DIR is empty"
fi

start_test "TEMPLATES_DIR exists or is container path"
if [[ -d "$TEMPLATES_DIR" ]] || [[ "$TEMPLATES_DIR" == /mnt/* ]]; then
    pass_test
else
    fail_test "TEMPLATES_DIR does not exist: $TEMPLATES_DIR"
fi

start_test "get_default_secret works with DEFAULT_ADMIN_EMAIL"
value=$(get_default_secret DEFAULT_ADMIN_EMAIL)
if [[ -n "$value" ]]; then
    pass_test
else
    fail_test "get_default_secret returned empty for DEFAULT_ADMIN_EMAIL"
fi

# ============================================================
# Test: CLI commands exist
# ============================================================

MANAGE_DIR="$UIS_ROOT/manage"

start_test "uis-cli.sh can run 'secrets status'"
if bash "$MANAGE_DIR/uis-cli.sh" secrets status >/dev/null 2>&1; then
    pass_test
else
    fail_test
fi

start_test "uis-cli.sh can run 'cluster types'"
if bash "$MANAGE_DIR/uis-cli.sh" cluster types >/dev/null 2>&1; then
    pass_test
else
    fail_test
fi

start_test "uis-cli.sh help shows 'init' command"
if bash "$MANAGE_DIR/uis-cli.sh" help 2>&1 | grep -q 'init'; then
    pass_test
else
    fail_test
fi

start_test "uis-cli.sh help shows 'secrets' command"
if bash "$MANAGE_DIR/uis-cli.sh" help 2>&1 | grep -q 'secrets'; then
    pass_test
else
    fail_test
fi

start_test "uis-cli.sh help shows 'cluster types'"
if bash "$MANAGE_DIR/uis-cli.sh" help 2>&1 | grep -q 'cluster types'; then
    pass_test
else
    fail_test
fi

# ============================================================
# Test: show_secrets_status reports per-environment Cloudflare tunnels
# ============================================================
# One hardcoded two-variable list (CLOUDFLARE_DNS_TOKEN/CLOUDFLARE_TUNNEL_TOKEN)
# was the only status this command ever gave. A 4th named environment should
# be a one-line change in cloudflare-envs.sh, not a new hardcoded string here
# — so this pins the loop exists and iterates the canonical list, not that
# any one environment name is special-cased into the function.

start_test "show_secrets_status reports CLOUDFLARE_TUNNEL_TOKEN_TEST"
output="$(show_secrets_status 2>&1)"
if grep -q 'CLOUDFLARE_TUNNEL_TOKEN_TEST' <<<"$output"; then
    pass_test
else
    fail_test "no per-env TEST row in show_secrets_status output"
fi

start_test "show_secrets_status reports CLOUDFLARE_TUNNEL_TOKEN_PROD"
if grep -q 'CLOUDFLARE_TUNNEL_TOKEN_PROD' <<<"$output"; then
    pass_test
else
    fail_test "no per-env PROD row in show_secrets_status output"
fi

start_test "show_secrets_status's per-env rows come from a loop over UIS_CLOUDFLARE_ENVS, not a hardcoded string"
if grep -q 'UIS_CLOUDFLARE_ENVS\[@\]' "$LIB_DIR/secrets-management.sh"; then
    pass_test
else
    fail_test "a 4th environment would need a new hardcoded line here instead of one in cloudflare-envs.sh"
fi

# ============================================================
# Summary
# ============================================================

print_summary
