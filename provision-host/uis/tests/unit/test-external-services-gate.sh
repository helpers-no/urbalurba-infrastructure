#!/bin/bash
# test-external-services-gate.sh — is_external_service must not fail OPEN
#
# The gate decides whether `uis deploy <svc>` renders a transparent proxy or
# the real in-cluster workload. On an installation whose database lives outside
# the cluster and is shared by every other service, getting that wrong replaces
# the proxy with an empty StatefulSet while logging ordinary progress
# (ops, urb-agents#600).
#
# ⚠️ The cases that matter are the ones that are NOT answers: the file exists
# and yq is gone, or the file exists and does not parse. Those must return 2 —
# "cannot tell" — never 1, which means "deploy in-cluster".
#
# ⚠️ And the stock laptop must be untouched: no file, or a comments-only file,
# is a real answer of "not declared" and must stay quiet.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"

if [[ -d "/mnt/urbalurbadisk/provision-host/uis" ]]; then
    UIS_LIB="/mnt/urbalurbadisk/provision-host/uis/lib"
else
    UIS_LIB="$(cd "$SCRIPT_DIR/../../lib" && pwd)"
fi

source "$UIS_LIB/logging.sh"
source "$UIS_LIB/external-services.sh"

if ! command -v yq >/dev/null 2>&1; then
    print_test_section "external-services gate"
    start_test "yq is available"
    skip_test "yq not installed on this host — the gate's own dependency"
    print_summary
    exit $?
fi

_tmp="$(mktemp -d)"
trap 'rm -rf "$_tmp"' EXIT
export EXTEND_DIR="$_tmp"
_F="$_tmp/external-services.yaml"

_gate() { local rc=0; is_external_service "$1" 2>/dev/null || rc=$?; echo "$rc"; }

# ============================================================================
print_test_section "Answers: the two states that really are answers"
# ============================================================================

start_test "no file at all is 'not declared' (1), not an error"
rm -f "$_F"
[[ "$(_gate postgresql)" == "1" ]] && pass_test || fail_test "got $(_gate postgresql)"

start_test "a comments-only file is 'not declared' (1) — the shipped default"
printf '# nothing declared here\n# just guidance\n' > "$_F"
[[ "$(_gate postgresql)" == "1" ]] && pass_test || fail_test "got $(_gate postgresql)"

start_test "a file declaring a DIFFERENT service is 'not declared' for this one"
printf 'minio:\n  host: 192.0.2.20\n  why: "example"\n' > "$_F"
[[ "$(_gate postgresql)" == "1" ]] && pass_test || fail_test "got $(_gate postgresql)"

start_test "a declared service is 'external' (0)"
printf 'postgresql:\n  host: 192.0.2.10\n  port: 5432\n  why: "example"\n' > "$_F"
[[ "$(_gate postgresql)" == "0" ]] && pass_test || fail_test "got $(_gate postgresql)"

start_test "an entry with an empty host is 'not declared', not 'external'"
printf 'postgresql:\n  host: ""\n  why: "example"\n' > "$_F"
[[ "$(_gate postgresql)" == "1" ]] && pass_test || fail_test "got $(_gate postgresql)"

# ============================================================================
print_test_section "🔴 Non-answers must be 2, never 1"
# ============================================================================

start_test "a file that does not parse returns 2 (cannot tell), NOT 1"
printf 'postgresql:\n  host: 192.0.2.10\n   why: broken indentation\n  : : :\n' > "$_F"
got="$(_gate postgresql)"
[[ "$got" == "2" ]] && pass_test || fail_test "got $got — 1 here means 'deploy in-cluster' over a proxy"

start_test "an unparseable file says so on stderr"
err=$(is_external_service postgresql 2>&1 >/dev/null || true)
[[ "$err" == *"does not parse"* ]] && pass_test || fail_test "stderr was: '$err'"

start_test "🔴 file present but yq missing returns 2, NOT 1"
printf 'postgresql:\n  host: 192.0.2.10\n  why: "example"\n' > "$_F"
# Shadow yq with an empty PATH for one call, the way a broken image would.
# ⚠️ "$BASH", not `bash`: a `VAR=x cmd` prefix applies to the lookup of `cmd`
# itself, so `PATH=/nonexistent bash` fails to find bash and the test silently
# measured nothing — it reported an empty string, not a wrong answer.
got=$(PATH=/nonexistent "$BASH" -c "
    source '$UIS_LIB/logging.sh'
    source '$UIS_LIB/external-services.sh'
    EXTEND_DIR='$_tmp'
    rc=0; is_external_service postgresql 2>/dev/null || rc=\$?
    echo \$rc" 2>/dev/null)
[[ "$got" == "2" ]] && pass_test || fail_test "got '$got' — an unreadable topology must not read as in-cluster"

start_test "no file AND no yq is still 'not declared' (1) — the stock laptop"
rm -f "$_F"
got=$(PATH=/nonexistent "$BASH" -c "
    source '$UIS_LIB/logging.sh'
    source '$UIS_LIB/external-services.sh'
    EXTEND_DIR='$_tmp'
    rc=0; is_external_service postgresql 2>/dev/null || rc=\$?
    echo \$rc" 2>/dev/null)
[[ "$got" == "1" ]] && pass_test || fail_test "got '$got' — absence of a file is an answer and must stay quiet"

# ============================================================================
print_test_section "The caller refuses on 'cannot tell'"
# ============================================================================

start_test "service-deployment.sh treats 2 as a refusal, not as in-cluster"
_SD="$UIS_LIB/service-deployment.sh"
grep -q '_ext_state -eq 2' "$_SD" && grep -q 'die_config "Cannot determine whether' "$_SD" \
    && pass_test || fail_test "the deploy path must stop when the topology is unreadable"

start_test "and it still takes the external branch on 0"
grep -q '_ext_state -eq 0' "$_SD" && pass_test || fail_test "external branch no longer reachable"

print_summary
