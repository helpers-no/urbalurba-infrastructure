#!/bin/bash
# test-install-version-override.sh — `uis template install --version <tag>@<digest>`
#
# 🔴 WHY IT EXISTS. The catalogue pin was the only installable thing, so a
# nominee could not be verified until AFTER it had been advertised to everyone.
# Every nomination to date was therefore unverified at install, or verified by
# hand-editing a registry cache — and a verification path nobody reproduces is a
# step that quietly stops happening (ops-dev, urb-agents#981).
#
# ⚠️ The two properties that matter more than the flag's name:
#   it must be visibly deliberate — a host must not drift off-catalogue with the
#   only record in a chat thread;
#   it must not silently become the normal path.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
LIB="$REPO_ROOT/provision-host/uis/lib/template.sh"

PASS=0; FAIL=0; SKIP=0
pass() { echo -e "  Testing: $1... \033[0;32mPASS\033[0m"; ((++PASS)); }
fail() { echo -e "  Testing: $1... \033[0;31mFAIL\033[0m"; echo -e "    \033[0;31m→ $2\033[0m"; ((++FAIL)); }
skip() { echo -e "  Testing: $1... \033[0;33mSKIP\033[0m"; ((++SKIP)); }

echo "=== install --version: verify a nominee before it is pinned ==="

if ! command -v yq >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    skip "yq and jq are available"
    echo ""; echo "  Passed: $PASS  Failed: $FAIL  Skipped: $SKIP"; exit 0
fi

log_error() { echo "ERROR: $*" >&2; }
log_warn()  { echo "WARN: $*" >&2; }
for fn in _uis_extend_dir _applications_file _applications_init _record_application \
          _report_off_catalogue _template_pin_is_immutable _apply_off_catalogue_version; do
    eval "$(sed -n "/^${fn}() {/,/^}$/p" "$LIB")"
done

# Control: without this, a typo in a sed range makes every assertion vacuous.
if declare -F _apply_off_catalogue_version >/dev/null && declare -F _report_off_catalogue >/dev/null; then
    pass "control: the functions loaded from the real lib"
else
    fail "control: the functions loaded from the real lib" "the sed extraction matched nothing"
    echo ""; echo "  Passed: $PASS  Failed: $FAIL  Skipped: $SKIP"; exit 1
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
GOOD="sha256:$(printf 'b%.0s' $(seq 64))"
CAT="sha256:$(printf '9%.0s' $(seq 64))"

# ⚠️ Sets TRY_RC rather than printing it. Written first as `rc="$(_try ...)"`,
# which runs the function in a SUBSHELL — so SOURCE_DIGEST and OFF_CATALOGUE
# were set and discarded, and the one assertion that reads them failed while
# every assertion reading the output FILE passed. A harness that can only see
# half the effect is a harness that tests half the function.
_try() {  # $1 = spec -> sets TRY_RC
    CATALOGUE_TAG="v20260914-9509ea5"; CATALOGUE_DIGEST="$CAT"
    SOURCE_TAG="$CATALOGUE_TAG"; SOURCE_DIGEST="$CATALOGUE_DIGEST"; OFF_CATALOGUE=0
    OFF_CATALOGUE_SPEC="$1"
    _apply_off_catalogue_version testapp >"$TMP/out" 2>&1
    TRY_RC=$?
}

_try "v20260914-1fa7961@$GOOD"; rc="$TRY_RC"
if [[ "$rc" == "0" && "$SOURCE_DIGEST" == "$GOOD" && "$OFF_CATALOGUE" == "1" ]]; then
    pass "🔴 a DIFFERENT tag@digest overrides the pin and marks the host off-catalogue"
else
    fail "🔴 a different tag@digest marks the host off-catalogue" "rc=$rc digest=$SOURCE_DIGEST off=$OFF_CATALOGUE"
fi

# 🔴 OFF-CATALOGUE IS A COMPARISON, NOT A FLAG-PRESENCE TEST. 1.6.88 set the
# marker whenever --version was used, so passing the pin the catalogue itself
# advertises printed "this is not what the catalogue points at" directly above
# the catalogue pointer it had just matched (imac via ops-dev, #987).
#
# ⚠️ The intended use is verifying a NOMINEE, and a nominee is normally the pin
# about to BECOME the catalogue pin — so the ordinary path left a false "not
# current" claim on the verification host.
_try "v20260914-9509ea5@$CAT"; rc="$TRY_RC"
if [[ "$rc" == "0" && "$OFF_CATALOGUE" == "0" ]]; then
    pass "🔴 --version naming exactly the catalogue pin is NOT off-catalogue"
else
    fail "🔴 --version naming exactly the catalogue pin is not off-catalogue" \
         "rc=$rc off=$OFF_CATALOGUE — this claimed a difference against an identical pin"
fi

if ! grep -q "OFF-CATALOGUE INSTALL" "$TMP/out"; then
    pass "and it does not print the off-catalogue banner in that case"
else
    fail "it does not print the banner for an identical pin" \
         "the banner contradicted itself two lines apart: $(cat "$TMP/out")"
fi

# ⚠️ A digest that matches while the TAG differs is still a difference worth
# marking — the same bytes under another name is not the catalogue's pin.
_try "v20260914-other@$CAT"; rc="$TRY_RC"
if [[ "$OFF_CATALOGUE" == "1" ]]; then
    pass "a matching digest under a different tag is still off-catalogue"
else
    fail "a matching digest under a different tag is still off-catalogue" "off=$OFF_CATALOGUE"
fi

# 🔴 THE LOAD-BEARING REFUSAL. Off-catalogue is precisely where nothing has
# pinned the tag, so it is where a tag is most likely to have moved since it was
# nominated — and verifying a different artifact than the one under discussion,
# then reporting success, is worse than not verifying.
_try "v20260914-1fa7961"; rc="$TRY_RC"
if [[ "$rc" != "0" ]] && grep -q "needs <tag>@<digest>" "$TMP/out"; then
    pass "🔴 a bare tag is REFUSED — a moving tag would verify the wrong artifact"
else
    fail "🔴 a bare tag is refused" "rc=$rc out=$(head -1 "$TMP/out")"
fi

_try "latest@$GOOD"; rc="$TRY_RC"
if [[ "$rc" != "0" ]] && grep -q "not immutable" "$TMP/out"; then
    pass "a moving tag is refused by the catalogue's own rule, reused here"
else
    fail "a moving tag is refused" "rc=$rc out=$(head -1 "$TMP/out")"
fi

_try "v20260914-1fa7961@sha256:notadigest"; rc="$TRY_RC"
if [[ "$rc" != "0" ]] && grep -q "not a sha256 digest" "$TMP/out"; then
    pass "a malformed digest is refused"
else
    fail "a malformed digest is refused" "rc=$rc out=$(head -1 "$TMP/out")"
fi

# ⚠️ Visibly deliberate: the operator must be able to answer "is this host
# current?" from the output, which needs BOTH pins.
_try "v20260914-1fa7961@$GOOD"; rc="$TRY_RC"
if grep -q "OFF-CATALOGUE INSTALL" "$TMP/out" && grep -q "$CAT" "$TMP/out" && grep -q "$GOOD" "$TMP/out"; then
    pass "⚠️ the banner names BOTH what the catalogue says and what is installing"
else
    fail "⚠️ the banner names both pins" "one of them is missing: $(cat "$TMP/out")"
fi

# ⚠️ The flag must not redirect WHERE FROM, only WHICH VERSION.
_fn="$(sed -n '/^_apply_off_catalogue_version() {/,/^}$/p' "$LIB")"
if grep -q 'SOURCE_ARTIFACT' <<<"$_fn"; then
    fail "the override cannot change the artifact source" \
         "a flag that also redirects the source is a much larger hole than the one it closes"
else
    pass "the override cannot change the artifact source, only the version"
fi

# ── it is recorded, and it stops being reported once the host is back ────────
export UIS_BASE="$TMP"; mkdir -p "$TMP/.uis.extend"
OFF_CATALOGUE=1 CATALOGUE_DIGEST="$CAT" \
    _record_application testapp art v20260914-1fa7961 "$GOOD" "dagster" "cl" '{}' "" testapp >/dev/null 2>&1
if [[ "$(yq -r '.applications[0].off_catalogue' "$(_applications_file)" 2>/dev/null)" == "true" ]]; then
    pass "the install is RECORDED as off-catalogue"
else
    fail "the install is recorded as off-catalogue" "the only record would be a chat thread"
fi

out="$(_report_off_catalogue testapp "$CAT" 2>&1)"
if [[ "$out" == *"OFF-CATALOGUE install"* && "$out" == *"v20260914-1fa7961"* ]]; then
    pass "a later reader is told, and told which version"
else
    fail "a later reader is told" "out=$out"
fi

# 🔴 AND IT MUST STOP. Written first with chained mikefarah selects, this
# reported on EVERY host with any recorded application, because
# select(.off_catalogue == true) passed a null through instead of dropping the
# row. A control that cries wolf is the one people learn to scroll past.
OFF_CATALOGUE=0 CATALOGUE_DIGEST="$CAT" \
    _record_application testapp art v20260914-9509ea5 "$CAT" "dagster" "cl" '{}' "" testapp >/dev/null 2>&1
out="$(_report_off_catalogue testapp "$CAT" 2>&1)"
if [[ -z "$out" ]]; then
    pass "🔴 a catalogue install silences it — the warning does not cry wolf"
else
    fail "🔴 a catalogue install silences it" "still warning on a current host: $out"
fi

# 🔴 SELF-CLEARING. A nominee verified with --version is normally the pin about
# to BECOME the catalogue pin, so a marker only a reinstall could retract left a
# false "not current" claim on the verification host from the moment
# dev-templates caught up (ops-dev, #987).
OFF_CATALOGUE=1 CATALOGUE_DIGEST="$CAT" \
    _record_application testapp art v-old "$GOOD" "dagster" "cl" '{}' "" testapp >/dev/null 2>&1
out="$(_report_off_catalogue testapp "$CAT" 2>&1)"
if [[ "$out" == *"OFF-CATALOGUE install"* ]]; then
    pass "🔴 true positive: it DOES report when the recorded pin differs from the catalogue"
else
    fail "🔴 true positive: it reports a genuine difference" \
         "silent on a host that really is off-catalogue: $out"
fi

out="$(_report_off_catalogue testapp "$GOOD" 2>&1)"
if [[ -z "$out" ]]; then
    pass "🔴 and it CLEARS ITSELF when the catalogue moves to that pin — no reinstall"
else
    fail "🔴 it clears itself when the catalogue moves to that pin" \
         "still claiming 'not current' about a host that now is: $out"
fi

# ⚠️ Both conditions, not either. Comparing pins alone would warn on every host
# whose catalogue has moved since install — that is "behind", a different thing,
# and would be the cry-wolf failure this record already had once.
# 🔴 THE BEHAVIOURAL VERSION, because the structural one was not enough. A
# mutation dropping the provenance condition left all 18 assertions passing:
# nothing exercised "installed FROM the catalogue, and the catalogue then moved
# on". That host is BEHIND, which is a different thing, and warning about it
# would be the cry-wolf failure this record already had once.
OFF_CATALOGUE=0 CATALOGUE_DIGEST="$GOOD" \
    _record_application testapp art v-cat "$GOOD" "dagster" "cl" '{}' "" testapp >/dev/null 2>&1
out="$(_report_off_catalogue testapp "$CAT" 2>&1)"
if [[ -z "$out" ]]; then
    pass "🔴 a catalogue install whose catalogue MOVED ON is silent — behind is not off-catalogue"
else
    fail "🔴 a catalogue install whose catalogue moved on is silent" \
         "warning about a host that never used --version: $out"
fi

# ⚠️ Comments stripped: a scan that can match the prose explaining a rule is a
# scan that passes when the rule is gone. That has happened in this repo.
_rep="$(sed -n '/^_report_off_catalogue() {/,/^}$/p' "$LIB" | grep -v '^[[:space:]]*#')"
if grep -q 'off_catalogue == true' <<<"$_rep" && grep -q '!= \$cat' <<<"$_rep"; then
    pass "⚠️ the report needs BOTH --version provenance and a live difference"
else
    fail "⚠️ the report needs both provenance and a live difference" \
         "one condition alone re-opens a false-positive class"
fi

# ⚠️ With no catalogue pin to compare against it must say it could not compare,
# rather than reporting either currency or drift.
#
# ⚠️ Re-record off-catalogue first: the record is keyed on app_name, so the
# catalogue-install assertion above REPLACED it. Without this line the
# assertion below passed for the wrong reason — no matching row rather than a
# correct refusal to guess. Found by a mutation that should have failed and did
# not.
OFF_CATALOGUE=1 CATALOGUE_DIGEST="$CAT" \
    _record_application testapp art v-old "$GOOD" "dagster" "cl" '{}' "" testapp >/dev/null 2>&1
out="$(_report_off_catalogue testapp "" 2>&1)"
if [[ "$out" == *"could NOT be determined"* ]]; then
    pass "⚠️ an unreadable catalogue pin is 'could not compare', not a drift claim"
else
    fail "⚠️ an unreadable catalogue pin is 'could not compare'" "out=$out"
fi

# ⚠️ And the row must not arrive as one field. mikefarah `+ "\t" +` emits a
# LITERAL backslash-t, which this hit.
OFF_CATALOGUE=1 CATALOGUE_DIGEST="$CAT" \
    _record_application testapp art v20260914-1fa7961 "$GOOD" "dagster" "cl" '{}' "" testapp >/dev/null 2>&1
out="$(_report_off_catalogue testapp "$CAT" 2>&1)"
if [[ "$out" != *'\t'* ]]; then
    pass "the report splits its fields rather than printing a literal backslash-t"
else
    fail "the report splits its fields" "literal \\t in the output: $out"
fi

echo ""
echo "  Passed: $PASS  Failed: $FAIL  Skipped: $SKIP"
[[ "$FAIL" -eq 0 ]]
