#!/bin/bash
# test-framework.sh - UIS Test Framework
#
# Provides assertion functions and test runners for UIS tests.
#
# Usage:
#   source /path/to/test-framework.sh
#   start_test "My test"
#   assert_equals "expected" "actual" && pass_test || fail_test   # explicit
#   assert_equals "expected" "actual" "message"                    # self-reporting
#   print_summary
#
# Both assertion forms are correct and both count exactly once: assertions
# report their own success, and pass/fail/skip are idempotent per test.
# ⚠️ Every started test MUST report an outcome — print_summary fails the suite
# on any that does not, rather than counting it as neither.

# Colors
readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_YELLOW='\033[0;33m'
readonly TEST_BOLD='\033[1m'
readonly TEST_NC='\033[0m'

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Current test name (for error messages)
CURRENT_TEST=""

# 🔴 Whether the current test has reported an outcome yet.
#
# Two call-site forms are both in wide use and both correct:
#
#   assert_equals "$a" "$b" && pass_test || fail_test "..."   # explicit
#   assert_equals "$a" "$b" "message"                         # self-reporting
#
# The second form used to count NOTHING on success: the assertion returned 0
# and no counter moved. 28 of this repository's 68 template tests were in that
# shape, so the summary read "Total: 68  Passed: 40  Failed: 0" — a third of
# the suite neither passing nor failing, and the verdict line still saying ALL
# TESTS PASSED. Failures were reported (the asserts call fail_test themselves),
# so the verdict was never wrong; the COUNT was, which is worse in the one way
# that matters here — a number nobody can reconcile is a number nobody checks.
#
# The fix: every assertion now reports its own success, and pass/fail/skip are
# idempotent per test, so the explicit form does not double-count. print_summary
# then reconciles run against passed+failed+skipped and FAILS on a gap, because
# a started test that never reported an outcome is a broken test, not a pass.
CURRENT_TEST_RESOLVED=0

# ============================================================================
# Test Runner Functions
# ============================================================================

# Start a test
# Usage: start_test "Test description"
start_test() {
    CURRENT_TEST="$1"
    TESTS_RUN=$((TESTS_RUN + 1))
    CURRENT_TEST_RESOLVED=0
    echo -n "  Testing: $1... "
}

# Mark current test as passed. Idempotent: the first outcome for a test wins,
# so `assert_x && pass_test` counts once, not twice.
pass_test() {
    [[ "$CURRENT_TEST_RESOLVED" == "1" ]] && return 0
    CURRENT_TEST_RESOLVED=1
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${TEST_GREEN}PASS${TEST_NC}"
}

# Mark current test as failed
# Usage: fail_test [error_message]
#
# ⚠️ A failure after an outcome is already recorded still PRINTS — silence there
# would hide a real assertion — but does not move the counters twice.
fail_test() {
    if [[ "$CURRENT_TEST_RESOLVED" == "1" ]]; then
        [[ -n "$1" ]] && echo -e "    ${TEST_RED}→ (also) $1${TEST_NC}"
        return 0
    fi
    CURRENT_TEST_RESOLVED=1
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${TEST_RED}FAIL${TEST_NC}"
    if [[ -n "$1" ]]; then
        echo -e "    ${TEST_RED}→ $1${TEST_NC}"
    fi
}

# Skip a test
# Usage: skip_test [reason]
#
# Callable with or without a preceding start_test — the skip loops that stand in
# for a whole yq-dependent block use it bare — so it increments TESTS_RUN itself
# in that case, keeping the summary's arithmetic reconcilable either way.
skip_test() {
    if [[ "$CURRENT_TEST_RESOLVED" == "1" || -z "$CURRENT_TEST" ]]; then
        TESTS_RUN=$((TESTS_RUN + 1))
    fi
    CURRENT_TEST_RESOLVED=1
    TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
    echo -e "${TEST_YELLOW}SKIP${TEST_NC}"
    if [[ -n "$1" ]]; then
        echo -e "    ${TEST_YELLOW}→ $1${TEST_NC}"
    fi
}

# Print test summary
# Returns: 0 if all tests passed, 1 if any failed
print_summary() {
    echo ""
    echo "────────────────────────────────────"
    echo "Total: $TESTS_RUN  Passed: $TESTS_PASSED  Failed: $TESTS_FAILED  Skipped: $TESTS_SKIPPED"

    # 🔴 Reconcile. A test that started and reported no outcome is a broken
    # test, and a suite that cannot account for its own tests must not report
    # green — that is the same rounding-up this repository has spent a week
    # removing from `uis` itself.
    local accounted=$((TESTS_PASSED + TESTS_FAILED + TESTS_SKIPPED))
    if [[ "$accounted" -ne "$TESTS_RUN" ]]; then
        echo -e "${TEST_RED}UNACCOUNTED: $((TESTS_RUN - accounted)) test(s) started and reported no outcome${TEST_NC}"
        echo "  Each needs pass_test, fail_test, skip_test, or a self-reporting assert_*."
        return 1
    fi

    if [[ "$TESTS_FAILED" -eq 0 ]]; then
        echo -e "${TEST_GREEN}ALL TESTS PASSED${TEST_NC}"
        return 0
    else
        echo -e "${TEST_RED}SOME TESTS FAILED${TEST_NC}"
        return 1
    fi
}

# Print a section header in tests
# Usage: print_test_section "Section Name"
print_test_section() {
    echo ""
    echo -e "${TEST_BOLD}=== $* ===${TEST_NC}"
}

# ============================================================================
# Assertion Functions
# ============================================================================

# Assert two values are equal
# Usage: assert_equals "expected" "actual" [message]
# Returns: 0 if equal, 1 if not
assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="${3:-Expected '$expected', got '$actual'}"

    if [[ "$expected" == "$actual" ]]; then
        pass_test; return 0
    else
        fail_test "$message"
        return 1
    fi
}

# Assert two values are not equal
# Usage: assert_not_equals "unexpected" "actual" [message]
assert_not_equals() {
    local unexpected="$1"
    local actual="$2"
    local message="${3:-Values should not be equal: '$actual'}"

    if [[ "$unexpected" != "$actual" ]]; then
        pass_test; return 0
    else
        fail_test "$message"
        return 1
    fi
}

# Assert a value is not empty
# Usage: assert_not_empty "value" [message]
assert_not_empty() {
    local value="$1"
    local message="${2:-Value is empty}"

    if [[ -n "$value" ]]; then
        pass_test; return 0
    else
        fail_test "$message"
        return 1
    fi
}

# Assert a value is empty
# Usage: assert_empty "value" [message]
assert_empty() {
    local value="$1"
    local message="${2:-Value should be empty but was: '$value'}"

    if [[ -z "$value" ]]; then
        pass_test; return 0
    else
        fail_test "$message"
        return 1
    fi
}

# Assert a command succeeds (exit code 0)
# Usage: assert_success command [args...]
assert_success() {
    if "$@" >/dev/null 2>&1; then
        pass_test; return 0
    else
        fail_test "Command failed: $*"
        return 1
    fi
}

# Assert a command fails (exit code non-zero)
# Usage: assert_failure command [args...]
assert_failure() {
    if "$@" >/dev/null 2>&1; then
        fail_test "Command should have failed: $*"
        return 1
    else
        pass_test; return 0
    fi
}

# Assert a file exists
# Usage: assert_file_exists "/path/to/file" [message]
assert_file_exists() {
    local file="$1"
    local message="${2:-File does not exist: $file}"

    if [[ -f "$file" ]]; then
        pass_test; return 0
    else
        fail_test "$message"
        return 1
    fi
}

# Assert a directory exists
# Usage: assert_dir_exists "/path/to/dir" [message]
assert_dir_exists() {
    local dir="$1"
    local message="${2:-Directory does not exist: $dir}"

    if [[ -d "$dir" ]]; then
        pass_test; return 0
    else
        fail_test "$message"
        return 1
    fi
}

# Assert a file is executable
# Usage: assert_executable "/path/to/file" [message]
assert_executable() {
    local file="$1"
    local message="${2:-File is not executable: $file}"

    if [[ -x "$file" ]]; then
        pass_test; return 0
    else
        fail_test "$message"
        return 1
    fi
}

# Assert a string contains a substring
# Usage: assert_contains "haystack" "needle" [message]
assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-String does not contain '$needle'}"

    if [[ "$haystack" == *"$needle"* ]]; then
        pass_test; return 0
    else
        fail_test "$message"
        return 1
    fi
}

# Assert a string matches a regex
# Usage: assert_matches "string" "regex" [message]
assert_matches() {
    local string="$1"
    local regex="$2"
    local message="${3:-String does not match pattern '$regex'}"

    if [[ "$string" =~ $regex ]]; then
        pass_test; return 0
    else
        fail_test "$message"
        return 1
    fi
}

# Assert a function is defined
# Usage: assert_function_exists "function_name" [message]
assert_function_exists() {
    local func="$1"
    local message="${2:-Function not defined: $func}"

    if type "$func" &>/dev/null; then
        pass_test; return 0
    else
        fail_test "$message"
        return 1
    fi
}

# Assert a variable is defined
# Usage: assert_var_defined "VAR_NAME" [message]
assert_var_defined() {
    local var="$1"
    local message="${2:-Variable not defined: $var}"

    # Use declare -p to check if variable exists (works for arrays too)
    if declare -p "$var" &>/dev/null; then
        pass_test; return 0
    else
        fail_test "$message"
        return 1
    fi
}

# ============================================================================
# Test Helpers
# ============================================================================

# Create a temporary directory for test fixtures
# Usage: TEST_DIR=$(create_test_dir)
create_test_dir() {
    mktemp -d "${TMPDIR:-/tmp}/uis-test.XXXXXX"
}

# Clean up a test directory
# Usage: cleanup_test_dir "$TEST_DIR"
cleanup_test_dir() {
    local dir="$1"
    [[ -d "$dir" && "$dir" == *"uis-test."* ]] && rm -rf "$dir"
}

# Run a test in a subshell to isolate failures
# Usage: run_isolated test_function
run_isolated() {
    local func="$1"
    (
        set -e
        "$func"
    )
}
