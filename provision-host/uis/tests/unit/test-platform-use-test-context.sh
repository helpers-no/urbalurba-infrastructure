#!/bin/bash
# test-platform-use-test-context.sh — "<platform>-test" secondary contexts
# must get a real repair path, not a flat "Unknown platform" refusal.
#
# proxmox manages TWO kubectl contexts (prod "proxmox", test "proxmox-test")
# from ONE platform directory. `./uis platform use proxmox-test` used to be
# refused outright, because validation only ever checked for a platform
# DIRECTORY named "proxmox-test" (there isn't one — it's a context belonging
# to the "proxmox" directory). The only working repair path, pf_lockstep_flip
# directly or platforms/proxmox/scripts/point-postgresql-at.sh, was invisible
# from `./uis --help`. A kubeconfig rebuilt by hand after a missing
# /root/.kube/config has no way to learn any of this (urb-agents/
# urbalurba-infrastructure#566).
#
# ⚠️ cmd_platform_use's own platform-directory check is hardcoded to
# /mnt/urbalurbadisk, which doesn't exist outside the container (confirmed:
# no existing unit test executes cmd_platform_use end to end, for the same
# reason). pf_context_exists is pure and fully testable — behavioral test
# below. The cmd_platform_use wiring itself is asserted structurally, the
# same pattern test-external-services-gate.sh uses for code this awkward to
# execute directly.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"

if [[ -d "/mnt/urbalurbadisk/provision-host/uis" ]]; then
    UIS_LIB="/mnt/urbalurbadisk/provision-host/uis/lib"
    UIS_CLI_FILE="/mnt/urbalurbadisk/provision-host/uis/manage/uis-cli.sh"
else
    UIS_LIB="$(cd "$SCRIPT_DIR/../../lib" && pwd)"
    UIS_CLI_FILE="$(cd "$SCRIPT_DIR/../../manage" && pwd)/uis-cli.sh"
fi

# ============================================================================
print_test_section "pf_context_exists — real behavior against a fake kubectl"
# ============================================================================

_tmp="$(mktemp -d)"
trap 'rm -rf "$_tmp"' EXIT
export PF_KUBECONFIG="$_tmp/kubeconf-all"
: > "$PF_KUBECONFIG"

# Fake kubectl: "config get-contexts <name>" succeeds only for names in
# KNOWN_CONTEXTS (space-separated), exactly like the real command's exit
# status — this test only depends on that contract, not on YAML shape.
export KNOWN_CONTEXTS="proxmox proxmox-test rancher-desktop"
_FAKE_BIN="$_tmp/bin"
mkdir -p "$_FAKE_BIN"
cat > "$_FAKE_BIN/kubectl" <<'EOF'
#!/bin/bash
if [[ "$1" == "config" && "$2" == "get-contexts" ]]; then
    for c in $KNOWN_CONTEXTS; do
        [[ "$c" == "$3" ]] && exit 0
    done
    exit 1
fi
exit 1
EOF
chmod +x "$_FAKE_BIN/kubectl"

source "$UIS_LIB/platform-switching.sh"

start_test "pf_context_exists is defined after sourcing platform-switching.sh"
declare -F pf_context_exists >/dev/null && pass_test || fail_test "function not found"

start_test "returns 0 for a context the kubeconfig actually has"
PATH="$_FAKE_BIN:$PATH" pf_context_exists "proxmox-test" && pass_test || fail_test "expected success for proxmox-test"

start_test "returns 1 for a context that doesn't exist"
if PATH="$_FAKE_BIN:$PATH" pf_context_exists "proxmox-staging"; then
    fail_test "expected failure for an unknown context"
else
    pass_test
fi

start_test "returns 1 (not an error exit, not a crash) for an empty name"
if PATH="$_FAKE_BIN:$PATH" pf_context_exists ""; then
    fail_test "expected failure for an empty context name"
else
    pass_test
fi

start_test "exported for sub-shell callers, same as the other pf_* helpers"
grep -q "^export -f pf_context_exists$" "$UIS_LIB/platform-switching.sh" && pass_test \
    || fail_test "pf_context_exists missing from the export -f line"

# ============================================================================
print_test_section "cmd_platform_use recognizes '<platform>-test' contexts"
# ============================================================================

start_test "a target matching <base>-test is accepted when <base>/scripts/init.sh exists"
grep -q 'test_base="\${target%-test}"' "$UIS_CLI_FILE" && pass_test \
    || fail_test "the -test suffix is no longer stripped/checked in cmd_platform_use"

start_test "a -test context's state is read from the kubeconfig, not from the base platform's status.sh"
# The base platform's status.sh --summary contract has no notion of a second
# context — routing a -test target through pf_platform_summary would silently
# report on the PROD cluster's state under the test cluster's name.
awk '/if \(\( is_test_context \)\); then/,/elif ! summary=/' "$UIS_CLI_FILE" \
    | grep -q 'pf_context_exists "\$target"' \
    && pass_test || fail_test "is_test_context branch no longer queries pf_context_exists directly"

start_test "a missing -test context's error names the real recovery command"
grep -q "re)provision it with: ./uis platform up \$test_base" "$UIS_CLI_FILE" && pass_test \
    || fail_test "not-initialized hint no longer points at './uis platform up <base>'"

start_test "an unrecognized target (not -test, no init.sh) still gets the original refusal"
grep -q 'Unknown platform .\$target. (no init.sh found' "$UIS_CLI_FILE" && pass_test \
    || fail_test "the original unknown-platform error message is gone"

print_summary
