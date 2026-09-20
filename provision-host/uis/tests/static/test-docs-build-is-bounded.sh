#!/bin/bash
# test-docs-build-is-bounded.sh — the docs build keeps its heap bound.
#
# urb-agents#1295/#1299. A docs build held 2.4 GB in a 4 GB cap for 3 h 40 m and
# wedged the container: throttled 34.6 million times, never OOM-killed, 63% of
# wall time with nothing runnable. The cap was the bug and is now 5120 MiB.
#
# 🔵 The bound is the backstop, in ops-dev's framing: "the cap makes the build
# possible; the bound makes its failure honest." Without it the next build that
# is larger than the one measured stalls silently again instead of failing in
# five seconds with a legible message.
#
# ⚠️ It is a HEAP bound, not an RSS bound. Removing it is a decision; drifting
# out of it by editing the script is not, which is what this asserts.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"

if [[ -d "/mnt/urbalurbadisk/website" ]]; then
    REPO="/mnt/urbalurbadisk"
else
    REPO="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
fi
PKG="$REPO/website/package.json"

print_test_section "the docs build is bounded"

start_test "website/package.json exists and parses"
if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$PKG" 2>/dev/null; then
    pass_test
else
    fail_test "package.json missing or not valid JSON"
fi

start_test "the build script carries a heap bound"
_b=$(python3 -c "
import json,sys
print(json.load(open(sys.argv[1]))['scripts'].get('build',''))" "$PKG" 2>/dev/null)
if [[ "$_b" == *--max-old-space-size=* ]]; then
    pass_test
else
    fail_test "build script has no bound — a runaway build stalls silently again: '$_b'"
fi

start_test "the bound is above the measured peak, not a guess below it"
# Healthy peaks measured at 2356 and 2581 MiB RSS; the heap inside that is
# smaller. A bound at or under ~2600 would risk tripping on a healthy build,
# which is worse than no bound because the roster requires this build to run.
_n=$(printf '%s' "$_b" | sed -n 's/.*--max-old-space-size=\([0-9]\+\).*/\1/p')
if [[ -n "$_n" && "$_n" -ge 3000 ]]; then
    pass_test
else
    fail_test "bound is ${_n:-unset} MiB — at or below the measured RSS peak, so it can fire on a healthy build"
fi

start_test "and it is still a bound, not an unlimited number"
# A bound set absurdly high is the same as no bound, and reads as one.
if [[ -n "$_n" && "$_n" -le 4096 ]]; then
    pass_test
else
    fail_test "bound is ${_n:-unset} MiB — high enough that total RSS could reach the container cap first"
fi

print_summary
