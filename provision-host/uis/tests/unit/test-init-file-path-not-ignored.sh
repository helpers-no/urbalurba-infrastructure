#!/bin/bash
# test-init-file-path-not-ignored.sh - `--init-file <path>` must never be silently dropped
#
# 🔴 Until 1.6.176 only "-" had a branch. A path was parsed, forwarded through
# configure_service, compared against "-" twice, matched neither, and was never
# read — so `uis configure postgresql --app x --init-file schema.sql` created a
# database with NO TABLES and reported success.
#
# That form is the one the usage text advertised, the one dev-templates
# documents, and the one urb-agents-console's own init-database.sql names in
# its header. Every copy of the documented command was a silent no-op.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"

if [[ -d "/mnt/urbalurbadisk/provision-host/uis" ]]; then
    ROOT="/mnt/urbalurbadisk"
else
    ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
fi
UIS_CLI="$ROOT/provision-host/uis/manage/uis-cli.sh"
PG_LIB="$ROOT/provision-host/uis/lib/configure-postgresql.sh"

print_test_section "configure --init-file: a path is read, or refused — never ignored"

TMP="$(create_test_dir)"
trap 'cleanup_test_dir "$TMP"' EXIT
printf 'CREATE TABLE IF NOT EXISTS t (id int);\n' > "$TMP/schema.sql"

_cfg() {  # runs configure; sets OUT and RC (no subshell — see #1732's harness bug)
    OUT="$("$UIS_CLI" configure postgresql --app demo --namespace demo \
        --secret-name-prefix demo "$@" 2>&1)"
    RC=$?
}

# ── an unreadable path must stop the command, not proceed ──

start_test "A path that cannot be read stops the command — the refusal is the last output"
_cfg --init-file "$TMP/does-not-exist.sql"
last="$(echo "$OUT" | grep -v '^[[:space:]]*$' | tail -1)"
if [[ $RC -ne 0 ]] && echo "$last" | grep -qF "under /mnt/urbalurbadisk"; then
    pass_test
else
    fail_test "Command continued past the refusal; rc=$RC, last line: $last"
fi

start_test "The refusal names the file it could not read"
_cfg --init-file "$TMP/does-not-exist.sql"
if echo "$OUT" | grep -qF "does-not-exist.sql"; then
    pass_test
else
    fail_test "Refusal does not name the file: $OUT"
fi

start_test "The refusal explains the container boundary rather than just failing"
_cfg --init-file "$TMP/does-not-exist.sql"
if echo "$OUT" | grep -qiF "cannot see files on your machine"; then
    pass_test
else
    fail_test "No explanation of why the path is unreadable: $OUT"
fi

start_test "The refusal gives the working alternative (pipe into --init-file -)"
_cfg --init-file "$TMP/does-not-exist.sql"
if echo "$OUT" | grep -qF -- "--init-file -" && echo "$OUT" | grep -qiE "cat |pipe"; then
    pass_test
else
    fail_test "No pipe form offered: $OUT"
fi

start_test "The JSON surface reports phase=init_file, not a bare failure"
OUT="$("$UIS_CLI" configure postgresql --app demo --namespace demo \
    --secret-name-prefix demo --init-file "$TMP/does-not-exist.sql" --json 2>/dev/null)"
phase=$(echo "$OUT" | jq -r '.phase' 2>/dev/null)
status=$(echo "$OUT" | jq -r '.status' 2>/dev/null)
if [[ "$status" == "error" && "$phase" == "init_file" ]]; then
    pass_test
else
    fail_test "Expected status=error phase=init_file; got: $OUT"
fi

start_test "A readable path gets past validation (it is not refused for being a path)"
# It will fail later for want of a cluster; what matters is that it does NOT
# fail with the init-file refusal.
_cfg --init-file "$TMP/schema.sql"
if echo "$OUT" | grep -qi "Cannot read init file"; then
    fail_test "A readable path was refused: $OUT"
else
    pass_test
fi

# ── the handler must actually read what it was given ──

start_test "The handler routes both '-' and a path through one applier"
if grep -q "_pg_run_init()" "$PG_LIB"; then
    pass_test
else
    fail_test "No _pg_run_init helper in $PG_LIB"
fi

start_test "_pg_run_init redirects a file into the applier"
fn="$(awk '/^_pg_run_init\(\) \{/,/^\}/' "$PG_LIB")"
if echo "$fn" | grep -qF '< "$src"'; then
    pass_test
else
    fail_test "_pg_run_init never opens the file: $fn"
fi

start_test "_pg_run_init still supports stdin"
if echo "$fn" | grep -qF '"$src" == "-"'; then
    pass_test
else
    fail_test "_pg_run_init dropped the stdin path: $fn"
fi

start_test "🔴 Neither call site gates on '-' any more — that was the whole defect"
# Strip comments: the note explaining the fix quotes the old comparison.
code="$(grep -v '^[[:space:]]*#' "$PG_LIB")"
n_dash=$(echo "$code" | grep -c 'if \[\[ "\$init_file" == "-" \]\]')
n_nonempty=$(echo "$code" | grep -c 'if \[\[ -n "\$init_file" \]\]')
if [[ "$n_dash" -eq 0 && "$n_nonempty" -eq 2 ]]; then
    pass_test
else
    fail_test "Expected 0 '-' gates and 2 non-empty gates; found $n_dash and $n_nonempty"
fi

start_test "Both call sites go through _pg_run_init, not the raw applier"
n_run=$(echo "$code" | grep -c '_pg_run_init "\$database_name"')
if [[ "$n_run" -eq 2 ]]; then
    pass_test
else
    fail_test "Only $n_run of 2 call sites use _pg_run_init"
fi

start_test "The usage text no longer advertises a bare <path>"
usage="$("$UIS_CLI" configure --help 2>&1 || true)"
short="$("$UIS_CLI" configure 2>&1 || true)"
n=0
echo "$usage" | grep -qF -- '--init-file <path|->' && n=$((n+1))
echo "$usage" | grep -qi 'inside the container'   && n=$((n+1))
# the short usage line hid the path form entirely
echo "$short" | grep -qF -- '[--init-file <path|->]' && n=$((n+1))
if [[ $n -eq 3 ]]; then
    pass_test
else
    fail_test "only $n of 3 — usage does not describe both forms"
fi

print_summary
