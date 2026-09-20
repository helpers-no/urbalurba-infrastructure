#!/bin/bash
# test-deploy-change-verdict.sh — all three branches of what a deploy did.
#
# urb-agents#1278: on a live cluster only the "unchanged" branch was ever
# exercised. The tester could not make `uis deploy dagster` roll something
# without manufacturing a config change, and would not invent one on a live host
# to exercise a message — the right call, and the reason the decision was
# extracted into a function that can be tested here instead.
#
# 🔵 This is a real test of the shipped code path, not a copy of it: it sources
# the library and calls the same function deploy_single_service calls.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(dirname "$SCRIPT_DIR")"
source "$TESTS_DIR/lib/test-framework.sh"

UIS_DIR="$(dirname "$TESTS_DIR")"
# The library sources siblings; give it what it needs and nothing else.
# shellcheck disable=SC1090
source "$UIS_DIR/lib/logging.sh" 2>/dev/null || true
source "$UIS_DIR/lib/paths.sh"   2>/dev/null || true

# Pull in only the function under test, so no other side effect of the library
# can make this pass or fail for an unrelated reason.
eval "$(sed -n '/^_deploy_change_verdict()/,/^}/p' "$UIS_DIR/lib/service-deployment.sh")"

print_test_section "what a deploy actually did — all three branches"

start_test "the function under test was actually loaded"
# Without this, every assertion below would compare "" to "" and pass.
if declare -f _deploy_change_verdict >/dev/null; then
    pass_test
else
    fail_test "_deploy_change_verdict is not defined — the extraction failed and the cases below are vacuous"
fi

_A=$'dagster-webserver-a 2026-09-17T07:22:44Z\ndagster-daemon-b 2026-09-17T07:22:47Z'
_B=$'dagster-webserver-c 2026-09-20T02:50:37Z\ndagster-daemon-d 2026-09-20T02:50:41Z'

start_test "unchanged pods -> unchanged   (the #1271 case, and the only one seen live)"
[[ "$(_deploy_change_verdict "$_A" "$_A")" == "unchanged" ]] && pass_test || fail_test "got $(_deploy_change_verdict "$_A" "$_A")"

start_test "new pod names and times -> rolled   (NOT exercised on a cluster)"
[[ "$(_deploy_change_verdict "$_A" "$_B")" == "rolled" ]] && pass_test || fail_test "got $(_deploy_change_verdict "$_A" "$_B")"

start_test "same name, new start time -> rolled   (restart in place)"
# A pod restarted in place keeps its name. Names alone would call this
# "unchanged" — the same defect, inverted.
_r1=$'x 2026-09-17T07:22:44Z'
_r2=$'x 2026-09-20T09:00:00Z'
[[ "$(_deploy_change_verdict "$_r1" "$_r2")" == "rolled" ]] && pass_test || fail_test "got $(_deploy_change_verdict "$_r1" "$_r2")"

start_test "no namespace to compare -> unknown   (NOT exercised on a cluster)"
[[ "$(_deploy_change_verdict "" "")" == "unknown" ]] && pass_test || fail_test "got $(_deploy_change_verdict "" "")"

start_test "readable before, unreadable after -> unknown, not 'rolled'"
# kubectl failing after the deploy must not be reported as a successful roll.
[[ "$(_deploy_change_verdict "$_A" "")" == "unknown" ]] && pass_test || fail_test "got $(_deploy_change_verdict "$_A" "")"

start_test "unreadable before, readable after -> unknown, not 'rolled'"
[[ "$(_deploy_change_verdict "" "$_B")" == "unknown" ]] && pass_test || fail_test "got $(_deploy_change_verdict "" "$_B")"

start_test "pod ORDER does not decide the verdict"
# The fingerprint is sorted at the source; if that ever stops, two identical
# clusters would read as rolled on every deploy.
_o1=$'a 2026-09-20T01:00:00Z\nb 2026-09-20T01:00:01Z'
_o2=$'a 2026-09-20T01:00:00Z\nb 2026-09-20T01:00:01Z'
[[ "$(_deploy_change_verdict "$_o1" "$_o2")" == "unchanged" ]] && pass_test || fail_test "identical input read as changed"

print_summary
