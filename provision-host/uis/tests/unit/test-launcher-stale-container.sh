#!/bin/bash
# test-launcher-stale-container.sh — `./uis start` must say when the running
# container predates the image on disk.
#
# 🔴 `docker pull` does not touch a running container, and `start_container`
# returns early when one is up. So a pull performed outside the launcher leaves
# the host running the OLD code while `./uis start` exits 0 and says nothing.
# imac hit this upgrading to 1.6.112 and only avoided a false result by removing
# the container first by habit (ops-dev, urb-agents#1186).
#
# ⚠️ The function is EXTRACTED FROM THE LAUNCHER AND EXECUTED against a stubbed
# docker, in the style of test-launcher-busy-guard.sh. A grep would pass against
# a guard that never fires.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"

if [[ -f "/mnt/urbalurbadisk/uis" ]]; then
    LAUNCHER="/mnt/urbalurbadisk/uis"
else
    LAUNCHER="$(cd "$SCRIPT_DIR/../../../.." && pwd)/uis"
fi

print_test_section "Stale container: a pulled image does not replace a running one"

start_test "the launcher defines the guard"
_fn="$(sed -n '/^_warn_if_container_predates_image() {/,/^}/p' "$LAUNCHER")"
[[ -n "$_fn" ]] && pass_test || { fail_test "_warn_if_container_predates_image not found in $LAUNCHER"; print_summary; exit $?; }

source "$SCRIPT_DIR/../../lib/logging.sh" 2>/dev/null || true
log_warn() { echo "WARN: $1"; }
CONTAINER_NAME="uis-provision-host"
IMAGE="ghcr.io/helpers-no/uis-provision-host:latest"
eval "$_fn"

# RUNNING_ID / ONDISK_ID drive the stub. Empty means "docker could not tell".
docker() {
    [[ "$1" == "inspect" ]] || return 0
    case "$*" in
        *'{{.Image}}'*) [[ -n "${RUNNING_ID:-}" ]] && printf '%s\n' "$RUNNING_ID"; return 0 ;;
        *'{{.Id}}'*)    [[ -n "${ONDISK_ID:-}"  ]] && printf '%s\n' "$ONDISK_ID";  return 0 ;;
    esac
    return 0
}

start_test "🔴 it warns when the running container was created from another image"
RUNNING_ID="sha256:aaaa1111" ONDISK_ID="sha256:bbbb2222"
_out="$(_warn_if_container_predates_image 2>&1)"
if grep -q "still executing the OLD code" <<<"$_out"; then pass_test
else fail_test "no warning for a stale container; got: ${_out:-<empty>}"; fi

start_test "🔵 and it names a command that actually applies the image"
if grep -qE '\./uis (restart|pull)' <<<"$_out"; then pass_test
else fail_test "the warning does not name restart/pull; got: ${_out:-<empty>}"; fi

start_test "🔵 and it prints both ids so the operator can check the claim"
if grep -q "aaaa1111" <<<"$_out" && grep -q "bbbb2222" <<<"$_out"; then pass_test
else fail_test "the warning does not show both image ids; got: ${_out:-<empty>}"; fi

start_test "⚠️ it is SILENT when the container is already on the pulled image"
RUNNING_ID="sha256:same0000" ONDISK_ID="sha256:same0000"
_out="$(_warn_if_container_predates_image 2>&1)"
[[ -z "$_out" ]] && pass_test || fail_test "warned on an up-to-date container: $_out"

start_test "⚠️ it is SILENT when there is no local image (a host that never pulled)"
RUNNING_ID="sha256:aaaa1111" ONDISK_ID=""
_out="$(_warn_if_container_predates_image 2>&1)"
[[ -z "$_out" ]] && pass_test || fail_test "warned when the image is absent: $_out"

start_test "⚠️ it is SILENT when the container is not inspectable"
RUNNING_ID="" ONDISK_ID="sha256:bbbb2222"
_out="$(_warn_if_container_predates_image 2>&1)"
[[ -z "$_out" ]] && pass_test || fail_test "warned when the container is absent: $_out"

start_test "🔴 start_container calls the guard BEFORE its early return"
_sc="$(sed -n '/^start_container() {/,/^}/p' "$LAUNCHER")"
_head="$(sed -n '1,/return 0/p' <<<"$_sc")"
if grep -q "_warn_if_container_predates_image" <<<"$_head"; then pass_test
else fail_test "the guard is not reached on the already-running path — which is the only path it exists for"; fi

print_summary
