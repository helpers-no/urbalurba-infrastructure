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

print_summary
