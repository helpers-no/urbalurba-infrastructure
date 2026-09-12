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
if grep -q '22d6' <<<"$setup_code" && grep -q 'not declared' <<<"$setup_code"; then
    pass "the resolved digest is printed even with no declaration"
else
    fail "the resolved digest is printed even with no declaration" \
         "an operator who never pinned has no value to copy in"
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
