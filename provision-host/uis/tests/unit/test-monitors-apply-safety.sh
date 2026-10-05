#!/bin/bash
# test-monitors-apply-safety.sh — `uis monitors apply` must not let a bad
# discovery run wipe Uptime Kuma, and `check` must not call a retargeted
# monitor healthy just because its name did not change.
#
# AUTOKUMA__ON_DELETE=delete (manifests/230-uptime-kuma-autokuma.yaml) means
# every monitor name missing from the applied Secret gets DELETED, not
# skipped. A real instance of this exact mechanism lost every monitor in one
# run because nothing refused a truncated set, and separately reported a
# retargeted host as healthy because name-only comparison cannot see where a
# monitor points. Both are fixed here; this guards the fix rather than the
# description of it.
#
# ⚠️ IMPORTS THE REAL MODULE. A grep for "SHRINK_REFUSE_BELOW" would pass
# against a constant that nothing reads.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"

if [[ -f "/mnt/urbalurbadisk/provision-host/uis/lib/monitors.py" ]]; then
    MONITORS_PY="/mnt/urbalurbadisk/provision-host/uis/lib/monitors.py"
else
    MONITORS_PY="$(cd "$SCRIPT_DIR/../../../.." && pwd)/provision-host/uis/lib/monitors.py"
fi

print_test_section "uis monitors apply/check: shrink guard, unchanged-skip, content drift"

start_test "the module imports and defines the safety functions"
_check="$(python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('monitors', '$MONITORS_PY')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
assert callable(m._shrink_refused)
assert callable(m._apply_is_unchanged)
assert callable(m._content_hash)
print('OK')
" 2>&1)"
[[ "$_check" == "OK" ]] && pass_test || fail_test "import/attribute check failed: $_check"

# One python3 process runs every case below and prints one PASS/FAIL line per
# case, so a single bash loop drives start_test/pass_test/fail_test per line
# without re-importing the module for each assertion.
_cases="$(python3 -c "
import importlib.util, sys
spec = importlib.util.spec_from_file_location('monitors', '$MONITORS_PY')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

def case(label, got, want):
    print(('PASS' if got == want else 'FAIL') + '|' + label +
          ('' if got == want else f' (got {got!r}, want {want!r})'))

case('first apply, no baseline, is never refused',
     m._shrink_refused(0, 2, False), False)
case('a grown set is never refused',
     m._shrink_refused(10, 15, False), False)
case('an unchanged set is never refused',
     m._shrink_refused(10, 10, False), False)
case('a drop within tolerance is not refused',
     m._shrink_refused(10, 6, False), False)
case('a drop past the tolerance IS refused',
     m._shrink_refused(10, 4, False), True)
case('a drop to zero IS refused',
     m._shrink_refused(10, 0, False), True)
case('--force bypasses the refusal',
     m._shrink_refused(10, 4, True), False)
case('identical content and Kuma already matching is unchanged',
     m._apply_is_unchanged('h', 'h', {'a', 'b'}, {'a', 'b'}, False), True)
case('a changed hash is never unchanged',
     m._apply_is_unchanged('h2', 'h', {'a', 'b'}, {'a', 'b'}, False), False)
case('Kuma missing a name even with a matching hash is not unchanged '
     '(something deleted it by hand)',
     m._apply_is_unchanged('h', 'h', {'a'}, {'a', 'b'}, False), False)
case('an unreachable Kuma (None) is never unchanged',
     m._apply_is_unchanged('h', 'h', None, {'a', 'b'}, False), False)
case('--force is never unchanged even if truly identical',
     m._apply_is_unchanged('h', 'h', {'a', 'b'}, {'a', 'b'}, True), False)
case('content hash does not depend on list order',
     m._content_hash([{'name': 'b', 'url': 'http://x'},
                       {'name': 'a', 'hostname': 'y', 'port': 1}]) ==
     m._content_hash([{'name': 'a', 'hostname': 'y', 'port': 1},
                       {'name': 'b', 'url': 'http://x'}]), True)
case('content hash changes when a monitor target changes '
     '(the retargeted-address bug check must catch)',
     m._content_hash([{'name': 'b', 'url': 'http://x'}]) ==
     m._content_hash([{'name': 'b', 'url': 'http://CHANGED'}]), False)
" 2>&1)"

if [[ "$_cases" == *"Traceback"* ]]; then
    fail_test "python raised while running the cases: $_cases"
else
    while IFS='|' read -r status label; do
        [[ -z "$status" ]] && continue
        start_test "$label"
        [[ "$status" == "PASS" ]] && pass_test || fail_test "$label"
    done <<< "$_cases"
fi

print_summary
