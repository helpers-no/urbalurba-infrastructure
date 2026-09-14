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
    pass "a tag@digest overrides the catalogue pin"
else
    fail "a tag@digest overrides the catalogue pin" "rc=$rc digest=$SOURCE_DIGEST off=$OFF_CATALOGUE"
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
