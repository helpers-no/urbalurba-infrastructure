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

# 🔴 THE REFUSAL LOOKS BACKWARDS: an older UIS ignores env_from_services,
# delivers the host-facing export and INSTALLS, while this release refuses — so
# the host that upgraded is the one that stops (ops-dev, #967). It is still
# right, because refusing forces "replace, in one change", and an older UIS then
# sets NOTHING (one CANNOT line naming the variable) instead of delivering the
# loopback value (which resolves, hits the pod itself, and reads as a cluster
# problem). The message has to say WHICH to keep, or an author mid-migration is
# told there is a choice when there is not.
if [[ "$out" == *"REPLACE"* && "$out" == *"env_from_exports"* ]]; then
    pass "🔴 the collision says REPLACE, naming which entry to delete"
else
    fail "🔴 the collision says REPLACE, naming which entry to delete" \
         "'declare it in one of them' leaves the author to guess, and the wrong guess is the loopback one"
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

# ── a definition newer than this binary ──────────────────────────────────────
# 🔴 MEASURED ON 1.6.83: an `env_from_services:` block was dropped in SILENCE.
# rc=0, no output, the key absent from the conf — the pod then came up with the
# variable unset and the check reported "could not look" with nothing anywhere
# saying why. The cause is that the reader walks the WHITELIST, so a key the
# whitelist lacks is never looked at (ops-dev, #960).
#
# ⚠️ `config.*` one level up has refused unknown keys since it was written. The
# asymmetry was the defect.
eval "$(sed -n '/^TEMPLATE_CONFIG_KEYS=/p;/^TEMPLATE_CODE_LOCATION_KEYS=/p' "$LIB")"
eval "$(sed -n '/^_conf_get() {/,/^}$/p' "$LIB")"
eval "$(sed -n '/^_write_service_conf() {/,/^}$/p' "$LIB")"

_conf_for() {
    local extra="$1" d="$TMP/plan"; rm -rf "$d"; mkdir -p "$d"
    cat > "$TMP/wire.yaml" <<YAML
id: testapp
provides:
  services:
    - service: dagster
      config:
        code_location:
          name: testapp
          image: ghcr.io/x/testapp
          tag: v1
          module: testapp.defs
          why: "the pipelines"
$extra
YAML
    _write_service_conf "$d" "$TMP/wire.yaml" 0 dagster 2>"$TMP/err"
    echo "$?"
}

rc="$(_conf_for '          env_from_services:
            APP_URL: postgrest')"
if [[ "$rc" == "0" ]] && grep -q '^code_location_env_from_services=' "$TMP/plan/dagster.conf"; then
    pass "a known key reaches the plan"
else
    fail "a known key reaches the plan" "rc=$rc conf=$(cat "$TMP/plan/dagster.conf" 2>/dev/null)"
fi

rc="$(_conf_for '          env_from_the_future:
            APP_URL: something')"
if [[ "$rc" != "0" ]] && grep -q "Unknown code_location key 'env_from_the_future'" "$TMP/err"; then
    pass "🔴 a code_location key this binary cannot act on REFUSES, it does not drop it"
else
    fail "🔴 a code_location key this binary cannot act on REFUSES" \
         "rc=$rc err=$(cat "$TMP/err" 2>/dev/null | head -2)"
fi

# ⚠️ And it must say WHY, because the reader is holding a definition that is
# correct and a binary that is old — "unknown key" alone sends them to the
# artifact, which is the wrong file.
if grep -q "NEWER than this" "$TMP/err"; then
    pass "the refusal names the likely cause: the artifact is newer than this UIS"
else
    fail "the refusal names the likely cause" "'unknown key' alone points at the wrong file"
fi

# ── the declared port must agree with something UIS states independently ─────
# 🔴 imac measured what my own test could not: PostgREST's admin port answers
# 200 on /ready, /live AND /metrics, so "the wrong port is green on every
# liveness surface" (#961). A wrong `inCluster.port` would compose an address
# that resolves, connects, and answers — with the wrong API.
#
# ⚠️ MY TEST ABOVE CANNOT CATCH THAT. It asserts 3000 against services.json,
# which I also wrote: a control that shares the instrument shares its failure.
#
# 🔵 TWO TIERS, AND THE TEST SAYS WHICH IT GOT. An HTTP service has an
# IngressRoute, which is BY DEFINITION the port the public API is served on —
# if the declared port were the admin one, those disagree. A service with no
# ingress (postgresql is TCP and is exposed by `uis expose`, not Traefik) has no
# such statement, so the weaker check applies: the port must at least appear as
# a real `port:` in the manifests that create the service.
#
# ⚠️ The weaker tier is NOT silent. A first draft of this failed outright when
# no IngressRoute existed, which reads as rigour and is not: it would have
# blocked the next legitimate declaration — postgresql's 5432 is correct and
# has no ingress to prove it. Blocking valid work is not "failing toward
# alarm". Reporting the weaker tier by name is.
_port_strong=0; _port_weak=""; _port_bad=""
while IFS=$'\t' read -r sid sport splay; do
    [[ -z "$sid" ]] && continue
    # the playbook's NNN- prefix names its template set
    _prefix="${splay%%-*}"
    # 🔴 BOTH MANIFEST HOMES. UIS keeps service manifests in TWO places —
    # `ansible/playbooks/templates/` for per-app rendered ones and `manifests/`
    # for product-level ones — and the first version of this guard looked only
    # in the first. Declaring `inCluster` on `dagster`, whose IngressRoute lives
    # in `manifests/360-dagster-ingressroute.yaml`, failed the guard for the
    # wrong reason: the port was right and the search was incomplete.
    #
    # ⚠️ Found by USING the mechanism rather than by reading the guard. A search
    # that looks in one of two real locations reports absence it has not
    # established — the could-not-look defect, wearing a test's clothes.
    _tpl=("$REPO_ROOT"/ansible/playbooks/templates/${_prefix}-* "$REPO_ROOT"/manifests/${_prefix}-*)
    _ir="$(ls "$REPO_ROOT"/ansible/playbooks/templates/${_prefix}-*ingressroute* \
               "$REPO_ROOT"/manifests/${_prefix}-*ingressroute* 2>/dev/null | head -1)"
    if [[ -n "$_ir" ]]; then
        _routed="$(grep -oE '^[[:space:]]*port:[[:space:]]*[0-9]+' "$_ir" | grep -oE '[0-9]+' | head -1)"
        _port_strong=$((_port_strong + 1))
        [[ "$_routed" == "$sport" ]] || \
            _port_bad+="$sid declares inCluster.port $sport but $(basename "$_ir") routes the API to ${_routed:-<none>}"$'\n'
        continue
    fi
    # weaker tier: the number must be a port some manifest for this service
    # actually publishes, so a typed or invented value still fails.
    # ⚠️ A glob that matched nothing expands to the pattern itself, so only
    # real files are passed to grep — otherwise one missing home makes grep fail
    # and the port reads as unpublished.
    _real=(); for _f in "${_tpl[@]}"; do [[ -f "$_f" ]] && _real+=("$_f"); done
    if [[ "${#_real[@]}" -gt 0 ]] && grep -qhE "^[[:space:]]*(port|targetPort):[[:space:]]*${sport}([[:space:]]|$)" "${_real[@]}" 2>/dev/null; then
        _port_weak+="$sid "
    else
        _port_bad+="$sid declares inCluster.port $sport, which no manifest for '$splay' publishes"$'\n'
    fi
done <<< "$(jq -r '.services[] | select(.inCluster != null) | [.id, (.inCluster.port|tostring), .playbook] | @tsv' "$SERVICES_JSON" 2>/dev/null)"

# 🔴 Nothing checked at all is a vacuous assertion, not a pass.
if [[ "$_port_strong" -gt 0 || -n "$_port_weak" ]]; then
    pass "control: every published in-cluster port was compared against a manifest ($_port_strong via IngressRoute)"
else
    fail "control: an in-cluster port was compared against a manifest" \
         "nothing was compared — this assertion is vacuous as written"
fi

if [[ -z "$_port_bad" ]]; then
    pass "🔴 the declared in-cluster port agrees with the manifests that create the service"
else
    fail "🔴 the declared in-cluster port agrees with the manifests that create the service" \
         "${_port_bad%$'\n'}"
fi

# ⚠️ Name the services that only got the weaker check, so "verified" is not
# claimed for a port that was merely found somewhere.
if [[ -n "$_port_weak" ]]; then
    echo "    note: no IngressRoute for ${_port_weak% } — port matched a manifest, not an API route" >&2
fi

echo ""
echo "  Passed: $PASS  Failed: $FAIL  Skipped: $SKIP"
[[ "$FAIL" -eq 0 ]]
