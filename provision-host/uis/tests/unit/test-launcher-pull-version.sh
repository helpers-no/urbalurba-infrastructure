#!/bin/bash
# test-launcher-pull-version.sh — `uis pull` must not report a version it did
# not get.
#
# 🔴 THE DEFECT. `:latest` is a moving tag published by the container build,
# and the update notice compares the installed version against `version.txt` on
# main — which main gains the moment a release commit merges, minutes before
# the image exists and permanently if the build fails. So:
#
#   "Update available: 1.6.49 -> 1.6.50   (run: ./uis pull)"
#   $ ./uis pull
#   Image updated successfully
#   Now running version: 1.6.49            <- and the notice returns forever
#
# Raised by Terje. It had already cost a real round: I told another agent to
# wait for 1.6.41's image, and that build never produced one.
#
# ⚠️ The function under test is EXTRACTED FROM THE LAUNCHER AND EXECUTED, not
# grepped for. A structural assertion here would pass against the broken
# version, which printed all the right words.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"

if [[ -f "/mnt/urbalurbadisk/uis" ]]; then
    LAUNCHER="/mnt/urbalurbadisk/uis"
else
    LAUNCHER="$(cd "$SCRIPT_DIR/../../../.." && pwd)/uis"
fi

print_test_section "uis pull: is the version actually published?"

start_test "the launcher is where the test thinks it is"
[[ -f "$LAUNCHER" ]] && pass_test || { fail_test "no launcher at $LAUNCHER"; print_summary; exit $?; }

# Pull the real function out of the real file and run it.
_fn="$(sed -n '/^image_tag_published() {/,/^}/p' "$LAUNCHER")"

start_test "image_tag_published is defined in the launcher"
[[ -n "$_fn" ]] && pass_test || { fail_test "function not found — was it renamed?"; print_summary; exit $?; }

eval "$_fn"

# Stub docker. DOCKER_RC / DOCKER_OUT drive what `docker manifest inspect` does.
docker() {
    if [[ "$1" == "manifest" ]]; then
        [[ -n "${DOCKER_OUT:-}" ]] && echo "$DOCKER_OUT"
        return "${DOCKER_RC:-0}"
    fi
    return 0
}
export -f docker 2>/dev/null || true

start_test "a tag that resolves is 'yes'"
DOCKER_RC=0 DOCKER_OUT='{"schemaVersion":2}'
[[ "$(image_tag_published ghcr.io/x/y 1.6.50)" == "yes" ]] && pass_test || fail_test "got: $(image_tag_published ghcr.io/x/y 1.6.50)"

start_test "🔴 'manifest unknown' is 'no' — the build has not published it"
DOCKER_RC=1 DOCKER_OUT='manifest unknown'
[[ "$(image_tag_published ghcr.io/x/y 1.6.50)" == "no" ]] && pass_test || fail_test "got: $(image_tag_published ghcr.io/x/y 1.6.50)"

start_test "the registry's other spelling of absence is also 'no'"
DOCKER_RC=1 DOCKER_OUT='errors: MANIFEST_UNKNOWN: OCI index not found'
[[ "$(image_tag_published ghcr.io/x/y 1.6.50)" == "no" ]] && pass_test || fail_test "got: $(image_tag_published ghcr.io/x/y 1.6.50)"

start_test "🔴 a network failure is 'unknown', NOT 'no'"
DOCKER_RC=1 DOCKER_OUT='Get "https://ghcr.io/v2/": dial tcp: lookup ghcr.io: no such host'
got="$(image_tag_published ghcr.io/x/y 1.6.50)"
[[ "$got" == "unknown" ]] && pass_test || fail_test "got '$got' — offline must not be reported as 'not built yet'"

start_test "an auth failure is 'unknown', NOT 'no'"
DOCKER_RC=1 DOCKER_OUT='unauthorized: authentication required'
got="$(image_tag_published ghcr.io/x/y 1.6.50)"
[[ "$got" == "unknown" ]] && pass_test || fail_test "got '$got'"

start_test "a docker too old for the subcommand is 'unknown', NOT 'no'"
DOCKER_RC=1 DOCKER_OUT="docker: 'manifest' is not a docker command."
got="$(image_tag_published ghcr.io/x/y 1.6.50)"
[[ "$got" == "unknown" ]] && pass_test || fail_test "got '$got'"

# ============================================================================
print_test_section "uis pull: the caller acts on all three answers"
# ============================================================================

start_test "pull compares what arrived against what main advertises"
grep -q 'after="$(installed_version)"' "$LAUNCHER" \
    && grep -q 'remote="$(fresh_remote_version)"' "$LAUNCHER" \
    && pass_test || fail_test "pull must read back the version it actually got"

start_test "🔴 it uses a FRESH remote version, not the hour-old cache"
# The cache TTL is 3600s and the release being chased is minutes old, so the
# cached answer is precisely the one that would be wrong.
grep -q 'fresh_remote_version()' "$LAUNCHER" && pass_test || fail_test "no uncached lookup exists"

start_test "a mismatch returns non-zero rather than reporting success"
sed -n '/^pull_container() {/,/^}/p' "$LAUNCHER" | grep -q 'return 3' \
    && pass_test || fail_test "pull must not exit 0 when it did not get the version"

start_test "and the caller propagates that instead of leaving it bare under set -e"
grep -q 'pull_container || pull_rc=$?' "$LAUNCHER" && pass_test \
    || fail_test "a meaningful non-zero return left bare under set -e is the file's own documented hazard"

start_test "🔴 --check does not advertise a version that is not published"
# ops measured main moving twice while the image moved zero times, with
# "update available" printed each time (urb-agents#607). The advertised number
# must be checked against the registry before it is offered as an instruction.
_rvs="$(sed -n '/^report_version_status() {/,/^}/p' "$LAUNCHER")"
echo "$_rvs" | grep -q 'image_tag_published "$repo" "$remote"' \
    && echo "$_rvs" | grep -q 'released but NOT PUBLISHED yet' \
    && pass_test || fail_test "--check still offers 'run ./uis pull' for an image that does not exist"

start_test "--check's unreachable-registry branch says so instead of guessing"
echo "$_rvs" | grep -q 'Could not reach the registry to confirm' \
    && pass_test || fail_test "offline must not read as either published or absent"

start_test "the passive notice stays free of registry calls"
# ⚠️ Deliberate asymmetry, and worth pinning: maybe_notify_update fires on every
# command. A registry round-trip there would tax every invocation to improve a
# line the user did not ask for.
_notify="$(sed -n '/^maybe_notify_update() {/,/^}/p' "$LAUNCHER")"
echo "$_notify" | grep -q 'image_tag_published' \
    && fail_test "the every-command path must not call the registry" || pass_test

# ── an accurate "not yet" that a reader cannot act on ─────────────────────────
# 🔴 The not-published message was CORRECT and still cost two round trips.
# imac measured 1.6.58 and 1.6.63 during their build windows, filed the first as
# a blocker, and sat on a registry monitor for the second (#747). Both times the
# message told it the image was absent and nothing told it whether absent meant
# "ninety seconds away" or "the build failed".
#
# ⚠️ A truthful report that does not say what to do next is a report that gets
# escalated. Measured from the last ten successful builds: min 9.7m, median
# 12.2m, max 15.5m.
_rvs_fn="$(sed -n '/^report_version_status() {/,/^}/p' "$LAUNCHER")"
_pull_fn="$(sed -n '/^pull_container() {/,/^}/p' "$LAUNCHER")"

start_test "🔴 --check says how long a build takes, so 'not published' is actionable"
echo "$_rvs_fn" | grep -q 'takes 10-15 minutes' \
    && pass_test || fail_test "the not-published branch gives no expected duration"

start_test "🔴 pull says it too — that is the path someone is actively waiting on"
echo "$_pull_fn" | grep -q 'takes 10-15 minutes' \
    && pass_test || fail_test "the pull path gives no expected duration"

start_test "the message tells the reader to WAIT, not just that something is absent"
echo "$_rvs_fn" | grep -qi 'WAIT' \
    && pass_test || fail_test "no instruction to wait; a bare absence reads as a fault"

start_test "and distinguishes 'still building' from 'the build failed'"
echo "$_rvs_fn" | grep -qi 'probably failed' \
    && pass_test || fail_test "without the distinction the reader cannot choose between waiting and looking"

start_test "the 'unknown' branch does not claim the image is missing"
_branch="$(sed -n '/^pull_container() {/,/^}/p' "$LAUNCHER")"
echo "$_branch" | grep -q 'Could not reach the registry' && pass_test \
    || fail_test "an unreachable registry must read as 'do not know', not 'not built'"

print_summary
