#!/bin/bash
# test-configure-expose.sh - Unit tests for uis configure and uis expose
#
# Tests that can run WITHOUT a cluster — validates CLI routing, argument parsing,
# services.json metadata, file existence, and syntax.
#
# For integration tests with a running cluster, see deploy/test-configure-expose-integration.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"

# Determine paths (works both in container and on host)
if [[ -d "/mnt/urbalurbadisk/provision-host/uis" ]]; then
    UIS_CLI="/mnt/urbalurbadisk/provision-host/uis/manage/uis-cli.sh"
    LIB_DIR="/mnt/urbalurbadisk/provision-host/uis/lib"
    DATA_DIR="/mnt/urbalurbadisk/website/src/data"
    PROJECT_ROOT="/mnt/urbalurbadisk"
else
    UIS_CLI="$(cd "$SCRIPT_DIR/../../manage" && pwd)/uis-cli.sh"
    LIB_DIR="$(cd "$SCRIPT_DIR/../../lib" && pwd)"
    # Go up from tests/unit/ to repo root
    PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
    DATA_DIR="$PROJECT_ROOT/website/src/data"
fi

SERVICES_JSON="$DATA_DIR/services.json"

print_test_section "Configure & Expose: File existence and syntax"

# ============================================================
# File existence
# ============================================================

start_test "expose.sh exists"
if [[ -f "$LIB_DIR/expose.sh" ]]; then
    pass_test
else
    fail_test "File not found: $LIB_DIR/expose.sh"
fi

start_test "configure.sh exists"
if [[ -f "$LIB_DIR/configure.sh" ]]; then
    pass_test
else
    fail_test "File not found: $LIB_DIR/configure.sh"
fi

start_test "configure-postgresql.sh exists"
if [[ -f "$LIB_DIR/configure-postgresql.sh" ]]; then
    pass_test
else
    fail_test "File not found: $LIB_DIR/configure-postgresql.sh"
fi

# ============================================================
# Syntax checks
# ============================================================

start_test "expose.sh has valid bash syntax"
if bash -n "$LIB_DIR/expose.sh" 2>/dev/null; then
    pass_test
else
    fail_test "Syntax error in expose.sh"
fi

start_test "configure.sh has valid bash syntax"
if bash -n "$LIB_DIR/configure.sh" 2>/dev/null; then
    pass_test
else
    fail_test "Syntax error in configure.sh"
fi

start_test "configure-postgresql.sh has valid bash syntax"
if bash -n "$LIB_DIR/configure-postgresql.sh" 2>/dev/null; then
    pass_test
else
    fail_test "Syntax error in configure-postgresql.sh"
fi

# ============================================================
# services.json metadata
# ============================================================

print_test_section "Configure & Expose: services.json metadata"

start_test "services.json exists"
if [[ -f "$SERVICES_JSON" ]]; then
    pass_test
else
    fail_test "File not found: $SERVICES_JSON"
fi

# Check configurable field on expected services
# ⚠️ Exactly the two with a handler. mysql, mongodb, redis, elasticsearch,
# qdrant and authentik were listed here and had none — this test asserted the
# false advertisement rather than catching it. Retracted 2026-09-29 on Terje's
# decision (urb-agents#1710); they are checked below as NOT configurable now,
# which is the assertion that would have caught it.
for service in postgresql postgrest; do
    start_test "$service has configurable: true"
    val=$(jq -r --arg id "$service" '.services[] | select(.id == $id) | .configurable' "$SERVICES_JSON" 2>/dev/null)
    if [[ "$val" == "true" ]]; then
        pass_test
    else
        fail_test "Expected configurable=true for $service, got: $val"
    fi
done

# Check non-configurable services don't have configurable: true
for service in grafana prometheus argocd nginx whoami mysql mongodb redis elasticsearch qdrant authentik; do
    start_test "$service is NOT configurable"
    val=$(jq -r --arg id "$service" '.services[] | select(.id == $id) | .configurable // "null"' "$SERVICES_JSON" 2>/dev/null)
    if [[ "$val" != "true" ]]; then
        pass_test
    else
        fail_test "Expected configurable!=true for $service, got: $val"
    fi
done

# Check exposePort field on configurable services
# Using simple loop instead of associative array (bash 3 compatible)
for pair in "postgresql:35432" "mysql:33306" "mongodb:37017" "redis:36379" "elasticsearch:39200" "qdrant:36333" "authentik:39000"; do
    service="${pair%%:*}"
    expected="${pair##*:}"
    start_test "$service has exposePort: $expected"
    val=$(jq -r --arg id "$service" '.services[] | select(.id == $id) | .exposePort' "$SERVICES_JSON" 2>/dev/null)
    if [[ "$val" == "$expected" ]]; then
        pass_test
    else
        fail_test "Expected exposePort=$expected for $service, got: $val"
    fi
done

# Check no port conflicts
start_test "No duplicate exposePort values"
dupes=$(jq -r '[.services[] | select(.exposePort) | .exposePort] | group_by(.) | map(select(length > 1)) | length' "$SERVICES_JSON" 2>/dev/null)
if [[ "$dupes" == "0" ]]; then
    pass_test
else
    fail_test "Found duplicate exposePort values"
fi

# ============================================================
# CLI routing (requires bash 4+ for associative arrays in expose.sh)
# ============================================================

print_test_section "Configure & Expose: CLI routing"

BASH_MAJOR="${BASH_VERSINFO[0]}"
if [[ "$BASH_MAJOR" -ge 4 ]]; then

    start_test "uis configure (no args) prints usage to stderr"
    output=$("$UIS_CLI" configure 2>&1 || true)
    if echo "$output" | grep -q "Usage:"; then
        pass_test
    else
        fail_test "Expected usage message, got: $output"
    fi

    start_test "uis expose (no args) prints usage to stderr"
    output=$("$UIS_CLI" expose 2>&1 || true)
    if echo "$output" | grep -q "Usage:"; then
        pass_test
    else
        fail_test "Expected usage message, got: $output"
    fi

    start_test "uis expose --status runs without error"
    output=$("$UIS_CLI" expose --status 2>&1 || true)
    if echo "$output" | grep -q "Exposed services:"; then
        pass_test
    else
        fail_test "Expected status output, got: $output"
    fi

    start_test "uis help includes configure command"
    output=$("$UIS_CLI" help 2>&1 || true)
    if echo "$output" | grep -q "configure"; then
        pass_test
    else
        fail_test "configure not found in help output"
    fi

    start_test "uis help includes expose command"
    output=$("$UIS_CLI" help 2>&1 || true)
    if echo "$output" | grep -q "expose"; then
        pass_test
    else
        fail_test "expose not found in help output"
    fi

else
    echo "  (Skipping CLI routing tests — bash $BASH_MAJOR does not support associative arrays)"
    echo "  (These tests pass inside the container which has bash 5+)"
fi

# ============================================================
# Dockerfile symlink
# ============================================================

print_test_section "Configure & Expose: Dockerfile"

DOCKERFILE=""
if [[ -f "/mnt/urbalurbadisk/../Dockerfile.uis-provision-host" ]]; then
    DOCKERFILE="/mnt/urbalurbadisk/../Dockerfile.uis-provision-host"
elif [[ -f "$(cd "$SCRIPT_DIR/../../../.." && pwd)/Dockerfile.uis-provision-host" ]]; then
    DOCKERFILE="$(cd "$SCRIPT_DIR/../../../.." && pwd)/Dockerfile.uis-provision-host"
fi

if [[ -n "$DOCKERFILE" ]]; then
    start_test "Dockerfile creates /usr/local/bin/uis wrapper"
    if grep -q '/usr/local/bin/uis' "$DOCKERFILE"; then
        pass_test
    else
        fail_test "uis wrapper not found in Dockerfile"
    fi
else
    # Inside the container — check the wrapper directly
    start_test "/usr/local/bin/uis wrapper exists"
    if [[ -x "/usr/local/bin/uis" ]]; then
        pass_test
    else
        fail_test "/usr/local/bin/uis not found or not executable"
    fi
fi

# ============================================================
# Documentation
# ============================================================

print_test_section "Configure & Expose: Documentation"

DOC_FILE=""
if [[ -f "/mnt/urbalurbadisk/website/docs/developing/init-file-formats.md" ]]; then
    DOC_FILE="/mnt/urbalurbadisk/website/docs/developing/init-file-formats.md"
elif [[ -f "$PROJECT_ROOT/website/docs/developing/init-file-formats.md" ]]; then
    DOC_FILE="$PROJECT_ROOT/website/docs/developing/init-file-formats.md"
fi

if [[ -n "$DOC_FILE" ]]; then
    start_test "init-file-formats.md exists"
    pass_test

    start_test "init-file-formats.md covers PostgreSQL"
    if grep -q "PostgreSQL" "$DOC_FILE"; then
        pass_test
    else
        fail_test "PostgreSQL section not found"
    fi

    start_test "init-file-formats.md covers Authentik"
    if grep -q "Authentik" "$DOC_FILE"; then
        pass_test
    else
        fail_test "Authentik section not found"
    fi
else
    echo "  (Skipping documentation tests — docs not available in container)"
fi

# ============================================================
# Summary
# ============================================================

print_summary
