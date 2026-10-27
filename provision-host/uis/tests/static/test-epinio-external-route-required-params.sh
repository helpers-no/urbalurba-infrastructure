#!/bin/bash
# test-epinio-external-route-required-params.sh — urb-agents#2040 (gate 3 migration)
#
# 626-epinio-external-route.yml and its wrapper script give one Epinio app a
# stable external route, named directly from three caller-supplied parameters
# (app name, namespace, port) — there is no safe default for any of them, since
# all three are chosen by whoever ran `epinio push`, not by this repository.
# This asserts that both the playbook and the wrapper script actually refuse
# to proceed with any one of the three missing, and that the Service/
# IngressRoute names are driven by the parameter (so re-running is an update,
# not a second resource).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
PLAYBOOK="$REPO/ansible/playbooks/626-epinio-external-route.yml"
WRAPPER="$REPO/scripts/epinio/epinio-expose-route.sh"

PASS=0; FAIL=0
pass() { echo -e "  Testing: $1... \033[0;32mPASS\033[0m"; ((++PASS)); }
fail() { echo -e "  Testing: $1... \033[0;31mFAIL\033[0m"; echo -e "    \033[0;31m→ $2\033[0m"; ((++FAIL)); }

echo "=== epinio external-route: three required params, no safe default (#2040) ==="

[[ -f "$PLAYBOOK" ]] || { fail "playbook present" "missing: $PLAYBOOK"; echo; echo "  Passed: $PASS  Failed: $FAIL"; exit 1; }
[[ -f "$WRAPPER" ]] || { fail "wrapper script present" "missing: $WRAPPER"; echo; echo "  Passed: $PASS  Failed: $FAIL"; exit 1; }

pb="$(grep -v '^[[:space:]]*#' "$PLAYBOOK")"

if grep -qF 'epinio_route_app_name: ""' <<<"$pb" && grep -qF 'epinio_route_namespace: ""' <<<"$pb" && grep -qF 'epinio_route_port: ""' <<<"$pb"; then
    pass "all three vars default to empty, not a guessed value"
else
    fail "vars default to empty" "a default value here would silently route the wrong app/namespace/port"
fi

if grep -qF 'epinio_route_app_name | length > 0' <<<"$pb" \
    && grep -qF 'epinio_route_namespace | length > 0' <<<"$pb" \
    && grep -qF 'epinio_route_port | string | length > 0' <<<"$pb"; then
    pass "an assert task actually checks all three before anything is applied"
else
    fail "assert checks all three" "a missing parameter could reach the k8s tasks below as an empty string"
fi

if grep -qF 'name: "{{ epinio_route_app_name }}-external"' <<<"$pb"; then
    pass "the Service/IngressRoute names are derived from the app name, not generated"
else
    fail "names derived from app name" "re-running with the same app could create a second, differently-named resource instead of updating the first"
fi

for var in EPINIO_APP_NAME EPINIO_NAMESPACE EPINIO_APP_PORT; do
    if grep -q "if \[ -z \"\$$var\" \]" "$WRAPPER"; then
        pass "wrapper checks \$$var is set"
    else
        fail "wrapper checks \$$var is set" "the wrapper could invoke the playbook with this parameter empty"
    fi
done

if grep -qE '^[[:space:]]*exit 1$' "$WRAPPER"; then
    pass "wrapper exits non-zero when a parameter is missing"
else
    fail "wrapper exits non-zero on missing parameter" "a missing parameter might not actually stop the script"
fi

echo ""
echo "  Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
