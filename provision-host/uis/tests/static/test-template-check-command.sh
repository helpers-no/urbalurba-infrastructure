#!/bin/bash
# test-template-check-command.sh — the command that asks whether an
# application's output still reflects its input.
#
# 🔴 WHY IT EXISTS. atlas served a DELETED company over its public API for 7.5
# hours while every operator-visible signal was green: feed SUCCESS every 30
# minutes, exit_code 0, backlog 0, watermark advancing, API returning 200, all 5
# instigators RUNNING. The transform had failed 16 consecutive times; 119 changes
# were unapplied, 22 of them deletions; the register was 8.4 hours stale.
#
# It was found because a human asked a question.
#
# ⚠️ Every check in this platform asks "is this component healthy". None asked
# "does the output reflect the input" — including `uis verify dagster`, which
# passes whether automation is RUNNING or STOPPED.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$(cd "$SCRIPT_DIR/../../lib" && pwd)/template.sh"
CLI="$(cd "$SCRIPT_DIR/../../manage" && pwd)/uis-cli.sh"

PASS=0; FAIL=0
pass() { echo -e "  Testing: $1... \033[0;32mPASS\033[0m"; ((++PASS)); }
fail() { echo -e "  Testing: $1... \033[0;31mFAIL\033[0m"; echo -e "    \033[0;31m→ $2\033[0m"; ((++FAIL)); }

echo "=== uis template check ==="

_code="$(grep -v '^[[:space:]]*#' "$LIB")"

grep -q '^cmd_template_check()' "$LIB" && pass "the command exists" \
    || fail "the command exists" "no cmd_template_check"

grep -qE '^\s+check\)' <<<"$_code" && pass "it is dispatched from the template verb" \
    || fail "it is dispatched" "declared but unreachable — the guard that cannot fire, again"

# ── the grammar decision must be RECORDED, not merely made ────────────────────
# Terje handed the grammar back rather than arbitrating it, which makes
# "deliberate" a thing to discharge and evidence, not merely to assert.
_fn="$(sed -n '/^# Command: uis template check/,/^cmd_template_check() {/p' "$LIB")"
if grep -q 'WHY `check` AND NOT `status`' <<<"$_fn"; then
    pass "🔴 the naming decision is recorded beside the verb"
else
    fail "🔴 the naming decision is recorded beside the verb" \
         "the next person finds the outcome and not the reasoning"
fi
if grep -q 'Rejected alternatives' <<<"$_fn"; then
    pass "the rejected alternatives are named"
else
    fail "the rejected alternatives are named" "a choice without its alternatives reads as the only option"
fi

# ── it must NOT reuse the liveness vocabulary ─────────────────────────────────
# `status` means "is it up" in 4 places; `verify` means "does the component
# work" in ~6. The incident is liveness-green-while-data-wrong, so reusing
# either word gives the same name to the claim that was true and the claim that
# was false.
if grep -qE '^\s+(status|verify)\)' <<<"$(sed -n '/^run_template() {/,/^}/p' "$LIB")"; then
    fail "it does not reuse status/verify under template" \
         "the conflation is the defect, not a naming inconvenience"
else
    pass "it does not reuse status/verify under template"
fi

# ── an application that declares nothing must say so ──────────────────────────
# 🔴 ops-dev held this as the half that outlives the command: if the absence is
# silent, the command becomes something atlas has and nobody else does.
if grep -q 'declares no check command' <<<"$_code"; then
    pass "🔴 an application declaring nothing SAYS so"
else
    fail "🔴 an application declaring nothing SAYS so" \
         "silence makes this atlas-only and the next tenant is found by a human asking"
fi
if grep -q 'cannot tell you whether its output reflects' <<<"$_code"; then
    pass "and says what that means for the operator"
else
    fail "and says what that means" "an absent verb is not a fact an operator can act on"
fi

# ── could-not-check is distinguishable from checked-and-bad ───────────────────
_ret2=$(grep -c 'return 2' <<<"$(sed -n '/^cmd_template_check() {/,/^}/p' "$LIB")")
[[ "$_ret2" -ge 2 ]] && pass "🔴 'could not check' exits 2, distinct from a failed check" \
    || fail "'could not check' exits 2" "only $_ret2 such paths; a script cannot tell them apart"

if grep -q 'NOTHING WAS CHECKED' <<<"$_code"; then
    pass "a missing pod is not reported as a clean result"
else
    fail "a missing pod is not reported as a clean result" \
         "no pod means nothing was asked — the could-not-look rule"
fi

# ── an unsupported target is refused, not guessed ─────────────────────────────
if grep -q 'Refusing rather than guessing where to run it' <<<"$_code"; then
    pass "an unsupported check.in is refused rather than guessed"
else
    fail "an unsupported check.in is refused" "guessing where to run a tenant's script is worse than refusing"
fi

# ── the application owns the verdict ──────────────────────────────────────────
if grep -q 'exit code is the verdict' <<<"$(sed -n '/^cmd_template_check() {/,/^}/p' "$LIB")"; then
    pass "the application's exit code is passed through"
else
    fail "the application's exit code is passed through" \
         "UIS reads nothing from operational content and should interpret nothing here either"
fi

# ── discoverable on both surfaces ─────────────────────────────────────────────
grep -q 'template check <id>' "$CLI" && pass "listed in the top-level help" \
    || fail "listed in the top-level help" "a command absent from help does not exist"
grep -q 'check <id>' <<<"$_code" && pass "listed in the template subcommand help" \
    || fail "listed in the subcommand help" ""

# ── the four states, and conflating any two is the defect ─────────────────────
# imac's addition to my own design point (ops-dev, #928):
#   1 declared, healthy      2 declared, unhealthy
#   3 declared NOTHING       4 COULD NOT BE ASKED
# ⚠️ "3 of 4 healthy" silently drops what could not be asked. State 4 must be its
# own answer, not a rounding of 1 or 2.
_body="$(sed -n '/^cmd_template_check() {/,/^}/p' "$LIB")"

if grep -q 'COULD NOT BE ASKED' <<<"$_body"; then
    pass "🔴 state 4 is named, not folded into pass or fail"
else
    fail "🔴 state 4 is named" "an application that could not be asked is neither healthy nor broken"
fi

# 🔴 Measured by imac against the real artifact: atlas's script is in its REPO
# and not its IMAGE, and psql is absent from the image. Run as declared it
# printed a header of BLANK VALUES and exited 0.
if grep -q 'command -v' <<<"$_body" && grep -q 'test -x' <<<"$_body"; then
    pass "🔴 the command is pre-flighted before it is trusted"
else
    fail "🔴 the command is pre-flighted"          "an absent script exits 127 and a missing dependency prints blanks and exits 0"
fi

if grep -q 'rc" -eq 127' <<<"$_body"; then
    pass "127 is treated as could-not-be-asked, not as a failed check"
else
    fail "127 is treated as could-not-be-asked"          "'something it needed did not exist' is the blank-values case one level down"
fi

# 🔵 atlas's point, turned on the platform half: "exits 0" is not "the output
# reflects the input", and a criterion that accepts the former is satisfied by a
# stub. UIS cannot judge the numbers; it can refuse to claim it did.
if grep -q 'relayed this; it did not verify it' <<<"$_body"; then
    pass "🔴 exit 0 is reported as RELAYED, not as verified"
else
    fail "🔴 exit 0 is reported as relayed, not verified"          "claiming verification the platform did not perform is the hole moved, not closed"
fi

if grep -qE 'must ship IN THE IMAGE' <<<"$_body"; then
    pass "the refusal says what the application must change"
else
    fail "the refusal says what the application must change" "a refusal without a remedy is an obstacle"
fi

echo ""
echo "  Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
