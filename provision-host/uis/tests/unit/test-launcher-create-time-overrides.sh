#!/bin/bash
# test-launcher-create-time-overrides.sh — an override a warm container cannot
# honour must stop the command, not be discovered afterwards in a diff.
#
# 🔴 `./uis` silently ignored `UIS_IMAGE` when a container was already running.
# `start_container` returns early when the container is up — BEFORE `check_image`
# — so the override went on the floor.
#
# imac spent three runs verifying 1.6.67 with `UIS_IMAGE=…:1.6.67` against a
# container that had been up nine hours on 1.6.65, and was **one message from
# reporting that a working fix did not work** (ops-dev, urb-agents#796).
#
# 🔵 It caught it by diffing the output under both versions and getting
# BYTE-IDENTICAL text: if the override had applied, the two runs MUST differ —
# that is the whole point of the fix being in 1.6.67. Identical output was proof
# the override never took effect, not proof the fix was absent.
#
# ⚠️ The launcher ALREADY documented this shape for TEMPLATE_REPO, fixed in
# 1.6.9, two comments above the line that repeated it for UIS_IMAGE. Writing the
# shape down did not stop the next variable meeting it — which is why this is a
# declared class with an executed check rather than a third comment.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"

if [[ -f "/mnt/urbalurbadisk/uis" ]]; then
    LAUNCHER="/mnt/urbalurbadisk/uis"
else
    LAUNCHER="$(cd "$SCRIPT_DIR/../../../.." && pwd)/uis"
fi

print_test_section "create-time overrides on a warm container"

start_test "the launcher declares which overrides are create-time"
_decl="$(sed -n '/^UIS_CREATE_TIME_ENV=(/,/^)/p' "$LAUNCHER")"
if [[ -n "$_decl" ]] && grep -q 'UIS_IMAGE' <<< "$_decl"; then
    pass_test
else
    fail_test "no UIS_CREATE_TIME_ENV declaring the class"; print_summary; exit $?
fi

start_test "🔴 the check runs BEFORE the warm-container early return"
# ⚠️ Order is the whole defect. A check after the return is never reached.
_sc="$(sed -n '/^start_container() {/,/^}/p' "$LAUNCHER")"
_guard_line=$(grep -n '_refuse_ignored_create_time_override' <<< "$_sc" | head -1 | cut -d: -f1)
_return_line=$(grep -n 'return 0' <<< "$_sc" | head -1 | cut -d: -f1)
if [[ -n "$_guard_line" && -n "$_return_line" && "$_guard_line" -lt "$_return_line" ]]; then
    pass_test
else
    fail_test "guard at line ${_guard_line:-none}, early return at ${_return_line:-none}"
fi

start_test "a refusal exits non-zero rather than continuing"
grep -q '_refuse_ignored_create_time_override || exit 1' <<< "$_sc" && pass_test \
    || fail_test "the command must stop; silence is what made this a near-miss"

# ── execute it ────────────────────────────────────────────────────────────────
log_error() { echo "ERROR: $*" >&2; }
CONTAINER_NAME="uis-provision-host"
docker() {
    case "$*" in
        *Config.Image*) printf '%s\n' "${FAKE_IMAGE:-}" ;;
        *Mounts*)       printf '%s\n' "${FAKE_KUBE:-}" ;;
    esac
}
eval "$(sed -n '/^UIS_CREATE_TIME_ENV=(/,/^)/p' "$LAUNCHER")"
eval "$(sed -n '/^_warm_container_value_for() {/,/^}/p' "$LAUNCHER")"
eval "$(sed -n '/^_refuse_ignored_create_time_override() {/,/^}/p' "$LAUNCHER")"

FAKE_IMAGE="ghcr.io/helpers-no/uis-provision-host:1.6.65"
FAKE_KUBE="/home/someone/.kube"

start_test "no override set — silent, and does not block"
( unset UIS_IMAGE UIS_KUBECONFIG_DIR; _refuse_ignored_create_time_override ) >/dev/null 2>&1 \
    && pass_test || fail_test "a user who asked for nothing must not be nagged"

start_test "an override that AGREES with the running container is silent"
( UIS_IMAGE="ghcr.io/helpers-no/uis-provision-host:1.6.65" _refuse_ignored_create_time_override ) >/dev/null 2>&1 \
    && pass_test || fail_test "a satisfied override is not a problem"

start_test "🔴 imac's case: UIS_IMAGE disagrees — refuses"
( UIS_IMAGE="ghcr.io/helpers-no/uis-provision-host:1.6.67" _refuse_ignored_create_time_override ) >/dev/null 2>&1 \
    && fail_test "the exact case that nearly produced a false finding must not pass" || pass_test

start_test "the refusal names BOTH versions, so the reader can see the disagreement"
_out=$( UIS_IMAGE="ghcr.io/helpers-no/uis-provision-host:1.6.67" _refuse_ignored_create_time_override 2>&1 )
if grep -q '1.6.67' <<< "$_out" && grep -q '1.6.65' <<< "$_out"; then
    pass_test
else
    fail_test "got: $_out"
fi

start_test "the refusal says how to get what was asked for"
grep -qi 'restart\|./uis stop' <<< "$_out" && pass_test \
    || fail_test "a refusal without a remedy is an obstacle"

start_test "🔴 'could not tell' is silent — never reported as a mismatch"
# Same rule as the external-services gate and the digest check: could-not-look
# is not does-not-match.
( FAKE_IMAGE="" UIS_IMAGE="ghcr.io/x:1.6.67" _refuse_ignored_create_time_override ) >/dev/null 2>&1 \
    && pass_test || fail_test "an unreadable container must not be reported as disagreeing"

start_test "UIS_KUBECONFIG_DIR is covered too, not just the variable that was reported"
( UIS_KUBECONFIG_DIR="/somewhere/else" _refuse_ignored_create_time_override ) >/dev/null 2>&1 \
    && fail_test "the second create-time override must be checked as well" || pass_test

start_test "a kubeconfig mounted as the config FILE still matches its directory"
# The launcher resolves a symlinked config and mounts the file, so the recorded
# Source can be "<dir>/config" for what the user set as "<dir>".
( FAKE_KUBE="/home/someone/.kube/config" UIS_KUBECONFIG_DIR="/home/someone/.kube" \
  _refuse_ignored_create_time_override ) >/dev/null 2>&1 \
    && pass_test || fail_test "a file mount must not read as a different directory"

start_test "the runtime class is still separate and still forwarded"
# ⚠️ UIS_FORWARDED_ENV reaches a warm container on every exec; these two cannot.
# Collapsing the two classes would either nag about working overrides or drop
# the check on the ones that matter.
grep -q '^UIS_FORWARDED_ENV=(' "$LAUNCHER" && pass_test \
    || fail_test "the runtime override list has gone"

start_test "no create-time variable is also listed as forwarded"
_fwd="$(sed -n '/^UIS_FORWARDED_ENV=(/,/^)/p' "$LAUNCHER")"
_both=""
for v in "${UIS_CREATE_TIME_ENV[@]}"; do
    grep -qE "^[[:space:]]+$v([[:space:]]|$)" <<< "$_fwd" && _both+="$v "
done
[[ -z "$_both" ]] && pass_test || fail_test "in both classes, which cannot be true: $_both"

print_summary
