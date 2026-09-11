#!/bin/bash
# test-metadata.sh - Validate service metadata
#
# Tests that all service scripts have required metadata fields.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"

# Determine services directory (works both in container and on host)
if [[ -d "/mnt/urbalurbadisk/provision-host/uis/services" ]]; then
    SERVICES_DIR="/mnt/urbalurbadisk/provision-host/uis/services"
else
    SERVICES_DIR="$(cd "$SCRIPT_DIR/../../services" && pwd)"
fi

print_test_section "Phase 2: Metadata Validation Tests"
echo "Services directory: $SERVICES_DIR"

REQUIRED_FIELDS=(SCRIPT_ID SCRIPT_NAME SCRIPT_DESCRIPTION SCRIPT_CATEGORY)

# Count services
service_count=0
for script in "$SERVICES_DIR"/*/*.sh; do
    [[ -f "$script" ]] && ((service_count++))
done

echo "Found $service_count service scripts"
echo ""

for script in "$SERVICES_DIR"/*/*.sh; do
    [[ -f "$script" ]] || continue
    script_basename=$(basename "$script")

    # Clear previous values
    unset SCRIPT_ID SCRIPT_NAME SCRIPT_DESCRIPTION SCRIPT_CATEGORY

    # Source script to get metadata
    source "$script" 2>/dev/null

    for field in "${REQUIRED_FIELDS[@]}"; do
        start_test "$script_basename has $field"
        # Use indirect reference to get field value
        eval "value=\${$field}"
        if [[ -n "$value" ]]; then
            pass_test
        else
            fail_test "$field is empty or not defined"
        fi
    done
done

# ============================================================================
# 🔴 `helm repo add` MUST BE IDEMPOTENT, OR THE IMAGE BUILD BREAKS
#
# `helm repo add <name>` EXITS 1 when the name already exists:
#
#     Error: repository name (minio) already exists, please specify a different name
#     ERROR: failed to build: ... exit code: 1
#
# That was the whole of the 1.6.55 container build failure. 1.6.55 was released
# and never published, ops sat two versions behind it, and every fix merged
# afterwards was stranded on `main` — and NOTHING reported the failed build. It
# surfaced only because `uis version` said "released but NOT PUBLISHED yet" and
# somebody read it.
#
# ⚠️ Shipping paths only. A bare `helm repo add` in a doc example or a plan is
# prose, not a build step.
# ============================================================================
print_test_section "helm repo add is idempotent on every shipping path"

_repo_root="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

start_test "🔴 no shipping script runs a bare 'helm repo add'"
# ⚠️ Comment lines are stripped, and this file excluded. The first version
# flagged its own positive-control fixture AND a comment in the script it was
# written for — a check that cannot tell what the code DOES from what the code
# SAYS ABOUT ITSELF, which is the same false positive I hit on `chat_id: 0`
# earlier today.
_bare="$(grep -rn --include='*.sh' --include='*.yml' --include='*.yaml' \
            -E 'helm repo add ' "$_repo_root/provision-host" "$_repo_root/ansible" 2>/dev/null \
         | grep -v -- '--force-update' \
         | grep -v '/tests/static/test-metadata.sh:' \
         | grep -vE ':[0-9]+: *#' || true)"
if [[ -z "$_bare" ]]; then
    pass_test
else
    fail_test "a second add of the same name exits 1 and fails the build:"$'\n'"$_bare"
fi

# 🔴 POSITIVE CONTROL. An empty grep proves nothing about the grep.
_ctl="$(mktemp -d)"; mkdir -p "$_ctl/provision-host" "$_ctl/ansible"

start_test "positive control: a bare add IS caught"
printf 'helm repo add minio https://charts.min.io/\n' > "$_ctl/provision-host/x.sh"
_h="$(grep -rn --include='*.sh' -E '(^|[^#])helm repo add ' "$_ctl/provision-host" 2>/dev/null | grep -v -- '--force-update' || true)"
[[ -n "$_h" ]] && pass_test || fail_test "the pattern does not match its own target"

start_test "negative control: --force-update is NOT caught"
printf 'helm repo add --force-update minio https://charts.min.io/\n' > "$_ctl/provision-host/x.sh"
_h="$(grep -rn --include='*.sh' -E '(^|[^#])helm repo add ' "$_ctl/provision-host" 2>/dev/null | grep -v -- '--force-update' || true)"
[[ -z "$_h" ]] && pass_test || fail_test "the idempotent form must not be flagged"
rm -rf "$_ctl"
print_summary
