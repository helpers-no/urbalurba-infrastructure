#!/bin/bash
# test-launcher-busy-guard.sh — pull/stop/restart must not interrupt a command
# running inside the container.
#
# 🔴 `uis template install` is minutes long and runs INSIDE the container that
# `pull`, `stop` and `restart` all stop. Interrupting it leaves a half-built
# application — a database with a partial schema, or a code location written to
# .uis.extend that Dagster never loaded — and no UIS command repairs that.
#
# Reported by atlas from a production install (urb-agents#629): ops was asked to
# pull mid-install and held it only by reasoning it out themselves. Nothing
# warned.
#
# ⚠️ The functions are EXTRACTED FROM THE LAUNCHER AND EXECUTED against a
# stubbed docker. A grep would pass against a guard that never fires.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"

if [[ -f "/mnt/urbalurbadisk/uis" ]]; then
    LAUNCHER="/mnt/urbalurbadisk/uis"
else
    LAUNCHER="$(cd "$SCRIPT_DIR/../../../.." && pwd)/uis"
fi

print_test_section "Busy guard: is something running in the container?"

start_test "the launcher defines the guard"
_fns="$(sed -n '/^container_busy_with() {/,/^}/p' "$LAUNCHER")
$(sed -n '/^refuse_if_busy() {/,/^}/p' "$LAUNCHER")"
[[ -n "$_fns" ]] && pass_test || { fail_test "guard functions not found in $LAUNCHER"; print_summary; exit $?; }

source "$SCRIPT_DIR/../../lib/logging.sh" 2>/dev/null || true
CONTAINER_NAME="uis-provision-host"
eval "$_fns"

# CONTAINER_UP=yes|no ; TOP_OUT = what `docker top` prints
docker() {
    case "$1" in
        ps)  [[ "${CONTAINER_UP:-yes}" == "yes" ]] && echo "$CONTAINER_NAME"; return 0 ;;
        top) [[ -n "${TOP_OUT:-}" ]] && printf '%s\n' "$TOP_OUT"; return 0 ;;
    esac
    return 0
}

start_test "an idle container is not busy"
CONTAINER_UP=yes
TOP_OUT='/bin/bash
sleep infinity'
[[ -z "$(container_busy_with)" ]] && pass_test || fail_test "got: $(container_busy_with)"

start_test "🔴 a running template install IS busy"
TOP_OUT='/bin/bash /mnt/urbalurbadisk/provision-host/uis/manage/uis-cli.sh template install atlas'
[[ -n "$(container_busy_with)" ]] && pass_test || fail_test "an install in flight must be detected"

start_test "a running ansible-playbook IS busy"
TOP_OUT='/usr/bin/python3 /usr/local/bin/ansible-playbook playbooks/360-setup-dagster.yml'
[[ -n "$(container_busy_with)" ]] && pass_test || fail_test "a playbook in flight must be detected"

start_test "a stopped container is not busy — there is nothing to interrupt"
CONTAINER_UP=no
TOP_OUT='/bin/bash /mnt/urbalurbadisk/provision-host/uis/manage/uis-cli.sh template install atlas'
[[ -z "$(container_busy_with)" ]] && pass_test || fail_test "a stopped container cannot be running anything"

# ============================================================================
print_test_section "Busy guard: what the caller does about it"
# ============================================================================

CONTAINER_UP=yes

start_test "refuse_if_busy allows the action when nothing is running"
TOP_OUT='sleep infinity'
( refuse_if_busy pull >/dev/null 2>&1 ) && pass_test || fail_test "an idle container must not block a pull"

start_test "🔴 refuse_if_busy REFUSES when an install is running"
TOP_OUT='/bin/bash /mnt/urbalurbadisk/provision-host/uis/manage/uis-cli.sh template install atlas'
( refuse_if_busy pull >/dev/null 2>&1 ) && fail_test "must refuse" || pass_test

start_test "the refusal names what is running, so it is not a guess"
out="$( refuse_if_busy pull 2>&1 >/dev/null || true )"
[[ "$out" == *"template install atlas"* ]] && pass_test || fail_test "got: $out"

start_test "the refusal says why, not just no"
[[ "$out" == *"half-built"* ]] && pass_test || fail_test "an operator told only 'no' will use --force"

start_test "the refusal names the override"
[[ "$out" == *"UIS_FORCE=1"* ]] && pass_test || fail_test "a guard with no documented override gets worked around badly"

start_test "UIS_FORCE=1 proceeds, and says it is doing so"
out="$( UIS_FORCE=1 refuse_if_busy pull 2>&1 >/dev/null || echo REFUSED )"
[[ "$out" != *REFUSED* && "$out" == *"UIS_FORCE is set"* ]] && pass_test || fail_test "got: $out"

# ============================================================================
print_test_section "Busy guard: every path that stops the container"
# ============================================================================

for verb in pull stop restart; do
    start_test "'$verb' consults the guard before stopping the container"
    grep -q "refuse_if_busy $verb || exit 1" "$LAUNCHER" && pass_test \
        || fail_test "'$verb' stops the container and must check first"
done

start_test "the check uses docker top, not docker exec"
# ⚠️ exec starts a process in the very container being asked about, so on a
# stopped or unhealthy one it hangs or fails — least reliable exactly when it
# matters most.
_cbw="$(sed -n '/^container_busy_with() {/,/^}/p' "$LAUNCHER")"
echo "$_cbw" | grep -q 'docker top' && ! echo "$_cbw" | grep -q 'docker exec' \
    && pass_test || fail_test "the busy check must not depend on exec'ing into the container"

print_summary
