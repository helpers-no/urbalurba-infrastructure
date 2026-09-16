#!/bin/bash
# test-info-names-the-pin.sh — `uis template info` renders the CATALOGUE's pinned
# definition. When the host runs a different one, the output has to say so.
#
# 🔴 THREE PEOPLE READ A CORRECT RENDER AS A DEFECT. imac tested atlas at
# `e439668`, installed by digest while the catalogue still pinned `b7e513f`.
# `info` rendered b7e513f's `first_data.how` — 1114 characters, complete and
# correct for the version it was describing — and it was read as a TRUNCATED
# e439668, whose field is 2300 and of which 1114 is a byte-exact prefix.
#
# ⚠️ ops-dev diagnosed a truncation mechanism twice from that, and atlas shipped
# a general rule about a "silent cliff" in UIS that does not exist
# (urb-agents#1152, #1157). The render was right. The label was missing.
#
# 🔵 And the symptom vanished within the hour when dev-templates moved the pin,
# so anyone re-running the test sees correct output. The defect did not vanish.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
LIB="$REPO_ROOT/provision-host/uis/lib/template.sh"

PASS=0; FAIL=0; SKIP=0
pass() { echo -e "  Testing: $1... \033[0;32mPASS\033[0m"; ((++PASS)); }
fail() { echo -e "  Testing: $1... \033[0;31mFAIL\033[0m"; echo -e "    \033[0;31m→ $2\033[0m"; ((++FAIL)); }
skip() { echo -e "  Testing: $1... \033[0;33mSKIP\033[0m"; ((++SKIP)); }

echo "=== template info says which pin it is describing ==="

if ! command -v jq >/dev/null 2>&1 || ! command -v yq >/dev/null 2>&1; then
    skip "jq and yq are available"
    echo ""; echo "  Passed: $PASS  Failed: $FAIL  Skipped: $SKIP"; exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# ⚠️ The function reads the record through _applications_file, so that is what
# the harness replaces — not the yq call inside it. Stubbing the reader would
# test the stub.
_applications_file() { echo "$TMP/applications.yaml"; }
eval "$(sed -n '/^_template_info_describes_pin() {/,/^}$/p' "$LIB")"

if declare -F _template_info_describes_pin >/dev/null; then
    pass "control: the function loaded from the real lib"
else
    fail "control: the function loaded" "the sed extraction matched nothing — every assertion below is vacuous"
    echo ""; echo "  Passed: $PASS  Failed: $FAIL  Skipped: $SKIP"; exit 1
fi

_record() {
    cat > "$TMP/applications.yaml" <<YAML
applications:
$(printf '%s\n' "$@")
YAML
}
_entry() { printf '  - id: %s\n    app_name: %s\n    pin: %s\n' "$1" "$2" "$3"; }

CAT="sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
INST="sha256:iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii"

# ── the case that cost two days ─────────────────────────────────────────────
_record "$(_entry atlas atlas "$INST")"
out="$(_template_info_describes_pin atlas "$CAT")"
if [[ "$out" == *"CATALOGUE'S PIN"* && "$out" == *"$CAT"* && "$out" == *"$INST"* ]]; then
    pass "🔴 a differing pin is named, with both digests"
else
    fail "🔴 a differing pin is named" "the reader cannot tell whose answer they are reading: $out"
fi

if [[ "$out" == *"install atlas"* ]]; then
    pass "⚠️ and it says what would make the two agree"
else
    fail "⚠️ it says how to reconcile" "naming a discrepancy without the remedy is half a message: $out"
fi

# ── 🔴 SILENT WHEN THEY AGREE. A label on every info run is noise, and noise is
# what gets scrolled past on the run where it matters.
_record "$(_entry atlas atlas "$CAT")"
out="$(_template_info_describes_pin atlas "$CAT")"
if [[ -z "$out" ]]; then
    pass "🔴 nothing is printed when the pins agree"
else
    fail "🔴 silent when the pins agree" "a notice on every run is one nobody reads: $out"
fi

# ── ⚠️ SEVERAL TENANTS, SEVERAL PINS. The record is keyed on app_name, so one
# template id can hold more than one install, at more than one digest.
INST2="sha256:2222222222222222222222222222222222222222222222222222222222222222"
_record "$(_entry atlas atlas "$INST")" "$(_entry atlas atlas-test "$INST2")"
out="$(_template_info_describes_pin atlas "$CAT")"
if [[ "$out" == *"$INST"* && "$out" == *"$INST2"* ]]; then
    pass "⚠️ every distinct installed pin is listed, not just the first"
else
    fail "⚠️ all tenants' pins are listed" "one tenant's pin silently stands for another's: $out"
fi

# ── ⚠️ A DIFFERENT TEMPLATE'S RECORD IS NOT THIS ONE'S ──────────────────────
_record "$(_entry otherapp otherapp "$INST")"
out="$(_template_info_describes_pin atlas "$CAT")"
if [[ -z "$out" ]]; then
    pass "⚠️ another template's pin does not trigger this one's notice"
else
    fail "⚠️ the record is filtered by id" "got: $out"
fi

# ── ⚠️ NO CATALOGUE DIGEST IS NOT A DISCREPANCY ─────────────────────────────
# 🔵 With nothing to compare against, this says nothing rather than claiming the
# host has drifted — the rule _report_off_catalogue already learned.
_record "$(_entry atlas atlas "$INST")"
out="$(_template_info_describes_pin atlas "")"
if [[ -z "$out" ]]; then
    pass "🔵 with no catalogue digest to compare, it makes no claim"
else
    fail "🔵 no catalogue digest means no claim" "a marker that guesses in the dark: $out"
fi

# ── ⚠️ NO RECORD AT ALL — a template that is not installed here ─────────────
rm -f "$TMP/applications.yaml"
out="$(_template_info_describes_pin atlas "$CAT")"
if [[ -z "$out" ]]; then
    pass "⚠️ an uninstalled template prints no notice"
else
    fail "⚠️ silent with no record" "info on a template nobody installed is not a discrepancy: $out"
fi

# ── 🔴 AND IT MUST RUN BEFORE ANYTHING THE BLOCK PRINTS ─────────────────────
# A commands block read out of the catalogue's version is as wrong about this
# host as a cadence table is, so the label cannot come after it.
_fn="$(sed -n '/^_template_info_operational() {/,/^}$/p' "$LIB")"
_pin_at=$(grep -n '_template_info_describes_pin' <<<"$_fn" | head -1 | cut -d: -f1)
_cmd_at=$(grep -n '_template_info_commands' <<<"$_fn" | head -1 | cut -d: -f1)
if [[ -n "$_pin_at" && -n "$_cmd_at" && "$_pin_at" -lt "$_cmd_at" ]]; then
    pass "🔴 the label is emitted before the commands and operational blocks"
else
    fail "🔴 the label comes first" "pin_at='$_pin_at' cmd_at='$_cmd_at' — a caveat under the text it qualifies is read too late"
fi

# ── 🔴 IT MUST NOT BE HOISTED INTO THE HEADER ──────────────────────
# The obvious future simplification is "we already print Tag and Pin at the top
# of `info`, so say it once up there instead of twice down here." We already did
# print them up there. imac's stored capture from the session that caused this,
# on UIS BEFORE the change (ops-dev, urb-agents#1164):
#
#     Tag:      v20260914-b7e513f
#     Pin:      sha256:aa52587c…b2b6
#     ⚠ This host has an OFF-CATALOGUE install of 'atlas'.
#          atlas  installed at v20260916-e439668 / sha256:ba5305f0…875613cc
#          catalogue now points at sha256:aa52587c…b2b6
#     … roughly twenty lines …
#     [the operational block, describing b7e513f]
#
# ⚠️ Both digests, named, before a word of the block — and three agents spent an
# afternoon on a truncation that never happened. A label twenty lines from its
# subject is read as preamble, and preamble is skipped. The defect was DISTANCE,
# so a fix that restores the distance is not a simplification, it is the bug.
_cmd_fn="$(sed -n '/^cmd_template_info() {/,/^}$/p' "$LIB")"
if [[ -z "$_cmd_fn" ]]; then
    fail "the info command is readable" "sed range matched nothing in $LIB"
elif grep -q '_template_info_describes_pin' <<<"$_cmd_fn"; then
    fail "🔴 the label is not hoisted into the header" \
         "called from cmd_template_info, it prints with Tag/Pin and twenty lines from the block it governs — which is the original defect"
else
    pass "🔴 the label is not hoisted into the header beside Tag and Pin"
fi

echo ""
echo "  Passed: $PASS  Failed: $FAIL  Skipped: $SKIP"
[[ "$FAIL" -eq 0 ]]
