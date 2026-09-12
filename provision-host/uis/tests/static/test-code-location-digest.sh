#!/bin/bash
# test-code-location-digest.sh — the code image must be pinnable, and the
# resolved digest must be reported whether or not it was pinned.
#
# 🔴 The install definition is pulled at a digest and checked against the pin
# the catalogue records. The CODE image — the thing that actually executes — was
# addressed by `image:` + `tag:` with no digest field at all, so an application
# could not pin it even if it wanted to. A re-push of that tag changes what runs
# while every digest UIS prints stays identical (imac via ops-dev, #740).
#
# ⚠️ An immutable-LOOKING tag is not an immutable tag. The existing `latest`
# rejection is a deployment-correctness rule — Helm rolls the pod only when the
# image string changes — and `v20260911-f4bf175` satisfies it completely while
# still being re-pushable. That was the only rule UIS had.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
SETUP="$REPO_ROOT/ansible/playbooks/360-setup-dagster.yml"
VERIFY="$REPO_ROOT/ansible/playbooks/360-test-dagster.yml"
SCHEMA="$REPO_ROOT/provision-host/uis/templates/uis.extend/dagster-code-locations.yaml.default"

PASS=0; FAIL=0
pass() { echo -e "  Testing: $1... \033[0;32mPASS\033[0m"; ((++PASS)); }
fail() { echo -e "  Testing: $1... \033[0;31mFAIL\033[0m"; echo -e "    \033[0;31m→ $2\033[0m"; ((++FAIL)); }

echo "=== the code image can be pinned, and what runs is reported ==="

for f in "$SETUP" "$VERIFY" "$SCHEMA"; do
    [[ -f "$f" ]] || { fail "files present" "missing: $f"; echo; echo "  Passed: $PASS  Failed: $FAIL"; exit 1; }
done

# Comments name the defect; they must not satisfy the assertions.
setup_code="$(grep -v '^[[:space:]]*#' "$SETUP")"
verify_code="$(grep -v '^[[:space:]]*#' "$VERIFY")"

if grep -q 'ansible.builtin.assert' <<<"$setup_code"; then
    pass "control: the comment-stripped scan still sees tasks"
else
    fail "control: the comment-stripped scan still sees tasks" "stripping removed everything"
fi

# ── the resolution happens and is kept ─────────────────────────────────────────
# ⚠️ The playbook's sed uses character classes — `[Dd]ocker-[Cc]ontent-[Dd]igest`
# — so this must be a FIXED-string search. A regex search matched nothing and
# failed this assertion against correct code on its first run.
if grep -qF 'ocker-[Cc]ontent-[Dd]igest' <<<"$setup_code"; then
    pass "🔴 the pre-flight keeps the digest the registry returns"
else
    fail "🔴 the pre-flight keeps the digest the registry returns" \
         "the manifest request no longer reads the digest header"
fi

if grep -q -- '-D -' <<<"$setup_code"; then
    pass "headers are captured (-D -), not just the status code"
else
    fail "headers are captured (-D -), not just the status code" \
         "without response headers there is no digest to read"
fi

# ── a declared digest is verified, and a mismatch refuses ──────────────────────
if grep -q '22d4' <<<"$setup_code" && grep -q '_resolved == item.item.digest' <<<"$setup_code"; then
    pass "🔴 a declared digest is compared against what the tag resolves to"
else
    fail "🔴 a declared digest is compared against what the tag resolves to" \
         "no equality assertion between the declared and resolved digest"
fi

if grep -q "22d1" <<<"$setup_code" && grep -q 'sha256:\[0-9a-f\]{64}' <<<"$setup_code"; then
    pass "a malformed declared digest is rejected as malformed"
else
    fail "a malformed declared digest is rejected as malformed" \
         "a typo would surface as 'the tag has been re-pushed'"
fi

# ── could-not-look must not read as does-not-match ─────────────────────────────
if grep -q '22d5' <<<"$setup_code" && grep -q 'NOTHING WAS COMPARED' <<<"$setup_code"; then
    pass "🔴 an unresolvable image says NOTHING WAS COMPARED"
else
    fail "🔴 an unresolvable image says NOTHING WAS COMPARED" \
         "a 401 from a private registry must not be reported as a mismatch"
fi

# ── the digest is reported even when nothing was declared ──────────────────────
# ⚠️ Asserts the INTENT, not a phrase. The first version matched the literal
# string "not declared", and failed the moment that message was corrected — the
# old wording blamed the application for a value UIS had lost (#745).
if grep -q '22d6' <<<"$setup_code" && grep -q 'the tag is not pinned' <<<"$setup_code"; then
    pass "the resolved digest is printed even with no declaration"
else
    fail "the resolved digest is printed even with no declaration" \
         "an operator who never pinned has no value to copy in"
fi

# 🔴 And the message must not blame the application. 22d6 reads the OVERLAY and
# cannot know what the definition said; "not declared — add `digest:` to pin it"
# was printed on a run where atlas plainly declared one, and pointed the reader
# at the wrong agent.
if grep -qF 'not declared — add `digest:` to pin it' <<<"$setup_code"; then
    fail "22d6 does not attribute a missing digest to the application" \
         "this task cannot know whether the definition declared one"
else
    pass "22d6 does not attribute a missing digest to the application"
fi

# ── optional, not required ─────────────────────────────────────────────────────
_required_block="$(awk '/22c\. Require the fields/,/loop_control/' "$SETUP")"
if grep -q 'item.digest is defined' <<<"$_required_block"; then
    fail "digest stays OPTIONAL" \
         "an application that cannot publish digests must still be installable"
else
    pass "digest stays OPTIONAL"
fi

# ── what is RUNNING, from imageID and not from the tag we asked for ────────────
# ⚠️ Must match the jsonpath that READS it, not the word anywhere. The first
# version of this assertion passed against a playbook regressed to `{.image}`,
# because the summary line also contains the word "imageID". A check satisfied
# by prose about the thing is not a check on the thing.
if grep -qF '{.imageID}' <<<"$verify_code"; then
    pass "🔴 verify reads imageID — what the kubelet actually started"
else
    fail "🔴 verify reads imageID — what the kubelet actually started" \
         "no {.imageID} jsonpath in the verify playbook"
fi

# `.image` is the string we already had; reporting it would assert nothing.
if grep -qE '\{\.image\}|\.image\}' <<<"$verify_code"; then
    fail "verify does not report .image as if it were a verification" \
         "'image' is the tag we asked for; only imageID says what runs"
else
    pass "verify does not report .image as if it were a verification"
fi

if grep -q 'could-not-read' <<<"$verify_code" && grep -q 'NOTHING WAS COMPARED' <<<"$verify_code"; then
    pass "an unreadable running digest is 'could not look', not 'nothing running'"
else
    fail "an unreadable running digest is 'could not look', not 'nothing running'" \
         "the E checks do not distinguish the two"
fi

# ── E must COMPARE, not merely report ─────────────────────────────────────────
# 🔴 1.6.62's check E printed the running digest and asserted nothing against
# it. imac: "the match is one I made by eye against ops-dev's message." A green
# E was readable as a verified pin while nothing had been checked (#745).
if grep -q 'E2c' <<<"$verify_code" && grep -q 'ansible.builtin.fail' <<<"$verify_code"; then
    pass "🔴 a running digest that differs from the declared one FAILS"
else
    fail "🔴 a running digest that differs from the declared one FAILS"          "check E reports without comparing — a reported digest is not a verified one"
fi

# ⚠️ The comparison needs the declarations, and this playbook did not load them.
# The first version read `_code_locations`, which is set in 360-setup-dagster and
# is UNDEFINED here — so it would have looped over an empty dict and passed on
# every run. A guard that cannot fire, in the commit written to fix a guard that
# could not fire.
if grep -q '_declared_locations' <<<"$verify_code"    && grep -q 'dagster-code-locations.yaml' <<<"$verify_code"; then
    pass "the verify playbook loads the declarations it compares against"
else
    fail "the verify playbook loads the declarations it compares against"          "E compares against a variable this playbook never sets"
fi

if grep -qE '^    uis_extend_dir:' "$VERIFY"; then
    pass "uis_extend_dir is defined in the playbook that now reads it"
else
    fail "uis_extend_dir is defined in the playbook that now reads it"          "the slurp would fail on an undefined variable"
fi

if grep -q 'default(\[\], true)' <<<"$verify_code"; then
    pass "a bare code_locations: (null) is tolerated, as in the setup playbook"
else
    fail "a bare code_locations: (null) is tolerated"          "default([]) replaces only UNDEFINED; a hand-edited null flows through"
fi

if grep -q 'E2d' <<<"$verify_code" && grep -q 'nothing was compared' <<<"$verify_code"; then
    pass "E says how many locations were actually compared"
else
    fail "E says how many locations were actually compared"          "without it, a run where nothing declares a digest looks the same as a verified one"
fi

# ── the renderer must be able to emit what the deploy enforces ────────────────
LIB="$REPO_ROOT/provision-host/uis/lib/template.sh"
if grep -q '^TEMPLATE_CODE_LOCATION_KEYS=.*digest' "$LIB"; then
    pass "🔴 the definition's digest is read into the install plan"
else
    fail "🔴 the definition's digest is read into the install plan"          "a key absent from TEMPLATE_CODE_LOCATION_KEYS is never read at all"
fi

if grep -q 'did not survive the write' "$LIB"; then
    pass "the renderer reads its own write back before claiming success"
else
    fail "the renderer reads its own write back before claiming success"          "a value accepted by every layer can still not be in the file"
fi

# ── the schema tells an application the field exists ───────────────────────────
if grep -q '^#   digest      optional' "$SCHEMA"; then
    pass "the schema documents digest as an optional field"
else
    fail "the schema documents digest as an optional field" \
         "a field nobody is told about is a field nobody uses"
fi

if grep -q 'immutable-LOOKING tag is not an immutable tag\|IMMUTABLE-LOOKING TAG IS NOT' "$SCHEMA"; then
    pass "the schema says why the existing latest-rule is not enough"
else
    fail "the schema says why the existing latest-rule is not enough" \
         "without it, the latest-rule reads as covering integrity"
fi

echo ""
echo "  Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
