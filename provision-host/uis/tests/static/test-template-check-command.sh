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
# ⚠️ Asserts the CODE, not the comment. I restored this wording as a comment
# and the comment-stripped scan correctly refused to count it — a test declining
# to be satisfied by prose about the behaviour, which is the right answer.
if grep -q 'which UIS cannot run' <<<"$_code"; then
    pass "an unsupported check.in is refused rather than guessed"
else
    fail "an unsupported check.in is refused" "guessing where to run a tenant's script is worse than refusing"
fi

# ── the application owns the verdict ──────────────────────────────────────────
# The verdict is the application's: rc is captured from the exec and mapped,
# never re-judged. Checked as behaviour rather than as a sentence about it.
# The verdict is the application's: rc is captured and MAPPED by the contract,
# never re-judged. The literal string this used to match was replaced when the
# contract landed — assert the mapping instead.
if grep -q 'outside the check contract' <<<"$_code" && grep -qE 'rc=\$\?' <<<"$_code"; then
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
# ⚠️ The logic lives in `_check_state` now, shared by both forms. Scanning only
# `cmd_template_check` looked in the old place and reported five behaviours
# missing that were present — a test measuring the wrong object, which is the
# thing this suite keeps catching in me.
# ⚠️ COMMENT-STRIPPED. This was not, and my own comment explaining the
# `|| pod=""` defect satisfied the assertion forbidding it — AND defeated its
# negative control, which passed against the reintroduced bug. Eighth time today
# a scan matched prose about the thing instead of the thing, and the first where
# it disarmed the control as well as the check.
# ⚠️ BRACES. Without them the pipe binds to the LAST sed only, so two of the
# three functions kept their comments and the strip silently did a third of its
# job — which is how the `|| pod=""` assertion still failed against code that
# does not contain it.
_body="$( { sed -n '/^_check_state() {/,/^}/p' "$LIB"
            sed -n '/^cmd_template_check() {/,/^}/p' "$LIB"
            sed -n '/^cmd_template_check_all() {/,/^}/p' "$LIB"; } | grep -v '^[[:space:]]*#')"

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

if grep -qE '127\)' <<<"$_body"; then
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

# ── the LISTING: F1, F3, G1 ───────────────────────────────────────────────────
# 🔴 `uis template check <id>` requires someone to already suspect that
# application. Nobody suspected atlas — that is why it ran 7.5 hours behind five
# green signals (ops-dev, #935).
# ⚠️ Comment-stripped. Every assertion below searches for a token that the
# comments ALSO contain, because the comments explain the forbidden thing by
# quoting it. The "no x-of-y summary" check failed against correct code on its
# first run for exactly that. It is the seventh time today a scan matched prose
# about the thing instead of the thing, and I am now stripping by default rather
# than after a failure.
_all="$(sed -n '/^cmd_template_check_all() {/,/^}/p' "$LIB" | grep -v '^[[:space:]]*#')"

grep -q '^cmd_template_check_all()' "$LIB" && pass "🔴 a listing form exists"     || fail "🔴 a listing form exists" "the per-application form cannot find what nobody suspects"

if grep -q 'cmd_template_check_all; return' <<<"$(sed -n '/^cmd_template_check() {/,/^}/p' "$LIB")"; then
    pass "no id runs the listing"
else
    fail "no id runs the listing" "the discoverable form must be the bare command"
fi

# F1 — an application that declares no status is NAMED, not omitted.
grep -q 'declares no check' <<<"$_all" && pass "F1: an application declaring nothing is named"     || fail "F1: an application declaring nothing is named" "omitting it is how the gap stays invisible"

# F3 — every state named with its count, never "3 of 4 healthy".
if grep -q 'declare no check ·' <<<"$_all" && grep -q 'could not be asked' <<<"$_all"; then
    pass "F3: every state is named with its count"
else
    fail "F3: every state is named with its count"          "'3 of 4 healthy' silently drops what could not be asked"
fi
# ⚠️ Matches a COMPUTED x-of-y too. The first version required literal digits
# (`[0-9]+ of [0-9]+`), so injecting `$n_h of 4 healthy` — the realistic
# regression — sailed past it. The negative control caught that the assertion
# was weaker than the thing it guards.
if grep -qE '(\$\{?[A-Za-z_]+\}?|[0-9]+) of ' <<<"$_all"; then
    fail "F3: no x-of-y summary" "that arithmetic is the thing F3 forbids"
else
    pass "F3: no x-of-y summary"
fi

# G1 — a stopped application still produces a line, with a reason.
_state_all="$(sed -n '/^_check_state() {/,/^}/p' "$LIB")"
_state="$(grep -v '^[[:space:]]*#' <<<"$_state_all")"
if grep -q "no running pod for code location" <<<"$_state"; then
    pass "G1: a stopped application yields a reason, not a vanishing"
else
    fail "G1: a stopped application yields a reason" "it must not drop out of the list nor abort the run"
fi

# 🔴 atlas's warning: "a bug wearing a connectivity failure's clothes". An
# aggregate that maps ANY exception to state 4 turns a defect in UIS into the
# honest outcome and it is never looked at.
if grep -q 'uis-error' <<<"$_body" && grep -q 'UIS FAILED TO EVAL' <<<"$_all"; then
    pass "🔴 a UIS evaluation failure is its own state, not state 4"
else
    fail "🔴 a UIS evaluation failure is its own state"          "a defect here must not present as 'could not be asked'"
fi
if grep -q 'cannot hide inside' <<<"$_all"; then
    pass "and the output says why it is reported separately"
else
    fail "and the output says why" ""
fi

# ⚠️ no-check and could-not-ask are different fixes by different people.
if grep -q 'NOT could-not-ask' <<<"$_state_all"; then
    pass "an authoring gap is not folded into a runtime failure"
else
    fail "an authoring gap is not folded into a runtime failure"          "they need different fixes from different people"
fi

# ── a broken kubectl is not an absent pod ────────────────────────────────────
# 🔴 My fix for the errexit abort created a confident wrong answer: `|| pod=""`
# discarded kubectl's status, so a kubectl exiting 9 produced "no running pod
# for code location 'atlas-data'" — specific, confident and false (ops-dev,
# #939). atlas's sentence one layer further in: a bug wearing a connectivity
# failure's clothes.
if grep -q 'items\[\*\]' <<<"$_body"; then
    pass "🔴 the pod query distinguishes an empty match from a failure"
else
    fail "🔴 the pod query distinguishes empty from failure" \
         "{.items[0]…} returns 1 for BOTH, so rc carries no information"
fi

if grep -q 'cannot tell whether a pod exists' <<<"$_body"; then
    pass "a failing kubectl says so instead of naming a missing pod"
else
    fail "a failing kubectl says so" "'no running pod' is a claim UIS cannot make when kubectl failed"
fi

if grep -q '|| pod=""' <<<"$_body"; then
    fail "kubectl's status is not discarded" "|| pod=\"\" throws away the only signal that separates the two"
else
    pass "kubectl's status is not discarded"
fi

# ⚠️ Same conflation on the probe: `!` on a kubectl exec cannot tell "not in the
# image" from "could not reach the pod".
if grep -q 'PRESENT' <<<"$_body" && grep -q 'ABSENT' <<<"$_body"; then
    pass "the probe reports presence in its OUTPUT, not its exit status"
else
    fail "the probe reports presence in its output" \
         "sharing the exit status with kubectl makes the two failures one"
fi

if grep -q 'could not reach pod' <<<"$_body"; then
    pass "an unreachable pod is distinguished from a missing command"
else
    fail "an unreachable pod is distinguished from a missing command" ""
fi

# ── the exit-code contract: an application must be able to say "cannot look" ──
# 🔴 `*` collapsed every non-zero code into UNHEALTHY, so a check that had lost
# its database connection made a DEFINITE claim that the data was wrong. atlas
# exits 2 for CANNOT; with ATLAS_POSTGREST_URL unset, UIS reported UNHEALTHY
# while the data was fine throughout (ops-dev, #946).
#
# ⚠️ ops-dev turned my own argument on me: I removed the "anything else" bucket
# from state 4 so a defect of MINE could not hide in a benign state, and left the
# same bucket for tenants, where their "cannot look" hides in an alarming one.
if grep -qE '^\s+2\)\s+CHECK_STATE="could-not-ask"' <<<"$_body"; then
    pass "🔴 exit 2 means the application could not look"
else
    fail "🔴 exit 2 means the application could not look" \
         "without it a tenant cannot express cannot-look and it renders as a definite UNHEALTHY"
fi

if grep -qE '^\s+1\)\s+CHECK_STATE="unhealthy"' <<<"$_body"; then
    pass "exit 1 stays a definite claim"
else
    fail "exit 1 stays a definite claim" "the contract needs both halves to mean anything"
fi

# 🔵 The remaining catch-all is deliberate, and the asymmetry is the principle:
# a catch-all must fail toward ALARM, never toward reassurance. State 4's failed
# toward reassurance — a UIS bug looked like an honest "cannot tell".
if grep -q 'outside the check contract' <<<"$_body"; then
    pass "an undefined exit code says UIS is interpreting, not relaying"
else
    fail "an undefined exit code says UIS is interpreting" \
         "silently calling it unhealthy claims a meaning the contract does not define"
fi

# ⚠️ Scoped to the EXIT-CODE case block. Applied to the whole function it also
# matched the probe's `*)` — which legitimately means "cannot tell whether the
# command is present" and SHOULD be could-not-ask. An assertion that cannot tell
# two catch-alls apart is the defect it is testing for.
_rc_case="$(sed -n '/case "\$rc" in/,/esac/p' "$LIB")"
if grep -qE '\*\)\s+CHECK_STATE="could-not-ask"' <<<"$_rc_case"; then
    fail "the catch-all fails toward alarm, not reassurance" \
         "an undefined code landing in cannot-look is the state-4 mistake repeated for tenants"
else
    pass "the catch-all fails toward alarm, not reassurance"
fi

echo ""
echo "  Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
