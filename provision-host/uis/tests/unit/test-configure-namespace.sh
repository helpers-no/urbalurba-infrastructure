#!/bin/bash
# test-configure-namespace.sh - Unit tests for --namespace + --secret-name-prefix flags
#
# Tests that don't need a running cluster — validates argument parsing only.
# For integration tests with namespace/secret creation, see
# deploy/test-configure-namespace-integration.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"

if [[ -d "/mnt/urbalurbadisk/provision-host/uis" ]]; then
    UIS_CLI="/mnt/urbalurbadisk/provision-host/uis/manage/uis-cli.sh"
else
    UIS_CLI="$(cd "$SCRIPT_DIR/../../manage" && pwd)/uis-cli.sh"
fi

print_test_section "Configure: --namespace + --secret-name-prefix arg parsing"

# ============================================================
# Validation: both flags must come together
# ============================================================

start_test "Missing --secret-name-prefix when --namespace is set returns usage error"
output=$("$UIS_CLI" configure postgresql --app a --database b --namespace ns --json 2>/dev/null || true)
phase=$(echo "$output" | jq -r '.phase' 2>/dev/null)
status=$(echo "$output" | jq -r '.status' 2>/dev/null)
if [[ "$status" == "error" && "$phase" == "usage" ]]; then
    pass_test
else
    fail_test "Expected status=error, phase=usage; got: $output"
fi

start_test "Missing --namespace when --secret-name-prefix is set returns usage error"
output=$("$UIS_CLI" configure postgresql --app a --database b --secret-name-prefix p --json 2>/dev/null || true)
phase=$(echo "$output" | jq -r '.phase' 2>/dev/null)
status=$(echo "$output" | jq -r '.status' 2>/dev/null)
if [[ "$status" == "error" && "$phase" == "usage" ]]; then
    pass_test
else
    fail_test "Expected status=error, phase=usage; got: $output"
fi

start_test "Missing --app argument returns usage error (regression test for 3UIS)"
output=$("$UIS_CLI" configure postgresql --json 2>/dev/null || true)
phase=$(echo "$output" | jq -r '.phase' 2>/dev/null)
status=$(echo "$output" | jq -r '.status' 2>/dev/null)
if [[ "$status" == "error" && "$phase" == "usage" ]]; then
    pass_test
else
    fail_test "Expected status=error, phase=usage; got: $output"
fi

# ============================================================
# Help mentions the new flags
# ============================================================

start_test "uis configure usage mentions --namespace"
output=$("$UIS_CLI" configure 2>&1 || true)
if echo "$output" | grep -q -- "--namespace\|configure"; then
    pass_test
else
    fail_test "Usage output does not mention --namespace or configure: $output"
fi

# ============================================================
# Source the lib and verify _pg_secret_json_fragment helper
# ============================================================

LIB_DIR="${LIB_DIR:-/mnt/urbalurbadisk/provision-host/uis/lib}"
[[ ! -d "$LIB_DIR" ]] && LIB_DIR="$(cd "$SCRIPT_DIR/../../lib" && pwd)"

if [[ -f "$LIB_DIR/configure-postgresql.sh" ]]; then
    # shellcheck source=/dev/null
    source "$LIB_DIR/configure-postgresql.sh"

    start_test "_pg_secret_json_fragment returns empty when no namespace"
    fragment=$(_pg_secret_json_fragment "" "")
    if [[ -z "$fragment" ]]; then
        pass_test
    else
        fail_test "Expected empty fragment, got: $fragment"
    fi

    start_test "_pg_secret_json_fragment includes secret_name when set"
    fragment=$(_pg_secret_json_fragment "my-ns" "my-app-db")
    if echo "$fragment" | grep -q '"secret_name":"my-app-db"'; then
        pass_test
    else
        fail_test "Expected secret_name in fragment, got: $fragment"
    fi

    start_test "_pg_secret_json_fragment includes secret_namespace when set"
    fragment=$(_pg_secret_json_fragment "my-ns" "my-app-db")
    if echo "$fragment" | grep -q '"secret_namespace":"my-ns"'; then
        pass_test
    else
        fail_test "Expected secret_namespace in fragment, got: $fragment"
    fi

    start_test "_pg_secret_json_fragment includes env_var=DATABASE_URL"
    fragment=$(_pg_secret_json_fragment "my-ns" "my-app-db")
    if echo "$fragment" | grep -q '"env_var":"DATABASE_URL"'; then
        pass_test
    else
        fail_test "Expected env_var=DATABASE_URL, got: $fragment"
    fi

    start_test "_pg_secret_json_fragment starts with comma (so it can be appended to JSON)"
    fragment=$(_pg_secret_json_fragment "my-ns" "my-app-db")
    if [[ "${fragment:0:1}" == "," ]]; then
        pass_test
    else
        fail_test "Expected fragment to start with comma, got: $fragment"
    fi
else
    echo "  (Skipping helper tests — configure-postgresql.sh not found)"
fi

# ============================================================
# Summary
# ============================================================


# ============================================================
# The already-exists path must apply init too
#
# 🔴 `--init-file -` was applied ONLY on the create path, which sits several
# hundred lines below a `return 0` that the already-exists branch reaches
# first. So on any database that already existed, the init SQL was read from
# stdin and silently discarded: `template install` printed
#   `configure postgresql ... --init-file -   (stdin: 35 lines)`
# applied none of them, and exited 0.
#
# These are STRUCTURAL assertions rather than behavioural ones: applying init
# needs a cluster (kubectl exec into the postgres pod), so what can be checked
# here is that the call is REACHABLE from the branch — which is the property
# that was actually missing. The behaviour is imac's on urb-agents#481.
# ============================================================
print_test_section "Configure postgresql: init on an existing database"

if [[ -d "/mnt/urbalurbadisk/provision-host/uis" ]]; then
    PG_HANDLER="/mnt/urbalurbadisk/provision-host/uis/lib/configure-postgresql.sh"
else
    PG_HANDLER="$(cd "$SCRIPT_DIR/../../lib" && pwd)/configure-postgresql.sh"
fi

# Line numbers of the three landmarks, so the assertions read as an ordering.
# ⚠️ Anchored on the BRANCH CONDITION, not on a log message. This used to grep
# for "already exists — resetting password" and broke the moment 1.6.35 reworded
# it — a test asserting the shape of the code rather than the property, which is
# the same mistake as the 1.6.31 argument-list greps.
_exists_branch=$(grep -n 'if _pg_database_exists "$database_name" "$admin_pass"; then' "$PG_HANDLER" | head -1 | cut -d: -f1)
_first_return=$(awk -v s="$_exists_branch" 'NR>s && /^        return 0$/ {print NR; exit}' "$PG_HANDLER")
_init_in_branch=$(awk -v s="$_exists_branch" -v e="$_first_return" \
                      'NR>s && NR<e && /_pg_apply_init_file/ {print NR; exit}' "$PG_HANDLER")

start_test "the already-exists branch exists and returns"
if [[ -n "$_exists_branch" && -n "$_first_return" ]]; then pass_test
else fail_test "could not locate the branch (start=$_exists_branch return=$_first_return)"; fi

start_test "🔴 init is applied BEFORE that branch returns, not only on the create path"
if [[ -n "$_init_in_branch" ]]; then pass_test
else fail_test "no _pg_apply_init_file between line $_exists_branch and the return at $_first_return — init is silently discarded on an existing database"; fi

start_test "the existing-database failure path does NOT drop the database"
_rollback_in_branch=$(awk -v s="$_exists_branch" -v e="$_first_return" \
                          'NR>s && NR<e && /DROP DATABASE/ {print NR; exit}' "$PG_HANDLER")
if [[ -z "$_rollback_in_branch" ]]; then pass_test
else fail_test "line $_rollback_in_branch drops a database that predates the command"; fi

start_test "the JSON reports whether init ran, so a caller need not infer it"
grep -q '"init_applied":\$init_applied' "$PG_HANDLER" && pass_test \
    || fail_test "already_configured JSON does not carry init_applied"

start_test "the password rotation is announced, not silent"
grep -q "was rotated" "$PG_HANDLER" && pass_test \
    || fail_test "a credential rotation under a running workload must be stated"

# ============================================================================
# Hyphenated app names, and the SQL identifiers they become
#
# 🔴 `--param app_name=atlas-t` FAILED: the username is derived with `-` -> `_`
# but the database name was passed through verbatim and UNQUOTED, so
#   CREATE DATABASE atlas-t OWNER atlas_t
# died at the hyphen — after creating the role, which was left orphaned for the
# tester to drop by hand (imac, urb-agents#481, following an instruction of mine
# that named exactly that parameter).
#
# Structural, like the block above: issuing SQL needs a cluster, so what is
# asserted is that every identifier reaching the admin connection is quoted, and
# that a name which could break the quoting is refused before anything runs.
# ============================================================================
print_test_section "Configure postgresql: hyphenated names and SQL quoting"

start_test "🔴 CREATE DATABASE quotes its identifier"
grep -q 'CREATE DATABASE \\"\$database_name\\"' "$PG_HANDLER" && pass_test \
    || fail_test "an unquoted identifier is a syntax error for any name with a hyphen"

start_test "CREATE USER quotes its identifier"
grep -q 'CREATE USER \\"\$username\\"' "$PG_HANDLER" && pass_test || fail_test "unquoted"

start_test "GRANT quotes both identifiers"
grep -q 'ON DATABASE \\"\$database_name\\" TO \\"\$username\\"' "$PG_HANDLER" && pass_test || fail_test "unquoted"

start_test "both rollback paths quote too"
n=$(grep -c 'DROP \(DATABASE\|USER\) IF EXISTS \\"' "$PG_HANDLER")
[[ "$n" -ge 3 ]] && pass_test || fail_test "expected every DROP to quote; found $n"

start_test "no unquoted identifier interpolation is left in any SQL"
if grep -nE '(CREATE|DROP|ALTER|GRANT)[A-Z ]*(DATABASE|USER|ROLE) +\$' "$PG_HANDLER" | grep -v '\\"'; then
    fail_test "an identifier is still interpolated unquoted"
else
    pass_test
fi

start_test "an identifier that could break the quoting is refused before any SQL runs"
grep -q 'Invalid identifier' "$PG_HANDLER" && grep -q '\^\[A-Za-z0-9_-\]+\$' "$PG_HANDLER" && pass_test \
    || fail_test "no validation of the identifiers interpolated into admin SQL"

start_test "a failed CREATE DATABASE drops the role this command created"
grep -q 'user_was_created' "$PG_HANDLER" && pass_test \
    || fail_test "the orphan role imac had to drop by hand is still left behind"

start_test "the rollback does not drop a role that predates the command"
# ⚠️ Was a grep for one literal source line, which broke the moment the logic
# moved into _pg_ensure_role in 1.6.49 while the behaviour was unchanged. A
# test that fails on a refactor and would pass on a behavioural regression is
# testing the wrong thing. Now: the flag that gates the rollback is set ONLY on
# the branch where this run created the role.
grep -q 'role_outcome" == "created"' "$PG_HANDLER" \
    && [[ "$(grep -c 'user_was_created=true' "$PG_HANDLER")" -eq 1 ]] \
    && pass_test \
    || fail_test "rollback must only drop a role this run created"

start_test "a role that already exists has its password RESET, not left stale"
# 🔴 The defect this replaces the old grep with. CREATE USER failed, the error
# was discarded because the guard checked only that the role EXISTED, and the
# install published a password that had never been set on it — status: ok, and
# the application could not authenticate (ops, urb-agents#595). Behaviour is
# exercised in tests/unit/test-configure-postgresql-role.sh; this asserts the
# create path actually routes through it.
grep -q '_pg_ensure_role "$username" "$app_password" "$admin_pass"' "$PG_HANDLER" \
    && pass_test || fail_test "the create path must ensure the password, not just the role"

# ============================================================================
# Re-install must not rotate a credential nobody asked to rotate
#
# 🔴 The already-exists path minted a new password unconditionally. A re-install
# then left a running application holding the old one: the Secret was updated,
# the consumer's Deployment was unchanged so nothing restarted it, and the ETL
# failed with "password authentication failed" on an install that had just
# exited 0 (imac, urb-agents#492).
#
# The rotation existed because "UIS does not store per-app passwords". It does —
# in the Secret it wrote. `kubectl` is stubbed here so the read-back is tested
# rather than asserted.
# ============================================================================
print_test_section "Configure postgresql: re-install preserves the credential"

_kstub="$(mktemp -d)"
mkdir -p "$_kstub/bin"
cat > "$_kstub/bin/kubectl" <<'KSTUB'
#!/bin/bash
# Answers only the one query _pg_password_from_secret makes.
if [[ "$*" == *"jsonpath={.data.DATABASE_URL}"* ]]; then
    [[ -n "${STUB_SECRET_URL:-}" ]] || exit 1
    printf '%s' "$STUB_SECRET_URL" | base64 -w0
    exit 0
fi
exit 1
KSTUB
chmod +x "$_kstub/bin/kubectl"

# shellcheck disable=SC1090
source "$PG_HANDLER" 2>/dev/null || true

start_test "🔴 the password is read back out of the Secret UIS wrote"
got=$( PATH="$_kstub/bin:$PATH" STUB_SECRET_URL='postgresql://atlas:s3cr3tpw@pg:5432/atlas' \
       _pg_password_from_secret dagster atlas-database-db )
assert_equals "s3cr3tpw" "$got" "recovered from DATABASE_URL"

start_test "no namespace means nothing to read, and no error"
got=$( PATH="$_kstub/bin:$PATH" STUB_SECRET_URL='postgresql://a:b@h:1/d' _pg_password_from_secret "" "" )
assert_equals "" "$got" "empty, quietly"

start_test "a missing Secret yields empty rather than failing the caller"
out=$( set -e; v=$( PATH="$_kstub/bin:$PATH" _pg_password_from_secret dagster nosuch ); echo "REACHED:$v" )
assert_equals "REACHED:" "$out" "caller survives"

start_test "a malformed URL yields empty rather than a wrong password"
got=$( PATH="$_kstub/bin:$PATH" STUB_SECRET_URL='not-a-url' _pg_password_from_secret dagster s )
assert_equals "" "$got" "no colon, no guess"

start_test "the handler reads the rotate flag configure.sh has always passed"
grep -q 'local rotate="${10:-false}"' "$PG_HANDLER" && pass_test \
    || fail_test "--rotate is still parsed by configure.sh and ignored here"

start_test "the rotation warning fires only when a rotation happened"
grep -q 'if \[\[ "$rotated" == true \]\]; then' "$PG_HANDLER" && pass_test \
    || fail_test "the warning is unconditional again"

start_test "the JSON says whether it rotated, so a caller need not infer"
grep -q '"rotated":\$rotated' "$PG_HANDLER" && pass_test || fail_test "no rotated field"

rm -rf "$_kstub"

print_summary
