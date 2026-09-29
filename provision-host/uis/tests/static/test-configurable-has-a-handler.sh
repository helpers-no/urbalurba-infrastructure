#!/bin/bash
# test-configurable-has-a-handler.sh — the flag and the handler must agree
#
# 🔴 Eight services declared SCRIPT_CONFIGURABLE="true" and TWO had handlers.
# The other six advertised a capability that produced, at the point of use:
#
#     No configure handler for 'redis'. Handler not yet implemented.
#
# That is a promise the platform could not keep, and it was readable from the
# service list and the generated docs, so a template author or an operator had
# no way to tell the two apart (urb-agents#1710; retracted by Terje 2026-09-29).
#
# ⚠️ The declaration and the handler live in different files, which is exactly
# the shape that drifts. A comment cannot check; this can. Task 1.5 of
# PLAN-cli-configure-retract-unimplemented.
#
# 🔵 It asserts the correspondence in BOTH directions. A handler without the
# flag is also wrong — the gate would refuse a service that can actually be
# configured, which is the same defect pointing the other way.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
SERVICES_DIR="$REPO/provision-host/uis/services"
HANDLER_DIR="$REPO/provision-host/uis/lib"
SERVICES_JSON="$REPO/website/src/data/services.json"

PASS=0; FAIL=0
pass() { echo -e "  Testing: $1... \033[0;32mPASS\033[0m"; ((++PASS)); }
fail() { echo -e "  Testing: $1... \033[0;31mFAIL\033[0m"; echo -e "    \033[0;31m→ $2\033[0m"; ((++FAIL)); }

echo "=== every configurable service has a handler, and vice versa ==="

mapfile -t SERVICE_FILES < <(find "$SERVICES_DIR" -name 'service-*.sh' | sort)
if [[ "${#SERVICE_FILES[@]}" -ge 10 ]]; then
    pass "control: the scan found service files (${#SERVICE_FILES[@]})"
else
    fail "control: the scan found service files" "found ${#SERVICE_FILES[@]} — the glob is wrong and every check below is vacuous"
    echo ""; echo "  Passed: $PASS  Failed: $FAIL"; exit 1
fi

# --- declared true, no handler file: the defect this test exists for -------
_declared=""; _orphans=""
for f in "${SERVICE_FILES[@]}"; do
    grep -q 'SCRIPT_CONFIGURABLE="true"' "$f" || continue
    id="$(basename "$f" .sh)"; id="${id#service-}"
    _declared+="$id "
    [[ -f "$HANDLER_DIR/configure-$id.sh" ]] || _orphans+="$id "
done
if [[ -z "$_orphans" ]]; then
    pass "no service declares SCRIPT_CONFIGURABLE without a handler"
else
    fail "no service declares the flag without a handler" \
         "these advertise what they cannot do: ${_orphans% } — add lib/configure-<id>.sh or drop the flag"
fi

# --- 🔵 and the other direction: a handler nobody can reach ----------------
_unreachable=""
for h in "$HANDLER_DIR"/configure-*.sh; do
    [[ -f "$h" ]] || continue
    id="$(basename "$h" .sh)"; id="${id#configure-}"
    # configure.sh itself is the dispatcher, not a handler
    [[ "$id" == "postgresql" || "$id" == "postgrest" ]] || true
    f="$(find "$SERVICES_DIR" -name "service-$id.sh" | head -1)"
    [[ -n "$f" ]] || continue
    grep -q 'SCRIPT_CONFIGURABLE="true"' "$f" || _unreachable+="$id "
done
if [[ -z "$_unreachable" ]]; then
    pass "no handler exists that the gate would refuse to reach"
else
    fail "every handler is reachable" \
         "these have a handler but not the flag, so configure refuses them: ${_unreachable% }"
fi

# --- the generated JSON must agree with the declarations -------------------
# ⚠️ services.json is GENERATED. If it disagrees, the gate reads one truth and
# the service files state another — and the gate is what users meet.
if command -v python3 >/dev/null 2>&1 && [[ -f "$SERVICES_JSON" ]]; then
    _json_ids="$(python3 -c "
import json
d=json.load(open('$SERVICES_JSON'))
print(' '.join(sorted(s['id'] for s in d['services'] if s.get('configurable'))))
" 2>/dev/null)"
    _decl_sorted="$(echo "$_declared" | tr ' ' '\n' | grep -v '^$' | sort | tr '\n' ' ')"
    _json_sorted="$(echo "$_json_ids" | tr ' ' '\n' | grep -v '^$' | sort | tr '\n' ' ')"
    if [[ "$_decl_sorted" == "$_json_sorted" ]]; then
        pass "services.json agrees with the service files (${_json_sorted% })"
    else
        fail "services.json agrees with the service files" \
             "declared: ${_decl_sorted% } | generated: ${_json_sorted% } — run uis-docs.sh"
    fi
else
    fail "services.json could be read" "no python3 or no $SERVICES_JSON — the agreement is unchecked"
fi

# --- 🔴 the usage examples must name services that work --------------------
# The error shown when you get the syntax wrong used to recommend
# `uis configure redis`, which was never implemented.
# ⚠️ Strip comments and match only ECHOED examples. Grepping the whole file
# caught the comment explaining this very defect, and the placeholder in
# "uis configure <service>" — so it failed on its own documentation.
_cfg="$REPO/provision-host/uis/lib/configure.sh"
_examples="$(grep -v '^[[:space:]]*#' "$_cfg" \
    | grep -E '^[[:space:]]*echo "  uis configure ' \
    | grep -oE 'uis configure [a-z0-9-]+' \
    | awk '{print $NF}' | sort -u)"
_bad=""
for e in $_examples; do
    grep -q " $e " <<<" $_declared " || _bad+="$e "
done
if [[ -z "$_bad" ]]; then
    pass "every service named in configure's own examples is configurable"
else
    fail "configure's examples name only configurable services" \
         "it recommends: ${_bad% } — a command the tool would refuse"
fi

echo ""
echo "  Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
