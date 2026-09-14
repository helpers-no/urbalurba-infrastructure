#!/bin/bash
# test-env-from-services.sh — the tenant names a SERVICE and UIS composes the
# address. This test RUNS the functions; it does not grep for them.
#
# 🔴 WHY THE SHAPE EXISTS. An export like `http://api-<app>.localhost` is
# host-facing. Delivered into a pod it points the pod at ITSELF — `.localhost`
# is loopback by definition (RFC 6761), and imac measured `curl` exiting 7,
# resolved-and-refused, not 6. The obvious remedy — have the tenant declare
# `<service>.<namespace>.svc.cluster.local` — asks a tenant artifact to encode
# something UIS does not keep stable: `namespace` was an undeclared field of
# service.schema.json until this release, and `gravitee` moved from `default` to
# `gravitee` in 2d0570d. An artifact holding the old value would have broken
# silently that day, in a different repository, with no signal here.
#
# ⚠️ So the tenant names a service id and UIS composes the address from
# services.json. The knowledge that may change stays on the side that may
# change it (atlas's proposal, via ops-dev #959).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
LIB="$REPO_ROOT/provision-host/uis/lib/template.sh"

PASS=0; FAIL=0; SKIP=0
pass() { echo -e "  Testing: $1... \033[0;32mPASS\033[0m"; ((++PASS)); }
fail() { echo -e "  Testing: $1... \033[0;31mFAIL\033[0m"; echo -e "    \033[0;31m→ $2\033[0m"; ((++FAIL)); }
skip() { echo -e "  Testing: $1... \033[0;33mSKIP\033[0m"; ((++SKIP)); }

echo "=== env_from_services: the tenant names a service, UIS composes the address ==="

if ! command -v yq >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    skip "yq and jq are available to run the resolver"
    echo ""
    echo "  Passed: $PASS  Failed: $FAIL  Skipped: $SKIP"
    exit 0
fi

# Load ONLY the three functions under test. Sourcing the whole lib would run its
# top-level setup; extracting them keeps this a unit test of real code rather
# than a copy of it.
log_error() { echo "ERROR: $*" >&2; }
export SERVICES_JSON="$REPO_ROOT/website/src/data/services.json"
eval "$(sed -n '/^_service_in_cluster_url() {/,/^}$/p' "$LIB")"
eval "$(sed -n '/^_validate_env_from_services() {/,/^}$/p' "$LIB")"
eval "$(sed -n '/^_resolve_service_env() {/,/^}$/p' "$LIB")"

# Control: the extraction actually produced callable functions. Without this a
# typo in the sed range turns every assertion below into a silent pass on an
# undefined function.
if declare -F _service_in_cluster_url >/dev/null \
   && declare -F _validate_env_from_services >/dev/null \
   && declare -F _resolve_service_env >/dev/null; then
    pass "control: all three functions loaded from the real lib"
else
    fail "control: all three functions loaded from the real lib" \
         "the sed extraction matched nothing — every assertion below would be vacuous"
    echo ""; echo "  Passed: $PASS  Failed: $FAIL  Skipped: $SKIP"; exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

_def() {
    # $1 = the env_from_* block, indented to sit under code_location
    cat > "$TMP/def.yaml" <<YAML
id: testapp
exports:
  api-url: "http://api-testapp.localhost"
provides:
  services:
    - service: dagster
      config:
        code_location:
          name: testapp
$1
YAML
    printf '%s' "$TMP/def.yaml"
}

# ── the address is composed, and composed correctly ──────────────────────────
url="$(_service_in_cluster_url postgrest atlas)"; rc=$?
want="http://atlas-postgrest.postgrest.svc.cluster.local:3000"
if [[ "$rc" -eq 0 && "$url" == "$want" ]]; then
    pass "🔴 a per-application service resolves to its own instance"
else
    fail "🔴 a per-application service resolves to its own instance" \
         "got rc=$rc '$url', wanted '$want'"
fi

# ⚠️ The port must be the PRIMARY published one. PostgREST's Service publishes
# api 3000 AND admin 3001, so anything that infers a single port is guessing.
if [[ "$url" == *":3000" ]]; then
    pass "the port is the primary published one, not an inference"
else
    fail "the port is the primary published one" "PostgREST publishes 3000 (api) and 3001 (admin)"
fi

# ── every refusal, and each one refuses for its own stated reason ────────────
f="$(_def '          env_from_services:
            APP_URL: postgrest')"
if _validate_env_from_services "$f" testapp >/dev/null 2>&1; then
    pass "a valid declaration is accepted"
else
    fail "a valid declaration is accepted" "the working case must not be refused"
fi

resolved="$(_resolve_service_env '{"APP_URL":"postgrest"}' testapp)"
if [[ "$resolved" == '{"APP_URL":"http://testapp-postgrest.postgrest.svc.cluster.local:3000"}' ]]; then
    pass "the resolved map carries literal URLs, not service ids"
else
    fail "the resolved map carries literal URLs" "got: $resolved"
fi

f="$(_def '          env_from_services:
            APP_URL: nosuchservice')"
out="$(_validate_env_from_services "$f" testapp 2>&1)"; rc=$?
if [[ "$rc" -ne 0 && "$out" == *"is not a UIS service"* ]]; then
    pass "an unknown service id is refused"
else
    fail "an unknown service id is refused" "rc=$rc out=$out"
fi

# 🔴 THE LOAD-BEARING ONE. A service UIS publishes no address for must refuse,
# never fall through to a guess. A guessed address that RESOLVES is the failure
# that cost a day to disprove.
f="$(_def '          env_from_services:
            APP_URL: redis')"
out="$(_validate_env_from_services "$f" testapp 2>&1)"; rc=$?
if [[ "$rc" -ne 0 && "$out" == *"publishes no in-cluster address"* ]]; then
    pass "🔴 a service with no published address is refused, not guessed at"
else
    fail "🔴 a service with no published address is refused, not guessed at" "rc=$rc out=$out"
fi

f="$(_def '          env_from_exports:
            APP_URL: api-url
          env_from_services:
            APP_URL: postgrest')"
out="$(_validate_env_from_services "$f" testapp 2>&1)"; rc=$?
if [[ "$rc" -ne 0 && "$out" == *"BOTH"* ]]; then
    pass "one variable claimed by both maps is refused rather than silently resolved"
else
    fail "one variable claimed by both maps is refused" "rc=$rc out=$out"
fi

f="$(_def '          env_from_services:
            APP_URL: postgrest')"
out="$(_validate_env_from_services "$f" "" 2>&1)"; rc=$?
if [[ "$rc" -ne 0 && "$out" == *"per-application"* ]]; then
    pass "a per-application address with no app_name is refused, not rendered half-empty"
else
    fail "a per-application address with no app_name is refused" "rc=$rc out=$out"
fi

# ⚠️ THE REMEDY MUST TRAVEL WITH THE CAUSE. A shared footer about in-cluster
# addressing reads as actionable to someone whose problem is a name collision —
# the "correct and unreachable" shape this work removed once already.
f="$(_def '          env_from_exports:
            APP_URL: api-url
          env_from_services:
            APP_URL: postgrest')"
out="$(_validate_env_from_services "$f" testapp 2>&1)"
if [[ "$out" != *"inCluster block"* && "$out" != *"services.json"* ]]; then
    pass "⚠️ a collision is not given advice about in-cluster addressing"
else
    fail "⚠️ a collision is not given advice about in-cluster addressing" \
         "advice that is correct and unrelated reads as actionable and is not"
fi

# ── the platform data backing all of this ────────────────────────────────────
if jq -e '.properties.inCluster.required == ["scheme","nameTemplate","port"]' \
     "$REPO_ROOT/website/src/data/schemas/service.schema.json" >/dev/null 2>&1; then
    pass "the schema declares inCluster and what it requires"
else
    fail "the schema declares inCluster and what it requires" \
         "composing an address from undeclared data is how the namespace field got here"
fi

# 🔴 Declaring `namespace` must NOT be read as promising it. The description is
# the only place that distinction is written down.
if jq -er '.properties.namespace.description' \
     "$REPO_ROOT/website/src/data/schemas/service.schema.json" 2>/dev/null \
     | grep -q "may change between releases"; then
    pass "🔴 the schema says declaring the namespace does not make it stable"
else
    fail "🔴 the schema says declaring the namespace does not make it stable" \
         "a declared field reads as a contract unless it says otherwise"
fi

# ⚠️ Every inCluster block must belong to an entry that HAS a namespace — the
# composition reads it from there and would otherwise produce `svc..svc.`.
missing="$(jq -r '.services[] | select(.inCluster != null) | select(.namespace == null) | .id' \
    "$SERVICES_JSON" 2>/dev/null)"
if [[ -z "$missing" ]]; then
    pass "every service publishing an address also declares its namespace"
else
    fail "every service publishing an address also declares its namespace" "missing on: $missing"
fi

# 🔴 services.json IS GENERATED from provision-host/uis/services/**. An
# inCluster block hand-added to the JSON survives until the next docs
# regeneration and then vanishes — and the symptom is every env_from_services
# install suddenly refusing with "UIS publishes no in-cluster address", long
# after the commit that caused it. Assert the source declares what the data
# claims.
_drift=""
while IFS= read -r sid; do
    [[ -z "$sid" ]] && continue
    if ! grep -rqs "^SCRIPT_IN_CLUSTER_NAME=" \
         --include="service-${sid}.sh" "$REPO_ROOT/provision-host/uis/services"; then
        _drift+="$sid "
    fi
done <<< "$(jq -r '.services[] | select(.inCluster != null) | .id' "$SERVICES_JSON" 2>/dev/null)"
if [[ -z "$_drift" ]]; then
    pass "🔴 every published address is declared in the service script, not just the generated JSON"
else
    fail "🔴 every published address is declared in the service script" \
         "hand-added to services.json and will be erased by the next regeneration: ${_drift% }"
fi

echo ""
echo "  Passed: $PASS  Failed: $FAIL  Skipped: $SKIP"
[[ "$FAIL" -eq 0 ]]
