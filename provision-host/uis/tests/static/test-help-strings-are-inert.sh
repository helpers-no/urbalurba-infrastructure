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

# ---------------------------------------------------------------------------
# 🔴 THE SAME HAZARD IN A SPELLING THIS FILE DID NOT LOOK AT: HEREDOCS.
#
# Every check above matches `echo "` / `printf "`. `cmd_help` is a `cat <<EOF`,
# which those patterns never see — so a backtick sat in the help text until
# somebody ran the command and reported it:
#
#     uis help configure  ->  check: command not found
#
# An UNQUOTED heredoc performs command substitution, so bash ran `check` and
# the backticked word vanished from the output (imac, urb-agents#1700 item 3).
#
# 🔵 The rule is narrow on purpose: a backtick in an unquoted heredoc is always
# a mistake, while `$(...)` is the spelling used when substitution IS wanted —
# as in the config file `uis init` generates with `$(date)`. So this forbids
# backticks only, and ignores escaped ones (\\`), which is how the two
# legitimate uses in the docs generators spell a literal backtick.
# ---------------------------------------------------------------------------

# Echoes "line N: text" for every backtick inside an UNQUOTED heredoc.
_scan_heredocs() {
    python3 - "$1" <<'PYEOF'
import re, sys
lines = open(sys.argv[1], errors="ignore").read().splitlines()
inhd = False
for i, l in enumerate(lines, 1):
    if not inhd:
        m = re.search(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1", l)
        if m:
            inhd, quoted, delim, start, body = True, bool(m.group(1)), m.group(2), i, []
    else:
        if l.strip() == delim:
            if not quoted:
                for k, x in enumerate(body, 1):
                    # An escaped backtick is inert inside an unquoted heredoc,
                    # and escaping is the fix, so strip those before looking.
                    if "`" in re.sub(r"\\.", "", x):
                        print(f"line {start+k}: {x.strip()[:70]}")
            inhd = False
        else:
            body.append(l)
PYEOF
}

_hd_hits=""
for f in "${FILES[@]}"; do
    [[ -f "$f" ]] || continue
    while IFS= read -r line; do
        [[ -n "$line" ]] && _hd_hits+="$(basename "$f"):$line"$'\n'
    done < <(_scan_heredocs "$f")
done
if [[ -z "$_hd_hits" ]]; then
    pass "🔴 no unquoted heredoc carries a backtick, which bash would execute"
else
    fail "🔴 no unquoted heredoc carries a backtick" \
         "these EXECUTE every time the text is printed:"$'\n'"${_hd_hits%$'\n'}"
fi

# ⚠️ Positive control: the scanner must find one that IS there, or a clean
# result is indistinguishable from a broken parser.
_hdctl="$(mktemp)"
printf 'show() {\n    cat <<EOF\nthis has a `backtick`\nEOF\n}\n' > "$_hdctl"
if [[ -n "$(_scan_heredocs "$_hdctl")" ]]; then
    pass "control: the heredoc scanner finds a backtick that is there"
else
    fail "control: the heredoc scanner finds a backtick that is there" \
         "it found nothing in a file built to contain one — the check above proves nothing"
fi
rm -f "$_hdctl"

# 🔵 Negative control: a QUOTED heredoc is inert and must NOT be flagged, or
# the fix for this class would fail its own test.
_hdctl2="$(mktemp)"
printf "show() {\n    cat <<'EOF'\nthis has a \`backtick\` and is inert\nEOF\n}\n" > "$_hdctl2"
if [[ -z "$(_scan_heredocs "$_hdctl2")" ]]; then
    pass "control: a quoted heredoc with a backtick is correctly ignored"
else
    fail "control: a quoted heredoc with a backtick is correctly ignored" \
         "quoting the delimiter is a valid fix and the scanner rejects it"
fi
rm -f "$_hdctl2"

echo ""
echo "  Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
