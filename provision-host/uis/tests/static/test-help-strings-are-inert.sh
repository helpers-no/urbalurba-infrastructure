#!/bin/bash
# test-help-strings-are-inert.sh — operator-facing text must not EXECUTE
#
# 🔴 `uis template` PRINTED SHELL ERRORS INTO ITS OWN HELP.
#
#     echo "   (not liveness — `status` and `verify` are the words for that)"
#
# Backticks inside double quotes are command substitution. bash ran `status` and
# `verify`, printed both "command not found" lines to the operator, and
# substituted empty strings — so the ONE sentence that distinguishes `check`
# from `status`/`verify` lost both words. On `uis template`, the first thing a
# new operator runs (Terje via ops-dev, urb-agents#1031).
#
# ⚠️ Three instances existed, and one was introduced the same day in the
# `progress` help. This is a class, not an incident.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

PASS=0; FAIL=0
pass() { echo -e "  Testing: $1... \033[0;32mPASS\033[0m"; ((++PASS)); }
fail() { echo -e "  Testing: $1... \033[0;31mFAIL\033[0m"; echo -e "    \033[0;31m→ $2\033[0m"; ((++FAIL)); }

echo "=== help text must be printed, not executed ==="

mapfile -t FILES < <(printf '%s\n' \
    "$REPO_ROOT"/provision-host/uis/lib/*.sh \
    "$REPO_ROOT"/provision-host/uis/manage/*.sh \
    "$REPO_ROOT"/uis)

if [[ "${#FILES[@]}" -ge 5 ]]; then
    pass "control: the scan has files to read (${#FILES[@]})"
else
    fail "control: the scan has files to read" "found ${#FILES[@]} — the glob is wrong and every check below is vacuous"
    echo ""; echo "  Passed: $PASS  Failed: $FAIL"; exit 1
fi

# 🔴 A DOUBLE-QUOTED echo/printf ARGUMENT CONTAINING A BACKTICK.
#
# Matching is deliberately narrow: only `echo "` / `printf "` up to the closing
# quote, because a backtick elsewhere in a script may be intentional. An
# escaped backtick (\`) is fine — that is the fix — so it is excluded.
_hits=""
for f in "${FILES[@]}"; do
    [[ -f "$f" ]] || continue
    while IFS= read -r line; do
        _hits+="$(basename "$f"):$line"$'\n'
    done < <(grep -nE '(echo|printf) "[^"]*[^\\]`' "$f" 2>/dev/null)
done
if [[ -z "$_hits" ]]; then
    pass "🔴 no double-quoted echo/printf contains an unescaped backtick"
else
    fail "🔴 no double-quoted echo/printf contains an unescaped backtick" \
         "these EXECUTE and print 'command not found' to the operator:"$'\n'"${_hits%$'\n'}"
fi

# ⚠️ Positive control: the scan must actually catch the real defect. Without
# this, a pattern that matches nothing looks identical to a clean tree — which
# is how three of my assertions passed vacuously today.
_ctl="$(mktemp)"; trap 'rm -f "$_ctl"' EXIT
cat > "$_ctl" <<'CTL'
helpx() {
    echo "  (not liveness — `status` and `verify` are the words)"
}
CTL
if grep -qE '(echo|printf) "[^"]*[^\\]`' "$_ctl"; then
    pass "⚠️ positive control: the real defect IS caught by this pattern"
else
    fail "⚠️ positive control: the real defect is caught" \
         "the pattern does not match the very line that caused the defect"
fi

# ⚠️ Negative control: the FIX must not trip it, or the test forces the wrong
# remedy.
_ctl2="$(mktemp)"; trap 'rm -f "$_ctl" "$_ctl2"' EXIT
cat > "$_ctl2" <<'CTL'
helpy() {
    echo '  (not liveness — `status` and `verify` are the words)'
    echo "  A dependant's \`requires: $id\` will not see it."
}
CTL
if ! grep -qE '(echo|printf) "[^"]*[^\\]`' "$_ctl2"; then
    pass "⚠️ negative control: single quotes and escaped backticks both pass"
else
    fail "⚠️ negative control: the fix passes" "the test would force a remedy that is not the fix"
fi

# ── every template subcommand honours --help ────────────────────────────────
# 🔴 `--help` WAS READ AS AN APPLICATION ID: `check --help` reported no install
# record for '--help', and `install --help` said it was not in the registry then
# advised --refresh — offering to look harder for an application called --help.
# `uis --help` and `uis dagster --help` already worked, which is what made it a
# defect rather than a missing feature.
_rt="$(sed -n '/^run_template() {/,/^}$/p' "$REPO_ROOT/provision-host/uis/lib/template.sh")"
_rt_code="$(grep -v '^[[:space:]]*#' <<<"$_rt")"
if grep -qE '\-\-help\|-h\) set --' <<<"$_rt_code"; then
    pass "🔴 run_template intercepts --help before dispatching to a subcommand"
else
    fail "🔴 run_template intercepts --help before dispatch" \
         "an id-taking subcommand will treat --help as an id and advise --refresh"
fi

# ⚠️ Intercepted ONCE, not per subcommand — five copies of a guard is five
# things that drift apart.
#
# ⚠️ The pattern matches the INTERCEPTION, not every mention of --help: the
# `""|help|--help|-h)` case arm is the help case itself and counting it made
# this read 2. A pattern that matches more than it means is the same defect as
# one that matches less, which bit three assertions of mine today.
_n="$(grep -cE '\-\-help\|-h\) set --' <<<"$_rt_code")"
if [[ "$_n" == "1" ]]; then
    pass "⚠️ intercepted once, not copied into each subcommand"
else
    fail "⚠️ intercepted once" "found $_n interceptions in run_template"
fi

# ── the application's own declared commands reach the operator ──────────────
# 🔴 The application wrote a description of its check, UIS READ that description
# in order to RUN the check, and `template info` never showed either.
_lib="$REPO_ROOT/provision-host/uis/lib/template.sh"
if grep -q '_template_info_commands' "$_lib"; then
    pass "🔴 template info renders the application's declared commands"
else
    fail "🔴 template info renders the declared commands" \
         "UIS reads commands.check.description to run the check and showed it to nobody"
fi

_fn="$(sed -n '/^_template_info_commands() {/,/^}$/p' "$_lib" | grep -v '^[[:space:]]*#')"
if grep -q 'declares no commands' <<<"$_fn"; then
    pass "it says 'declares no commands' rather than printing an empty section"
else
    fail "it says so when there are none" "an empty section is not an answer"
fi

# ⚠️ And the INVOCATION is named, not just the script path. `run:` executes
# inside the code-location pod, so a path alone is correct and unusable.
if grep -q 'uis template check' <<<"$_fn"; then
    pass "⚠️ it names how the OPERATOR invokes it, not only the script it runs"
else
    fail "⚠️ it names the operator's invocation" \
         "a path the operator cannot execute is the correct-and-unreachable shape"
fi

# 🔴 It must render even when the artifact declares no `operational:` block —
# gating both on `operational` would hide `commands`.
_op="$(sed -n '/^_template_info_operational() {/,/^}$/p' "$_lib" | grep -v '^[[:space:]]*#')"
_cmd_line="$(grep -n '_template_info_commands' <<<"$_op" | head -1 | cut -d: -f1)"
_gate_line="$(grep -n 'has("operational")' <<<"$_op" | head -1 | cut -d: -f1)"
if [[ -n "$_cmd_line" && -n "$_gate_line" && "$_cmd_line" -lt "$_gate_line" ]]; then
    pass "🔴 commands render BEFORE the operational gate, so one cannot hide the other"
else
    fail "🔴 commands render before the operational gate" \
         "commands at line ${_cmd_line:-none}, gate at ${_gate_line:-none}"
fi

echo ""
echo "  Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
