#!/bin/bash
# test-code-location-digest-write.sh — the digest must survive the renderer.
#
# 🔴 1.6.62 built the digest field, the deploy-time verification, the docs and
# the schema. atlas declared one. And `uis template install` could not emit it:
# `_write_code_location` took six parameters and the definition's `digest` was
# never even read into the conf, because `TEMPLATE_CODE_LOCATION_KEYS` did not
# list it.
#
# Every deploy-time task then SKIPPED on a real install — 22d1, 22d4, 22d5 —
# and the install was silently green. Every digest printed was correct and
# nothing was pinned (imac via ops-dev, urb-agents#745).
#
# ⚠️ Nobody built the wrong thing. Three correct pieces with an empty seam
# between them, which is why no test on any single piece would have caught it.
# This one runs the renderer and READS THE FILE BACK.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"

LIB="$(cd "$SCRIPT_DIR/../../lib" && pwd)/template.sh"

print_test_section "the declared digest survives template install"

start_test "the renderer and the key list are where the test thinks they are"
if [[ -f "$LIB" ]] && grep -q '^_write_code_location() {' "$LIB"; then
    pass_test
else
    fail_test "no _write_code_location in $LIB"; print_summary; exit $?
fi

start_test "🔴 the definition's digest is READ at all"
# A key absent from this list is never read from template-info.yaml, so the
# renderer could not emit it even with a parameter to put it in.
if grep -q '^TEMPLATE_CODE_LOCATION_KEYS=.*digest' "$LIB"; then
    pass_test
else
    fail_test "TEMPLATE_CODE_LOCATION_KEYS does not include 'digest'"
fi

start_test "the call site passes it to the renderer"
if grep -q '_write_code_location "\$cl_n" "\$cl_i" "\$cl_t" "\$cl_m" "\$cl_w" "\$cl_s" "\$cl_d"' "$LIB"; then
    pass_test
else
    fail_test "the call site still passes six arguments"
fi

if ! command -v yq >/dev/null 2>&1; then
    skip_test "yq not installed (it lives in uis-provision-host) — renderer not executed"
    skip_test "yq not installed — absent-digest case not executed"
    skip_test "yq not installed — read-back refusal not executed"
    print_summary
    exit $?
fi

# ── execute the renderer for real ──────────────────────────────────────────────
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
DIGEST="sha256:86c5aed1af1a9def74166ccce6b20dc614b62de1696d1d5b2bf04ab3eb8f13c1"

log_error() { echo "ERROR: $*" >&2; }
log_info()  { :; }
_code_locations_file() { echo "$TMPD/dagster-code-locations.yaml"; }
eval "$(sed -n '/^_write_code_location() {/,/^}/p' "$LIB")"

start_test "🔴 a declared digest lands in the overlay the deploy reads"
rm -f "$TMPD/dagster-code-locations.yaml"
_write_code_location atlas-data ghcr.io/terchris/atlas-data v20260912-50fded5 \
    atlas_data.definitions "why" "atlas-db" "$DIGEST" >/dev/null 2>&1
_got=$(yq -r '.code_locations[] | select(.name == "atlas-data") | .digest // ""' \
       "$TMPD/dagster-code-locations.yaml" 2>/dev/null)
[[ "$_got" == "$DIGEST" ]] && pass_test || fail_test "overlay digest is '${_got:-<absent>}'"

start_test "an entry with no digest has no digest KEY, not an empty one"
# `digest: ""` would be "declared but empty" to the deploy's length guard, and
# would skip exactly as the missing field did.
_write_code_location other ghcr.io/x/y v1 m.mod "why2" "" >/dev/null 2>&1
_has=$(yq -r '.code_locations[] | select(.name == "other") | has("digest")' \
       "$TMPD/dagster-code-locations.yaml" 2>/dev/null)
[[ "$_has" == "false" ]] && pass_test || fail_test "has(\"digest\") is '$_has', expected false"

start_test "🔴 a digest that does not survive the write REFUSES"
# Simulates the 1.6.62 shape directly: the digest expression silently does
# nothing and every layer above still reports success.
_rc=0
(
    _realyq="$(command -v yq)"
    yq() { for a in "$@"; do case "$a" in *".digest)"*) return 0 ;; esac; done; "$_realyq" "$@"; }
    _code_locations_file() { echo "$TMPD/regress.yaml"; }
    eval "$(sed -n '/^_write_code_location() {/,/^}/p' "$LIB")"
    _write_code_location atlas ghcr.io/x/y v1 m.m "why" "" "$DIGEST"
) >/dev/null 2>&1 || _rc=$?
[[ "$_rc" -ne 0 ]] && pass_test || fail_test "the renderer reported success having written no digest"

start_test "the successful path still returns 0"
_write_code_location third ghcr.io/a/b v2 m.m "why3" "" "$DIGEST" >/dev/null 2>&1 && pass_test \
    || fail_test "a correct write must not be refused"

print_summary
