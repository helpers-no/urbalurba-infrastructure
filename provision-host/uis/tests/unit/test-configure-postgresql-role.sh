#!/bin/bash
# test-configure-postgresql-role.sh — Unit tests for _pg_ensure_role
#
# The defect this covers (1.6.49): the create path ran CREATE USER
# unconditionally and swallowed its failure whenever the role already existed,
# so `DROP DATABASE <app>` without `DROP ROLE <app>` produced an install that
# reported `status: ok` while publishing a password THAT WAS NEVER SET ON THE
# ROLE. Found by ops on urb-agents#595, planning a production reinstall.
#
# ⚠️ The assertion that matters is not "it returned 0". It is "an ALTER USER
# was actually issued". A test that only checked the exit code would have
# passed against the broken version, which returned 0 too — that is exactly how
# the defect survived.
#
# No cluster needed: _pg_exec and _pg_user_exists are stubbed and every
# statement is recorded.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"

if [[ -d "/mnt/urbalurbadisk/provision-host/uis" ]]; then
    UIS_LIB="/mnt/urbalurbadisk/provision-host/uis/lib"
else
    UIS_LIB="$(cd "$SCRIPT_DIR/../../lib" && pwd)"
fi

source "$UIS_LIB/logging.sh"
source "$UIS_LIB/configure-postgresql.sh"

# ---- stubs -----------------------------------------------------------------
# STUB_ROLE_EXISTS  : "yes" | "no" | "after-create" (absent, then present)
# STUB_CREATE_RC    : exit code CREATE USER should report
# STUB_ALTER_RC     : exit code ALTER USER should report
# SQL_LOG           : file recording every statement _pg_exec was asked to run

_reset_stubs() {
    STUB_ROLE_EXISTS="no"
    STUB_CREATE_RC=0
    STUB_ALTER_RC=0
    SQL_LOG="$(mktemp)"
    # ⚠️ A FILE, not a variable. _pg_ensure_role calls _pg_exec inside a
    # command substitution, so anything the stub assigns is lost with that
    # subshell — the first version of this stub used a variable and made the
    # race case look broken when it was not.
    CREATE_FLAG="$(mktemp)"; : > "$CREATE_FLAG"
}

_pg_user_exists() {
    case "$STUB_ROLE_EXISTS" in
        yes) return 0 ;;
        no)  return 1 ;;
        after-create) [[ -s "$CREATE_FLAG" ]] && return 0 || return 1 ;;
    esac
}

_pg_exec() {
    local sql="$1"
    echo "$sql" >> "$SQL_LOG"
    case "$sql" in
        "CREATE USER"*)
            echo seen > "$CREATE_FLAG"
            [[ "$STUB_CREATE_RC" -ne 0 ]] && { echo "ERROR:  role already exists"; return "$STUB_CREATE_RC"; }
            ;;
        "ALTER USER"*)
            [[ "$STUB_ALTER_RC" -ne 0 ]] && { echo "ERROR:  permission denied"; return "$STUB_ALTER_RC"; }
            ;;
    esac
    return 0
}

# grep -c prints 0 AND exits 1 when nothing matches, so `|| echo 0` emitted
# "0\n0" and every arithmetic comparison using it was a syntax error that the
# framework reported as a plain FAIL. Swallow the status, keep the count.
_sql_count() { local n; n=$(grep -c "^$1" "$SQL_LOG" 2>/dev/null); echo "${n:-0}"; }

# ============================================================================
print_test_section "_pg_ensure_role — role absent"
# ============================================================================

start_test "creates the role and reports 'created'"
_reset_stubs; STUB_ROLE_EXISTS="no"
out=$(_pg_ensure_role atlas newpw adminpw 2>/dev/null)
[[ "$out" == "created" ]] && pass_test || fail_test "got: '$out'"

start_test "issues exactly one CREATE USER and no ALTER USER"
c=$(_sql_count "CREATE USER"); a=$(_sql_count "ALTER USER")
[[ "$c" -eq 1 && "$a" -eq 0 ]] && pass_test || fail_test "CREATE=$c ALTER=$a"

start_test "the CREATE carries the password being published"
grep -q "CREATE USER \"atlas\" WITH PASSWORD 'newpw'" "$SQL_LOG" \
    && pass_test || fail_test "statement was: $(cat "$SQL_LOG")"

# ============================================================================
print_test_section "_pg_ensure_role — role survives its database (the defect)"
# ============================================================================

start_test "reports 'reset' rather than failing"
_reset_stubs; STUB_ROLE_EXISTS="yes"
out=$(_pg_ensure_role atlas newpw adminpw 2>/dev/null)
[[ "$out" == "reset" ]] && pass_test || fail_test "got: '$out'"

start_test "🔴 AN ALTER USER IS ACTUALLY ISSUED — the whole defect"
a=$(_sql_count "ALTER USER")
[[ "$a" -eq 1 ]] && pass_test || fail_test "expected 1 ALTER USER, got $a: $(cat "$SQL_LOG")"

start_test "the ALTER sets the password that will be published"
grep -q "ALTER USER \"atlas\" WITH PASSWORD 'newpw'" "$SQL_LOG" \
    && pass_test || fail_test "statement was: $(cat "$SQL_LOG")"

start_test "no CREATE USER is attempted when the role is known to exist"
c=$(_sql_count "CREATE USER")
[[ "$c" -eq 0 ]] && pass_test || fail_test "CREATE=$c"

# ============================================================================
print_test_section "_pg_ensure_role — failures are failures"
# ============================================================================

start_test "a failing ALTER returns non-zero instead of reporting success"
_reset_stubs; STUB_ROLE_EXISTS="yes"; STUB_ALTER_RC=1
out=$(_pg_ensure_role atlas newpw adminpw 2>/dev/null); rc=$?
[[ $rc -ne 0 ]] && pass_test || fail_test "rc=$rc out='$out'"

start_test "a failing ALTER puts the psql text on stderr"
_reset_stubs; STUB_ROLE_EXISTS="yes"; STUB_ALTER_RC=1
err=$(_pg_ensure_role atlas newpw adminpw 2>&1 >/dev/null)
[[ "$err" == *"permission denied"* ]] && pass_test || fail_test "stderr was: '$err'"

start_test "a failing CREATE with the role still absent returns non-zero"
_reset_stubs; STUB_ROLE_EXISTS="no"; STUB_CREATE_RC=1
out=$(_pg_ensure_role atlas newpw adminpw 2>/dev/null); rc=$?
[[ $rc -ne 0 ]] && pass_test || fail_test "rc=$rc out='$out'"

start_test "a failing CREATE puts the psql text on stderr"
_reset_stubs; STUB_ROLE_EXISTS="no"; STUB_CREATE_RC=1
err=$(_pg_ensure_role atlas newpw adminpw 2>&1 >/dev/null)
[[ "$err" == *"role already exists"* ]] && pass_test || fail_test "stderr was: '$err'"

# ============================================================================
print_test_section "_pg_ensure_role — the race the old guard was written for"
# ============================================================================

start_test "role appearing between check and CREATE reports 'reset', not failure"
_reset_stubs; STUB_ROLE_EXISTS="after-create"; STUB_CREATE_RC=1
out=$(_pg_ensure_role atlas newpw adminpw 2>/dev/null)
[[ "$out" == "reset" ]] && pass_test || fail_test "got: '$out'"

start_test "🔴 and the password is set on the role that appeared"
a=$(_sql_count "ALTER USER")
[[ "$a" -eq 1 ]] && pass_test || fail_test "expected 1 ALTER USER, got $a: $(cat "$SQL_LOG")"

start_test "a role that appears and then refuses the ALTER is a failure"
_reset_stubs; STUB_ROLE_EXISTS="after-create"; STUB_CREATE_RC=1; STUB_ALTER_RC=1
out=$(_pg_ensure_role atlas newpw adminpw 2>/dev/null); rc=$?
[[ $rc -ne 0 ]] && pass_test || fail_test "rc=$rc out='$out'"

print_summary
