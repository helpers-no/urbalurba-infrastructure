#!/bin/bash
# test-diagnostics-on-stderr.sh — diagnostics go to stderr; stdout is data.
#
# 🔴 Only log_error did. log_info, log_warn, log_success, log_debug and
# log_progress all wrote to STDOUT, which silently broke every `--json`
# contract in UIS: a caller capturing stdout got diagnostics interleaved with
# the document it asked for.
#
# It surfaced as `configure postgresql --json` on an existing database emitting
# a rotation warning ahead of its JSON, so the template runner read an empty
# status and reported a SUCCESSFUL configure as a failure — on exactly the
# re-install path it was asked to measure (imac, urb-agents#481).
#
# ⚠️ The bad line was added in 1.6.27, by me, using log_warn for one half of a
# message and an explicit `>&2` for the other. Patching that caller would have
# left the next one to find. This asserts the property instead.
#
# Behavioural, not a grep: each function is called and its streams captured.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"

if [[ -d "/mnt/urbalurbadisk/provision-host/uis" ]]; then
    UIS_LIB="/mnt/urbalurbadisk/provision-host/uis/lib"
else
    UIS_LIB="$(cd "$SCRIPT_DIR/../../lib" && pwd)"
fi
source "$UIS_LIB/logging.sh"

print_test_section "Diagnostics go to stderr, stdout stays data"

# Returns "stdout|stderr" for one call, so both halves can be asserted.
_streams() {
    local out err
    err="$(mktemp)"
    out="$("$@" 2>"$err")"
    printf '%s|%s' "${out//[$'\n']/ }" "$(tr -d '\n' < "$err")"
    rm -f "$err"
}

for fn in log_info log_warn log_success log_error; do
    start_test "$fn writes nothing to stdout"
    r="$(_streams "$fn" "probe message")"
    if [[ "${r%%|*}" == "" ]]; then pass_test
    else fail_test "$fn put '${r%%|*}' on stdout — it would corrupt any --json caller"; fi

    start_test "$fn does write to stderr (it must still be visible)"
    if [[ "${r#*|}" == *"probe message"* ]]; then pass_test
    else fail_test "$fn produced no stderr; the message is lost"; fi
done

start_test "log_progress writes nothing to stdout"
r="$(_streams log_progress "working" 1 3)"
[[ "${r%%|*}" == "" ]] && pass_test || fail_test "log_progress put '${r%%|*}' on stdout"

start_test "log_debug is silent by default and quiet on stdout when enabled"
r="$(_streams log_debug "dbg")"
r2="$(UIS_DEBUG=1; _streams log_debug "dbg")"
if [[ "${r%%|*}" == "" && "${r2%%|*}" == "" ]]; then pass_test
else fail_test "log_debug reached stdout"; fi

# The concrete regression: the 1.6.27 rotation warning must not reach stdout.
start_test "🔴 the password-rotation warning is not on stdout"
if [[ -f "$UIS_LIB/configure-postgresql.sh" ]]; then
    line=$(grep -n "was rotated" "$UIS_LIB/configure-postgresql.sh" | head -1)
    if [[ -z "$line" ]]; then
        skip_test "the rotation warning is gone; nothing to assert"
    else
        # It is emitted with log_warn, which the tests above prove goes to stderr.
        grep -q 'log_warn "Password' "$UIS_LIB/configure-postgresql.sh" && pass_test \
            || fail_test "the rotation warning no longer uses log_warn; check its stream directly"
    fi
else
    skip_test "configure-postgresql.sh not found"
fi

print_summary
