#!/bin/bash
# test-dagster-run-ambiguous-location.sh — one job name, two code locations
#
# 🔴 `uis dagster run <job>` resolved its selector with `set_fact` INSIDE a
# loop with a `when`. That keeps the LAST match and silently discards the
# rest, so two code locations defining the same job name resolved to whichever
# Dagster happened to list last — and `repositoriesOrError` promises no
# ordering.
#
# Each code location can carry a DIFFERENT IMAGE, so the same command, from
# the same shell, could execute a different build on consecutive runs and
# report success both times.
#
# ⚠️ From outside this is indistinguishable from the stale-handle defect that
# 360-test-dagster.yml's F check reports (urb-agents#1272, #1540). The two have
# different remedies — restart the webserver vs remove a leftover location —
# so a diagnosis that confuses them sends the operator to the wrong fix.
#
# 🔵 The fix refuses rather than picks. Launching the wrong one runs code the
# operator did not choose, which is the failure this playbook keeps meeting
# from every other direction.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
PB="$REPO_ROOT/ansible/playbooks/362-dagster-run.yml"
CLI="$REPO_ROOT/provision-host/uis/manage/uis-cli.sh"

PASS=0; FAIL=0
pass() { echo -e "  Testing: $1... \033[0;32mPASS\033[0m"; ((++PASS)); }
fail() { echo -e "  Testing: $1... \033[0;31mFAIL\033[0m"; echo -e "    \033[0;31m→ $2\033[0m"; ((++FAIL)); }

echo "=== an ambiguous job name is refused, not resolved arbitrarily ==="

for f in "$PB" "$CLI"; do
    [[ -f "$f" ]] || { fail "file present" "missing: $f"; echo; echo "  Passed: $PASS  Failed: $FAIL"; exit 1; }
done

# Comments explain the defect in this very file's prose, so every assertion
# below runs against the comment-stripped playbook. Without this, the fix
# could be reverted and the comments alone would keep the tests green.
pb="$(grep -v '^[[:space:]]*#' "$PB")"

if grep -q 'ansible.builtin.fail' <<<"$pb"; then
    pass "control: the comment-stripped scan still sees tasks"
else
    fail "control: the scan sees tasks" "stripping removed everything — every check below is vacuous"
    echo ""; echo "  Passed: $PASS  Failed: $FAIL"; exit 1
fi

# --- the collection must accumulate, not overwrite -------------------------
if grep -q '_owners | default(\[\]) + \[item\]' <<<"$pb"; then
    pass "every claiming location is collected, not just the last"
else
    fail "claimants are accumulated" "a bare set_fact in the loop keeps only the last match"
fi

# 🔴 The specific regression: assigning the selector inside the looping task.
# Scan THAT TASK's body — the set_fact sits above `loop:`, so a window taken
# after `loop:` inspects nothing and passes whatever the code says.
_collect="$(sed -n '/Collect every location/,/A selector must have been resolved/p' <<<"$pb")"
if grep -qE '^\s*_sel_(repo|loc):' <<<"$_collect"; then
    fail "the selector is not assigned inside the looping task" "last-match-wins is back"
else
    pass "the selector is not assigned inside the looping task"
fi

# --- the refusal ------------------------------------------------------------
if grep -q 'Refuse an ambiguous job name' <<<"$pb"; then
    pass "there is a task whose job is to refuse ambiguity"
else
    fail "an ambiguity refusal exists" "two locations would resolve silently"
fi

# It must fire on >1 AND only when no --location was given. Asserting one
# without the other would pass on a refusal that ignores the escape hatch.
# The `when:` sits after a long msg block, so take the whole task rather than
# a fixed number of lines — a window that stops short would assert nothing.
_guard="$(sed -n '/Refuse an ambiguous job name/,/Honour --location/p' <<<"$pb")"
_n=0
grep -q '_owners | length) > 1' <<<"$_guard" && _n=$((_n+1))
grep -q "_location | default('') | length) == 0" <<<"$_guard" && _n=$((_n+1))
if [[ "$_n" -eq 2 ]]; then
    pass "the refusal fires on more than one owner, and only without --location"
else
    fail "the refusal is guarded on both conditions" "only $_n of 2 — it would refuse always, or never"
fi

# A refusal that does not say WHICH locations leaves the operator nowhere.
if grep -q 'for o in _owners' <<<"$pb"; then
    pass "the refusal names the competing locations"
else
    fail "the refusal names the locations" "'it is ambiguous' with no names is not actionable"
fi

# --- the escape hatch -------------------------------------------------------
if grep -q "selectattr('location.name', 'equalto', _location)" <<<"$pb"; then
    pass "--location filters the owners to the one named"
else
    fail "--location filters the owners" "the flag would be accepted and ignored"
fi

# ⚠️ A --location that matches nothing must fail, not fall through to `first`
# on an empty list, which renders an empty selector and a confusing GraphQL
# error about the job not existing.
if grep -q "No code location named" <<<"$pb"; then
    pass "a --location that claims nothing is refused by name"
else
    fail "an unmatched --location is refused" "an empty owners list would reach `first`"
fi

# --- the CLI end of the wire ------------------------------------------------
# Both halves: the flag must be PARSED and it must be PASSED. Asserting only
# the parse would pass on a flag that is accepted and dropped.
_n=0
grep -q -- '--location) location=' "$CLI" && _n=$((_n+1))
grep -q -- '-e "location=\$location"' "$CLI" && _n=$((_n+1))
if [[ "$_n" -eq 2 ]]; then
    pass "the CLI parses --location and passes it to the playbook"
else
    fail "--location is wired end to end" "only $_n of 2 — parsed and dropped, or passed and unparsed"
fi

if grep -q "_location: \"{{ location | default('') }}\"" "$PB"; then
    pass "the playbook maps the extra-var into _location"
else
    fail "the playbook reads the extra-var" "_location would be undefined on every run"
fi

echo ""
echo "  Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
