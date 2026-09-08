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

print_summary
