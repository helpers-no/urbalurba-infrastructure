#!/bin/bash
# test-template-multi-surface.sh — Unit tests for PLAN-templates-001
#
# Covers the three findings that plan closes:
#   TPL-F3  _service_is_multi_instance — drives whether `uis deploy` gets --app
#   TPL-F4  _conf_get / _write_service_conf — the per-service config vocabulary
#   TPL-F7  _collect_init_sql — a file, or a directory of ordered *.sql
#
# No cluster needed. yq-dependent tests skip when yq is absent (it lives in
# uis-provision-host); everything else runs anywhere jq does.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"

if [[ -d "/mnt/urbalurbadisk/provision-host/uis" ]]; then
    UIS_LIB="/mnt/urbalurbadisk/provision-host/uis/lib"
else
    UIS_LIB="$(cd "$SCRIPT_DIR/../../lib" && pwd)"
fi

source "$UIS_LIB/logging.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# services.json fixture — deliberately NOT the live file, so these assertions
# cannot be broken by a metadata change elsewhere.
export SERVICES_JSON="$TMP/services.json"
cat > "$SERVICES_JSON" <<'JSON'
{"services":[
  {"id":"postgresql","priority":30,"multiInstance":false},
  {"id":"postgrest","priority":50,"multiInstance":true},
  {"id":"dagster","priority":56}
]}
JSON
export STACKS_JSON="$TMP/stacks.json"
echo '{"itemListElement":[]}' > "$STACKS_JSON"

source "$UIS_LIB/template.sh"

# ============================================================================
# TPL-F3 — _service_is_multi_instance
# ============================================================================
print_test_section "TPL-F3: multi-instance detection drives --app"

start_test "postgrest is multi-instance (so deploy gets --app)"
_service_is_multi_instance postgrest && pass_test || fail_test "postgrest should be multi-instance"

start_test "postgresql is not multi-instance (so deploy omits --app)"
_service_is_multi_instance postgresql && fail_test "postgresql should not be multi-instance" || pass_test

start_test "a service with no multiInstance key defaults to false"
_service_is_multi_instance dagster && fail_test "absent key must default false" || pass_test

start_test "an unknown service defaults to false rather than erroring"
_service_is_multi_instance nosuchservice && fail_test "unknown service must be false" || pass_test

# ============================================================================
# TPL-F4 — _conf_get
# ============================================================================
print_test_section "TPL-F4: the per-service config vocabulary"

conf="$TMP/postgrest.conf"
printf 'database=atlas\nschemas=api_v1,marts\nurl_prefix=api-atlas\n' > "$conf"

start_test "conf_get reads a present key"
assert_equals "api-atlas" "$(_conf_get "$conf" url_prefix)" "url_prefix"

start_test "conf_get reads a value containing commas"
assert_equals "api_v1,marts" "$(_conf_get "$conf" schemas)" "schemas"

start_test "conf_get returns empty for an absent key"
assert_empty "$(_conf_get "$conf" namespace)" "absent key"

start_test "conf_get returns empty for a missing file"
assert_empty "$(_conf_get "$TMP/nope.conf" database)" "missing file"

start_test "conf_get does not match a key that is a prefix of another"
printf 'url_prefix=real\n' > "$TMP/p.conf"
assert_empty "$(_conf_get "$TMP/p.conf" url)" "'url' must not match 'url_prefix'"

# ============================================================================
# TPL-F7 — _collect_init_sql
# ============================================================================
print_test_section "TPL-F7: init: as a file or an ordered directory"

echo "CREATE SCHEMA one;" > "$TMP/single.sql"

start_test "a single file is returned unchanged"
assert_equals "CREATE SCHEMA one;" "$(_collect_init_sql "$TMP/single.sql" 2>/dev/null)" "single file"

# Numbered files created out of order on disk, to prove sorting is real and not
# an accident of creation order.
mkdir -p "$TMP/migrations"
echo "SELECT 50;" > "$TMP/migrations/050_third.sql"
echo "SELECT 1;"  > "$TMP/migrations/001_first.sql"
echo "SELECT 26;" > "$TMP/migrations/026_second.sql"
echo "not sql"    > "$TMP/migrations/README.md"

start_test "a directory applies *.sql in LC_ALL=C sort order"
out=$(_collect_init_sql "$TMP/migrations" 2>/dev/null)
order=$(echo "$out" | grep -o 'SELECT [0-9]*' | tr '\n' ' ')
assert_equals "SELECT 1; SELECT 26; SELECT 50; " "$(echo "$out" | grep -oE 'SELECT [0-9]+;' | tr '\n' ' ')" "apply order"

start_test "non-.sql files are excluded"
echo "$out" | grep -q "not sql" && fail_test "README.md was included" || pass_test

start_test "the ordered file list is logged to stderr before applying"
err=$(_collect_init_sql "$TMP/migrations" 2>&1 >/dev/null)
echo "$err" | grep -q "3 .sql file(s)" && echo "$err" | grep -q "001_first.sql" \
    && pass_test || fail_test "expected count and file list on stderr, got: $err"

start_test "each chunk is labelled with its source file"
echo "$out" | grep -q -- "-- >>> 026_second.sql" && pass_test || fail_test "missing per-file marker"

start_test "an empty directory FAILS rather than installing nothing"
mkdir -p "$TMP/empty"
_collect_init_sql "$TMP/empty" >/dev/null 2>&1 && fail_test "empty dir must fail" || pass_test

start_test "a directory with only non-.sql files also fails"
mkdir -p "$TMP/nosql"; echo x > "$TMP/nosql/notes.txt"
_collect_init_sql "$TMP/nosql" >/dev/null 2>&1 && fail_test "must fail with no .sql" || pass_test

start_test "a path that is neither file nor directory fails"
_collect_init_sql "$TMP/does-not-exist" >/dev/null 2>&1 && fail_test "must fail" || pass_test

start_test "un-padded numeric prefixes trigger a warning (order inverts)"
mkdir -p "$TMP/unpadded"
for f in 9_nine 10_ten 100_hundred; do echo "SELECT 1;" > "$TMP/unpadded/$f.sql"; done
warn=$(_collect_init_sql "$TMP/unpadded" 2>&1 >/dev/null)
echo "$warn" | grep -qi "lexicographic" && pass_test || fail_test "no padding warning: $warn"

start_test "the warning shows what numeric order would have been"
echo "$warn" | grep -A3 "Numeric order" | grep -q "9_nine.sql" && pass_test \
    || fail_test "numeric order not shown: $warn"

start_test "zero-padded names produce NO warning"
warn2=$(_collect_init_sql "$TMP/migrations" 2>&1 >/dev/null)
echo "$warn2" | grep -qi "lexicographic" && fail_test "warned on padded names" || pass_test

start_test "the warning does not change the order actually applied"
out2=$(_collect_init_sql "$TMP/unpadded" 2>/dev/null)
first=$(echo "$out2" | grep -m1 -o -- "-- >>> [0-9_a-z]*\.sql")
assert_equals "-- >>> 100_hundred.sql" "$first" "lexicographic order is still what is applied"

# ============================================================================
# TPL-F3 (part 2) — the per-service deploy/configure ORDER
#
# The --app flag was only half of TPL-F3. A multi-instance install still failed,
# because the runner deployed before configuring and 088-setup-postgrest.yml
# needs the per-app secret configure creates. Found end-to-end by imac on
# urb-agents#335 after the flag fix. These assert the decision, which is what
# the executor branches on.
# ============================================================================
print_test_section "TPL-F3 part 2: configure-before-deploy for multi-instance"

start_test "multi-instance means configure runs first"
_service_is_multi_instance postgrest && pass_test || fail_test "postgrest must select configure-first"

start_test "single-instance means deploy runs first"
_service_is_multi_instance postgresql && fail_test "postgresql must not select configure-first" || pass_test

start_test "the reasoning holds for an unknown service (deploy first, the safe default)"
_service_is_multi_instance whatever && fail_test "unknown must default to deploy-first" || pass_test

# ============================================================================
# TPL-F4 — _write_service_conf (needs yq)
# ============================================================================
print_test_section "TPL-F4: config parsing and validation (needs yq)"

if ! command -v yq >/dev/null 2>&1; then
    skip_test "Skipping yq-dependent tests: yq not installed (it lives in uis-provision-host)"
    skip_test "Skipping yq-dependent tests: yq not installed"
    skip_test "Skipping yq-dependent tests: yq not installed"
    skip_test "Skipping yq-dependent tests: yq not installed"
else
    info="$TMP/template-info.yaml"
    cat > "$info" <<'YAML'
install_type: stack
params: { app_name: atlas }
provides:
  services:
    - service: postgresql
      config: { database: atlas, namespace: dagster, secret_name_prefix: atlas-database }
    - service: postgrest
      config: { schemas: api_v1, url_prefix: api-atlas }
    - service: bad
      config: { url-prefix: typo }
    - service: lonely
      config: { namespace: dagster }
YAML
    pd="$TMP/plan"; mkdir -p "$pd"

    start_test "every supported key is written to the conf file"
    _write_service_conf "$pd" "$info" 0 postgresql >/dev/null 2>&1
    [[ "$(_conf_get "$pd/postgresql.conf" namespace)" == "dagster" && \
       "$(_conf_get "$pd/postgresql.conf" secret_name_prefix)" == "atlas-database" ]] \
        && pass_test || fail_test "namespace/secret_name_prefix not written"

    start_test "schemas and url_prefix are written"
    _write_service_conf "$pd" "$info" 1 postgrest >/dev/null 2>&1
    [[ "$(_conf_get "$pd/postgrest.conf" schemas)" == "api_v1" && \
       "$(_conf_get "$pd/postgrest.conf" url_prefix)" == "api-atlas" ]] \
        && pass_test || fail_test "schemas/url_prefix not written"

    start_test "an unknown config key is REJECTED, not ignored"
    _write_service_conf "$pd" "$info" 2 bad >/dev/null 2>&1 \
        && fail_test "typo'd key was accepted" || pass_test

    start_test "namespace without secret_name_prefix fails, naming the missing one"
    out=$(_write_service_conf "$pd" "$info" 3 lonely 2>&1)
    if [[ $? -eq 0 ]]; then
        fail_test "namespace alone was accepted"
    else
        echo "$out" | grep -q "secret_name_prefix" && pass_test \
            || fail_test "error did not name the missing key: $out"
    fi
fi

# ============================================================================
# set -e and command substitution — the shape that made two handlers dead code
#
# `x=$(cmd)` where cmd fails ABORTS under `set -e`, so a following `x_exit=$?`
# and everything testing it is unreachable. It defeated the configure-failure
# handler in template.sh (silent failures, urb-agents#335) and the Cancel path
# in menu-helpers.sh. These assert the IDIOM, which is what both fixes rely on.
# ============================================================================
print_test_section "set -e: capturing exit status from a substitution"

start_test "a bare assignment aborts before the handler (the defect)"
out=$(bash -c 'set -e; f(){ local r; r=$(bash -c "echo J; exit 1"); echo "HANDLER:$r"; }; f' 2>/dev/null || true)
assert_empty "$out" "handler must NOT be reached with a bare assignment"

start_test "|| rc=\$? reaches the handler and preserves the output (the fix)"
out=$(bash -c 'set -e; f(){ local r rc=0; r=$(bash -c "echo J; exit 1") || rc=$?; echo "HANDLER:$r:$rc"; }; f' 2>/dev/null || true)
assert_equals "HANDLER:J:1" "$out" "handler reached, stdout and status both kept"

start_test "no bare assign-then-\$? remains in the uis libs"
lib_dir="$UIS_LIB"
found=$(for f in "$lib_dir"/*.sh; do
    awk 'prev ~ /^[[:space:]]*(local +)?[a-z_]+=\$\(/ && $0 ~ /^[[:space:]]*(local +)?[a-z_]+=\$\?[[:space:]]*$/ {print FILENAME": "NR} {prev=$0}' "$f"
done)
assert_empty "$found" "libs must capture with || rc=\$? under set -e"

# ============================================================================
# PLAN-templates-002 phase 1 — the allowlist and the pin
#
# An application's definition is pulled and then fed to `configure --init-file`,
# which applies it as the database owner. So these two checks are a security
# boundary, not validation, and they are the cheapest thing to get wrong.
# ============================================================================
print_test_section "Phase 1: allowlist and immutability"

start_test "an allowlisted artifact is accepted"
_template_source_allowed "ghcr.io/terchris/atlas-data/uis" && pass_test || fail_test "should be allowed"

start_test "the other default is accepted too"
_template_source_allowed "ghcr.io/helpers-no/something/uis" && pass_test || fail_test "should be allowed"

start_test "an artifact outside the allowlist is REFUSED"
_template_source_allowed "ghcr.io/stranger/evil/uis" && fail_test "must be refused" || pass_test

start_test "a lookalike registry is refused (docker.io, not ghcr.io)"
_template_source_allowed "docker.io/terchris/atlas-data/uis" && fail_test "must be refused" || pass_test

start_test "an empty artifact is refused rather than matching everything"
_template_source_allowed "" && fail_test "empty must be refused" || pass_test

start_test "an installation can extend the allowlist via .uis.extend"
mkdir -p "$TMP/extend"
printf '# a comment\n\nghcr.io/thirdparty/*\n' > "$TMP/extend/template-allowlist.conf"
EXTEND_DIR="$TMP/extend" _template_source_allowed "ghcr.io/thirdparty/app/uis" && pass_test \
    || fail_test "extend file should widen the allowlist"

start_test "extending does not remove the defaults"
EXTEND_DIR="$TMP/extend" _template_source_allowed "ghcr.io/terchris/x/uis" && pass_test \
    || fail_test "defaults must survive"

start_test "no digest is refused — a tag alone is not a pin"
_template_pin_is_immutable "v20260909-abc1234" "" 2>/dev/null && fail_test "must refuse" || pass_test

start_test "a malformed digest is refused"
_template_pin_is_immutable "v20260909-abc1234" "sha256:nothex" 2>/dev/null && fail_test "must refuse" || pass_test

start_test "latest is refused even with a valid digest"
_template_pin_is_immutable "latest" "sha256:$(printf 'a%.0s' {1..64})" 2>/dev/null && fail_test "must refuse" || pass_test

start_test "a branch-shaped tag is refused"
_template_pin_is_immutable "main" "sha256:$(printf 'a%.0s' {1..64})" 2>/dev/null && fail_test "must refuse" || pass_test

start_test "an immutable tag with a valid digest is accepted"
_template_pin_is_immutable "v20260909-abc1234" "sha256:$(printf 'b%.0s' {1..64})" && pass_test || fail_test "should be accepted"

start_test "a missing source field is named, not dereferenced"
out=$(_require_source_fields '{"source":{"artifact":"ghcr.io/terchris/a/uis"}}' fixture 2>&1) && fail_test "must fail" || true
echo "$out" | grep -q "source.digest" && pass_test || fail_test "should name the missing field: $out"

# ============================================================================
# Phase 1 — resolution, against an OCI layout on disk (needs oras; no network)
# ============================================================================
print_test_section "Phase 1: resolution via oras"

if ! command -v oras >/dev/null 2>&1; then
    skip_test "Skipping oras tests: oras not installed (it ships in uis-provision-host 1.6.16+)"
    skip_test "Skipping oras tests: oras not installed"
    skip_test "Skipping oras tests: oras not installed"
else
    layout="$TMP/layout"
    ( mkdir -p "$TMP/def/migrations" && cd "$TMP/def" \
      && printf 'id: fixture\ninstall_type: stack\n' > template-info.yaml \
      && echo "SELECT 1;" > migrations/001_a.sql \
      && oras push --oci-layout "$layout:v20260909-abc1234" template-info.yaml migrations/001_a.sql ) >/dev/null 2>&1
    fixture_digest=$(oras manifest fetch --oci-layout --descriptor "$layout:v20260909-abc1234" 2>/dev/null \
        | sed -n 's/.*"digest":"\([^"]*\)".*/\1/p')

    export UIS_ORAS_OCI_LAYOUT=1 TEMPLATE_CACHE_DIR="$TMP/cache"

    # ⚠️ Each case runs in a SUBSHELL with its own allowlist. The first version of
    # these tests wrote `TEMPLATE_ALLOWLIST_DEFAULT="$layout" out=$(...)`, which is
    # two variable assignments and NOT an env-prefixed command — the env-prefix
    # form only applies when a command follows. So the allowlist leaked globally
    # and the refusal case passed the check it was meant to fail. It failed
    # honestly, which is the only reason I noticed.
    start_test "resolution pulls the definition and echoes its path"
    out=$( TEMPLATE_ALLOWLIST_DEFAULT="$layout"; _resolve_definition fixture "$layout" v20260909-abc1234 "$fixture_digest" public 2>/dev/null )
    [[ -f "$out/template-info.yaml" ]] && pass_test || fail_test "no definition at '$out'"

    start_test "the cache is keyed by digest, so a re-resolve is a hit"
    out2=$( TEMPLATE_ALLOWLIST_DEFAULT="$layout"; _resolve_definition fixture "$layout" v20260909-abc1234 "$fixture_digest" public 2>&1 >/dev/null )
    echo "$out2" | grep -qi "cached" && pass_test || fail_test "expected a cache hit: $out2"

    start_test "an artifact outside the allowlist is refused before any pull"
    ( _resolve_definition fixture "$layout" v20260909-abc1234 "$fixture_digest" public >/dev/null 2>&1 ) \
        && fail_test "must refuse when not allowlisted" || pass_test

    start_test "the refusal names the allowlist rather than just saying no"
    err=$( _resolve_definition fixture "$layout" v20260909-abc1234 "$fixture_digest" public 2>&1 >/dev/null )
    echo "$err" | grep -q "ghcr.io/terchris" && pass_test || fail_test "should list what IS allowed: $err"

    unset UIS_ORAS_OCI_LAYOUT TEMPLATE_CACHE_DIR
fi

# ============================================================================
# PLAN-templates-002 phase 3 — the code-location writer (TPL-F5)
#
# The write is filter-then-append keyed on `name`, which is what makes it
# idempotent and what makes removal the same filter without the append. Needs
# yq (mikefarah v4, pinned in the Dockerfile).
# ============================================================================
print_test_section "Phase 3: the code-location writer"

if ! command -v yq >/dev/null 2>&1; then
    for _ in 1 2 3 4 5 6; do skip_test "Skipping code-location tests: yq not installed"; done
else
    cl_dir="$TMP/cl"; mkdir -p "$cl_dir"

    start_test "a code location is written in the shape the Dagster playbook reads"
    ( EXTEND_DIR="$cl_dir"; _write_code_location atlas-data ghcr.io/terchris/atlas-data \
        v20260909-abc1234 atlas_data.definitions "Ingests 41 sources" "atlas-database-db" ) >/dev/null 2>&1
    f="$cl_dir/dagster-code-locations.yaml"
    got=$(yq -r '.code_locations[0] | [.name,.image,.tag,.module,.env_secrets[0]] | join(" ")' "$f" 2>/dev/null)
    assert_equals "atlas-data ghcr.io/terchris/atlas-data v20260909-abc1234 atlas_data.definitions atlas-database-db" "$got" "entry shape"

    start_test "re-running at the same pin is byte-identical"
    b=$(sha256sum "$f" | cut -d' ' -f1)
    ( EXTEND_DIR="$cl_dir"; _write_code_location atlas-data ghcr.io/terchris/atlas-data \
        v20260909-abc1234 atlas_data.definitions "Ingests 41 sources" "atlas-database-db" ) >/dev/null 2>&1
    a=$(sha256sum "$f" | cut -d' ' -f1)
    assert_equals "$b" "$a" "idempotent at the same pin"

    start_test "a new pin changes the tag and does NOT duplicate the entry"
    ( EXTEND_DIR="$cl_dir"; _write_code_location atlas-data ghcr.io/terchris/atlas-data \
        v20260910-def5678 atlas_data.definitions "Ingests 41 sources" "atlas-database-db" ) >/dev/null 2>&1
    got=$(yq -r '"\(.code_locations | length) \(.code_locations[0].tag)"' "$f" 2>/dev/null)
    assert_equals "1 v20260910-def5678" "$got" "one entry, new tag"

    start_test "a second tenant does not disturb the first"
    ( EXTEND_DIR="$cl_dir"; _write_code_location other-data ghcr.io/helpers-no/other \
        v9-zzz other.definitions "why two" "" ) >/dev/null 2>&1
    got=$(yq -r '[.code_locations[].name] | sort | join(",")' "$f" 2>/dev/null)
    assert_equals "atlas-data,other-data" "$got" "both present"

    start_test "🔴 a crafted name cannot rewrite the document (strenv, not interpolation)"
    ( EXTEND_DIR="$cl_dir"; _write_code_location 'x", "image": "evil' ghcr.io/x/y \
        v1-ccc m.d "why" "" ) >/dev/null 2>&1
    got=$(yq -r '[.code_locations[] | select(.name != "atlas-data" and .name != "other-data")] | .[0].image' "$f" 2>/dev/null)
    assert_equals "ghcr.io/x/y" "$got" "the crafted name stayed a literal name"

    start_test "removal is the same filter without the append"
    ( EXTEND_DIR="$cl_dir"; _remove_code_location other-data ) >/dev/null 2>&1
    yq -r '[.code_locations[].name] | join(",")' "$f" 2>/dev/null | grep -q "other-data" \
        && fail_test "other-data should be gone" || pass_test
fi

# ============================================================================
# PLAN-templates-002 phase 4 — the record, requires, exports, remove
# ============================================================================
print_test_section "Phase 4: applications.yaml, requires and exports"

if ! command -v yq >/dev/null 2>&1; then
    for _ in $(seq 1 18); do skip_test "Skipping phase-4 tests: yq not installed"; done
else
    ad="$TMP/apps"; mkdir -p "$ad"
    D64="sha256:$(printf 'a%.0s' {1..64})"

    start_test "an installed application is recorded with its pin and exports"
    ( EXTEND_DIR="$ad"; _record_application atlas ghcr.io/terchris/atlas-data/uis \
        v20260909-abc1234 "$D64" "postgresql,dagster,postgrest" "atlas-data" \
        '{"api-url":"http://api-atlas.localhost"}' ) >/dev/null 2>&1
    got=$( EXTEND_DIR="$ad"; yq -r '.applications[0] | [.id,.pin,.exports["api-url"]] | join(" ")' "$ad/applications.yaml" )
    assert_equals "atlas $D64 http://api-atlas.localhost" "$got" "record shape"

    start_test "re-recording the same id converges rather than duplicating"
    ( EXTEND_DIR="$ad"; _record_application atlas ghcr.io/terchris/atlas-data/uis \
        v20260910-def5678 "$D64" "postgresql" "atlas-data" '{}' ) >/dev/null 2>&1
    got=$( yq -r '"\(.applications | length) \(.applications[0].tag)"' "$ad/applications.yaml" )
    assert_equals "1 v20260910-def5678" "$got" "one entry, new pin"

    start_test "installed / not-installed are answered from the record, not a probe"
    ( EXTEND_DIR="$ad"; _application_installed atlas ) && \
    ( EXTEND_DIR="$ad"; _application_installed nosuch ) && fail_test "nosuch must not be installed" || pass_test

    start_test "requires on a missing application REFUSES and names the install command"
    printf 'requires:\n  - application: nosuch\n' > "$TMP/req.yaml"
    err=$( EXTEND_DIR="$ad"; _check_requires "$TMP/req.yaml" atlas-frontend 2>&1 ) && fail_test "must refuse" || true
    echo "$err" | grep -q "template install nosuch" && pass_test || fail_test "should name the command: $err"

    start_test "requires never auto-installs, and says so"
    echo "$err" | grep -qi "not installed automatically" && pass_test || fail_test "should state the policy: $err"

    start_test "requires on an installed application with the export passes"
    ( EXTEND_DIR="$ad"; _record_application atlas a v1-a "$D64" "" "" '{"api-url":"http://x"}' ) >/dev/null 2>&1
    printf 'requires:\n  - application: atlas\n    provides: api-url\n' > "$TMP/req2.yaml"
    ( EXTEND_DIR="$ad"; _check_requires "$TMP/req2.yaml" atlas-frontend ) >/dev/null 2>&1 && pass_test || fail_test "should pass"

    start_test "requires on an installed application MISSING the export refuses"
    printf 'requires:\n  - application: atlas\n    provides: nope\n' > "$TMP/req3.yaml"
    ( EXTEND_DIR="$ad"; _check_requires "$TMP/req3.yaml" atlas-frontend ) >/dev/null 2>&1 \
        && fail_test "must refuse a missing export" || pass_test

    start_test "{{ requires.<id>.<key> }} resolves from the record"
    got=$( EXTEND_DIR="$ad"; _substitute_requires 'URL={{ requires.atlas.api-url }}/v1' )
    assert_equals "URL=http://x/v1" "$got" "substitution"

    # ── the remove-side refusal, and the field it reads ───────────────────────
    #
    # 🔴 The four tests above all exercise the INSTALL side of `requires`. The
    # REMOVE side reads `.requires` back out of the record — and nothing wrote
    # it, for two shipped versions, so `remove` could never refuse while the
    # CLI reference said it would. Same class as `_json_field` below: a guard
    # whose input nothing produces. These assert the ROUND TRIP, because
    # testing the reader alone is what let it through.
    rd="$TMP/apps-remove"; mkdir -p "$rd"

    start_test "🔴 the record carries requires, so the remove refusal has an input"
    ( EXTEND_DIR="$rd"; _record_application atlas-frontend ghcr.io/terchris/atlas-web/uis \
        v20260909-abc1234 "$D64" "webapp" "" '{}' "atlas" ) >/dev/null 2>&1
    got=$( yq -r '.applications[0].requires | join(",")' "$rd/applications.yaml" )
    assert_equals "atlas" "$got" "requires is recorded, not dropped"

    start_test "_applications_requiring names the dependant that blocks removal"
    got=$( EXTEND_DIR="$rd"; _applications_requiring atlas )
    assert_equals "atlas-frontend" "$got" "the dependant is found"

    start_test "an application nothing requires is not blocked"
    got=$( EXTEND_DIR="$rd"; _applications_requiring atlas-frontend )
    assert_equals "" "$got" "no dependants"

    start_test "🔴 a prefix is not a dependency (contains() does substring matching)"
    # ["atlas-data"] | contains(["atlas"]) is TRUE in both jq and yq. With
    # contains(), removing `atlas` was blocked by an application requiring
    # `atlas-data`, naming a dependant that does not depend on it.
    ( EXTEND_DIR="$rd"; _record_application data-consumer ghcr.io/terchris/dc/uis \
        v20260909-abc1234 "$D64" "" "" '{}' "atlas-data" ) >/dev/null 2>&1
    got=$( EXTEND_DIR="$rd"; _applications_requiring atlas )
    assert_equals "atlas-frontend" "$got" "only the exact dependant, not the prefix match"

    start_test "and the exact longer name is still found"
    got=$( EXTEND_DIR="$rd"; _applications_requiring atlas-data )
    assert_equals "data-consumer" "$got" "exact match on the longer name"

    # ── app_name: the field removal derives every per-app name from ──────────
    #
    # 🔴 Removal used to reconstruct per-app names from the record ID. They are
    # the same string only when --param app_name= was not used. imac installed
    # atlas as `atlast`; removing it planned to undeploy `postgrest --app atlas`
    # — the LIVE tenant serving 13 views — and named the live database in its
    # own "will NOT remove" notice (urb-agents#481). Only the prompt stopped it.
    #
    # ⚠️ The fixture could not catch this: uisfix's id and app_name were the
    # same string. These tests deliberately make them DIFFER.
    an="$TMP/apps-appname"; mkdir -p "$an"

    start_test "🔴 the record stores app_name, and it may differ from the id"
    ( EXTEND_DIR="$an"; _record_application atlas ghcr.io/terchris/atlas-data/uis \
        v20260909-853c696 "$D64" "postgresql,postgrest,dagster" "atlast-data" \
        '{"api-url":"http://api-atlast.localhost"}' "" "atlast" ) >/dev/null 2>&1
    got=$( yq -r '.applications[0] | "\(.id) \(.app_name)"' "$an/applications.yaml" )
    assert_equals "atlas atlast" "$got" "id and app_name are both recorded and differ"

    start_test "an install with no override records app_name equal to the id"
    ( EXTEND_DIR="$an"; _record_application plain a v1-a "$D64" "" "" '{}' "" "plain" ) >/dev/null 2>&1
    got=$( app_id=plain yq -r '.applications[] | select(.id == strenv(app_id)) | .app_name' "$an/applications.yaml" )
    assert_equals "plain" "$got" "the common case still records it"

    start_test "_conf_param reads app_name out of the effective-params file"
    printf 'app_name=atlast\nother=x\n' > "$TMP/eff.env"
    assert_equals "atlast" "$(_conf_param "$TMP/eff.env" app_name)" "effective param read"

    start_test "_conf_param yields empty for a key that is not there"
    assert_equals "" "$(_conf_param "$TMP/eff.env" nosuch)" "absent key"

    start_test "the install reads requires from the definition as the record's CSV"
    printf 'requires:\n  - application: atlas\n    provides: api-url\n  - application: other\n' \
        > "$TMP/req4.yaml"
    got=$(yq -r '[.requires // [] | .[] | .application // ""] | map(select(. != "")) | join(",")' \
             "$TMP/req4.yaml")
    assert_equals "atlas,other" "$got" "the call site's extraction"
fi

# ============================================================================
# _validate_template_info — the third spelling of "this is an application"
#
# `templateKind` is DERIVED in the catalogue's generator, so `install_type` is
# the only field a human authors there (dev-templates, urb-agents#479). A tenant
# who mirrors the catalogue stub writes `install_type: application` in their
# artifact and used to be refused for it.
# ============================================================================
# ============================================================================
# The registry cache must be keyed by the URL, and file:// must not be cached
#
# 🔴 The cache was ONE fixed path for whatever registry was fetched last, with
# a one-hour TTL and no override. So switching REGISTRY_URL_PRIMARY — the
# documented way to test a template before it reaches the catalogue — silently
# served the PREVIOUS registry for up to an hour, and the install resolved a pin
# the operator never asked for.
#
# Found while switching a local registry between two atlas digests: the install
# printed the old pin. It printed it, which is the only reason it was visible.
# ============================================================================
# ============================================================================
# Structural: no per-app name in `remove` may be derived from the record id
#
# The unit tests above prove app_name is RECORDED. This proves it is USED — and
# it is a grep because exercising removal needs a cluster. The defect was NINE
# separate uses of $template_id where $app_name was meant; a tenth added later
# would be just as dangerous and just as quiet.
# ============================================================================
# ============================================================================
# One application, one database — and ONE argument construction
#
# 🔴 These used to grep for the two hand-maintained copies of the argument list
# (`effective_db="${resolved_db:-$plan_database}"` in the executor,
# `v="${v:-$plan_database}"` in the printer) and they PASSED while the two
# disagreed — because I had put the plan-database computation inside the
# dry-run branch, so the printer computed it and a real install did not. The
# plan said `--database atlas-t` and the run omitted it (imac, #481 round 3).
#
# ⚠️ Those assertions were about the SHAPE of the implementation, not the
# property. They could not fail for a scoping mistake, which is the mistake
# that happened. The durable assertion is behavioural and lives in
# test-plan-equals-execution.sh; these now only check the structural facts that
# make divergence unrepresentable.
# ============================================================================
print_test_section "one application, one database"

_install_fn=$(sed -n '/^cmd_template_install()/,/^}/p' "$UIS_LIB/template.sh")

start_test "there is exactly ONE argument builder, not two constructions"
# Count INVOCATIONS, not mentions — a comment naming the function is not a call.
n=$(grep -v '^\s*#' <<< "$_install_fn" | grep -c 'mapfile -t .*_build_configure_args')
[[ "$n" == "2" ]] && pass_test \
    || fail_test "expected the printer and the executor to call it once each; found $n invocations"

start_test "🔴 the plan database is computed at function scope, not in the dry-run branch"
# The computation must appear BEFORE `if [[ "$dry_run" == true ]]`.
calc_line=$(grep -n '_plan_database "' <<< "$_install_fn" | head -1 | cut -d: -f1)
dry_line=$(grep -n 'if \[\[ "\$dry_run" == true \]\]' <<< "$_install_fn" | head -1 | cut -d: -f1)
if [[ -n "$calc_line" && -n "$dry_line" && "$calc_line" -lt "$dry_line" ]]; then
    pass_test
else
    fail_test "computed at line ${calc_line:-none}, dry-run branch at ${dry_line:-none} — inside the branch means a real install never computes it"
fi

start_test "the builder emits --database from the plan when the service declares none"
conf="$TMP/nodb.conf"; : > "$conf"
pf="$TMP/nodb.env"; printf 'app_name=x\n' > "$pf"
got=$(_build_configure_args postgrest "$conf" "$pf" myapp thedb | tr '\n' ' ')
[[ "$got" == *"--database thedb"* ]] && pass_test || fail_test "got: $got"

start_test "a service declaring its own database: still wins over the plan's"
printf 'database=mine\n' > "$conf"
got=$(_build_configure_args postgrest "$conf" "$pf" myapp thedb | tr '\n' ' ')
[[ "$got" == *"--database mine"* && "$got" != *"thedb"* ]] && pass_test || fail_test "got: $got"

start_test "--json is emitted only when the caller asks (the executor, not the printer)"
a=$(_build_configure_args postgrest "$conf" "$pf" myapp thedb | grep -c '^--json$')
b=$(_build_configure_args postgrest "$conf" "$pf" myapp thedb json | grep -c '^--json$')
[[ "$a" == "0" && "$b" == "1" ]] && pass_test || fail_test "printer=$a executor=$b"

print_test_section "remove: per-app names come from app_name, never the id"

_remove_fn=$(sed -n '/^cmd_template_remove()/,/^}/p' "$UIS_LIB/template.sh")

start_test "🔴 no per-app operation is keyed on the record id"
if grep -q -- '--app "\?\$template_id' <<< "$_remove_fn"; then
    fail_test "a per-app operation still uses the record id instead of app_name"
else
    pass_test
fi

start_test "app_name is read out of the record"
grep -q '\.app_name' <<< "$_remove_fn" && pass_test \
    || fail_test "remove does not read app_name from the record"

start_test "a record without app_name refuses --yes rather than guessing silently"
grep -q 'Refusing --yes on a record with no app_name' <<< "$_remove_fn" && pass_test \
    || fail_test "an unverifiable plan must not be auto-confirmed"

start_test "the DROP DATABASE hint quotes the identifier"
grep -q 'DROP DATABASE ' <<< "$_remove_fn" && grep -q 'DROP DATABASE \\"' <<< "$_remove_fn" && pass_test \
    || fail_test "an app_name with a hyphen needs quoting in the hint too"

print_test_section "registry cache: keyed by URL, file:// never cached"

start_test "two different registry URLs get two different cache paths"
a=$( REGISTRY_URL_PRIMARY="https://example.test/a.json"; REGISTRY_CACHE=""; _registry_cache_path )
b=$( REGISTRY_URL_PRIMARY="https://example.test/b.json"; REGISTRY_CACHE=""; _registry_cache_path )
[[ -n "$a" && -n "$b" && "$a" != "$b" ]] && pass_test \
    || fail_test "same cache path for two URLs: '$a' vs '$b'"

start_test "the same URL is stable across calls"
a1=$( REGISTRY_URL_PRIMARY="https://example.test/a.json"; REGISTRY_CACHE=""; _registry_cache_path )
assert_equals "$a" "$a1" "stable for one URL"

start_test "an explicit REGISTRY_CACHE still wins (tests pin the path)"
got=$( REGISTRY_URL_PRIMARY="https://example.test/a.json"; REGISTRY_CACHE="/tmp/pinned.json"; _registry_cache_path )
assert_equals "/tmp/pinned.json" "$got" "explicit override honoured"

start_test "🔴 a file:// registry is never cacheable"
( REGISTRY_URL_PRIMARY="file:///tmp/local-registry.json"; _registry_is_cacheable ) \
    && fail_test "a local file must be read every time, not cached" || pass_test

start_test "an https registry is cacheable"
( REGISTRY_URL_PRIMARY="https://example.test/a.json"; _registry_is_cacheable ) && pass_test \
    || fail_test "a remote registry should still be cached"

start_test "a fresh cache is not reported for a file:// source"
( REGISTRY_URL_PRIMARY="file:///tmp/local-registry.json"; _registry_cache_fresh ) \
    && fail_test "file:// must never be considered fresh" || pass_test

start_test "a missing file:// registry refuses instead of falling back to the catalogue"
err=$( REGISTRY_URL_PRIMARY="file:///nonexistent/registry.json" \
       REGISTRY_URL_FALLBACK="https://example.test/fallback.json" \
       _fetch_registry 2>&1 ) && fail_test "must refuse" || true
echo "$err" | grep -q "Refusing to fall back" && pass_test \
    || fail_test "should refuse the fallback and say so: $err"

print_test_section "definition kinds: all three spellings"

if ! command -v yq >/dev/null 2>&1; then
    for _ in 1 2 3 4; do skip_test "Skipping kind tests: yq not installed"; done
else
    kd="$TMP/kinds"; mkdir -p "$kd"
    _mk_def() { printf '%s\nprovides:\n  services:\n    - service: postgresql\n      config:\n        database: x\n' "$1" > "$kd/template-info.yaml"; }

    start_test "kind: application is accepted"
    _mk_def "kind: application"
    ( _validate_template_info "$kd/template-info.yaml" "$kd" ) >/dev/null 2>&1 && pass_test || fail_test "kind: application refused"

    start_test "install_type: stack is accepted"
    _mk_def "install_type: stack"
    ( _validate_template_info "$kd/template-info.yaml" "$kd" ) >/dev/null 2>&1 && pass_test || fail_test "install_type: stack refused"

    start_test "🔴 install_type: application is accepted (the catalogue stub's spelling)"
    _mk_def "install_type: application"
    ( _validate_template_info "$kd/template-info.yaml" "$kd" ) >/dev/null 2>&1 && pass_test || fail_test "install_type: application refused"

    start_test "a definition with neither is still refused, naming what it got"
    _mk_def "install_type: overlay"
    err=$( ( _validate_template_info "$kd/template-info.yaml" "$kd" ) 2>&1 ) && fail_test "must refuse" || true
    echo "$err" | grep -q "overlay" && pass_test || fail_test "should name the value it got: $err"
fi

# ============================================================================
# _list_uis_templates — an application entry must be VISIBLE
#
# 🔴 The filter was `.folder | startswith("uis-")`, and an application entry has
# no `folder` — it has a `source`. So `uis template list` showed only the stack
# template, and atlas would have been installable solely by someone who already
# knew its id. `info` and `install` go through `_get_template` on the id and
# were unaffected, which is why nothing failed: the broken surface was the only
# one nobody scripts.
#
# The registry already carries the right field — each category has a `context`
# of `uis` or `dct` — so these assert the join, and that an application entry
# survives even if its category is a `dct` one.
# ============================================================================
print_test_section "template list: application entries are visible"

reg="$TMP/registry.json"
cat > "$reg" <<'REGJSON'
{"categories":[
  {"id":"DEMO","context":"uis","name":"Demo Stacks"},
  {"id":"WEB_APP","context":"dct","name":"Web Application Templates"}
],
 "templates":[
  {"id":"postgresql-demo","name":"PG Demo","description":"a stack","category":"DEMO",
   "folder":"uis-stack-templates/postgresql-demo","templateKind":"stack"},
  {"id":"designsystemet","name":"DS","description":"a dct app","category":"WEB_APP",
   "folder":"templates/designsystemet","templateKind":"app"},
  {"id":"atlas","name":"Atlas","description":"an application","category":"DEMO",
   "templateKind":"application","visibility":"public",
   "source":{"artifact":"ghcr.io/terchris/atlas-data/uis","tag":"v20260909-abc1234","digest":"sha256:aa"}},
  {"id":"miscategorised","name":"Mis","description":"application in a dct category",
   "category":"WEB_APP","templateKind":"application",
   "source":{"artifact":"ghcr.io/terchris/x/uis","tag":"v20260909-abc1234","digest":"sha256:bb"}}
]}
REGJSON

# _list_uis_templates reads $REGISTRY_CACHE and calls _fetch_registry first;
# point the cache at the fixture and stub the fetch so no network is touched.
REGISTRY_CACHE="$reg"
_fetch_registry() { return 0; }

start_test "🔴 an application entry appears in the list (it has no folder)"
got=$(_list_uis_templates | cut -d'|' -f1 | sort | paste -sd, -)
assert_equals "atlas,miscategorised,postgresql-demo" "$got" "application entries listed"

start_test "a dct template is still excluded"
_list_uis_templates | cut -d'|' -f1 | grep -qx designsystemet \
    && fail_test "designsystemet is a dct template and must not be listed" || pass_test

start_test "the uis stack template is still included"
_list_uis_templates | cut -d'|' -f1 | grep -qx postgresql-demo && pass_test \
    || fail_test "the stack template must stay listed"

start_test "an application in a dct category is still visible, not silently absent"
_list_uis_templates | cut -d'|' -f1 | grep -qx miscategorised && pass_test \
    || fail_test "a miscategorised application must not vanish"

start_test "the name and description survive the join"
got=$(_list_uis_templates | grep '^atlas|')
assert_equals "atlas|Atlas|an application" "$got" "all three fields"

# ============================================================================
# _json_field — the guard that the previous guard needed
#
# `x=$(echo "$j" | jq -r '.f')` aborts under `set -e` when $j is not JSON: jq
# exits 4 and the assignment inherits it, so no branch after it runs. That
# killed the purge reporting AND _forget_application, inside the very branch
# written to stop a failure being rounded up to success (imac, urb-agents#367 —
# the fourth instance of this class, and the first to land inside a fix for the
# third).
#
# ⚠️ The first case is the one that matters: a handler that writes a human line
# to stderr before its JSON produces exactly that mixed stream when the caller
# merges the streams. Asserting on it directly is what imac said would have
# caught all four in their own domains.
# ============================================================================
print_test_section "_json_field: parsing survives non-JSON"

start_test "a clean JSON object yields the field"
assert_equals "purged" "$(_json_field '{"status":"purged"}' '.status')" "clean json"

start_test "🔴 a human line before the JSON does not abort the caller"
mixed='Removing secret from namespace postgrest...
{"status":"purged","roles_dropped":["a","b"]}'
out=$( set -e; v="$(_json_field "$mixed" '.status')"; echo "REACHED:$v" )
echo "$out" | grep -q "REACHED:" && pass_test || fail_test "caller aborted: '$out'"

start_test "the caller reaches its fallback branch instead of dying"
out=$( set -e; v="$(_json_field 'not json at all' '.status')"; \
       if [[ -z "$v" ]]; then echo "FALLBACK"; else echo "GOT:$v"; fi )
assert_equals "FALLBACK" "$out" "fallback branch is reachable"

start_test "an absent field yields empty, not the string 'null'"
assert_equals "" "$(_json_field '{"status":"ok"}' '.detail')" "absent field"

start_test "empty input yields empty and succeeds"
out=$( set -e; v="$(_json_field '' '.status')"; echo "OK:$v" )
assert_equals "OK:" "$out" "empty input"

start_test "a jq expression with a filter still works"
assert_equals "a, b" "$(_json_field '{"roles_dropped":["a","b"]}' '(.roles_dropped // []) | join(", ")')" "filter expression"

print_summary
