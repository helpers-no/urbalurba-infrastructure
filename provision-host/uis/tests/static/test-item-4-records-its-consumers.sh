#!/bin/bash
# test-item-4-records-its-consumers.sh — the evidence for item 4 lives in the repo
#
# 🔵 urb-agents#1677: `urb-agents-console` is the first application to both deploy
# its own workload via `uis argocd register` AND depend on a platform service —
# with one generated credential and two given secrets, in a PUBLIC repository.
#
# Item 4's justification used to be a prediction about external developers. This
# is the first case where the seam costs SOMEONE ELSE'S HANDS: the author has no
# cluster access, so a third party must run `uis configure` first. That evidence
# arrived on the bus, and a bus thread is not where a plan's justification lives.
#
# ⚠️ Two over-claims this guards against, both tempting:
#   - that item 4 makes the GitOps story whole. It does not — a generated
#     credential is still minted imperatively. It makes the gap NAMED.
#   - that a concrete consumer summons a vault. Part 4 of the secrets
#     investigation argues item 4 is UPSTREAM of the vault either way.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
DOC="$REPO/website/docs/contributors/rules/application-deployment.md"

PASS=0; FAIL=0
pass() { echo -e "  Testing: $1... \033[0;32mPASS\033[0m"; ((++PASS)); }
fail() { echo -e "  Testing: $1... \033[0;31mFAIL\033[0m"; echo -e "    \033[0;31m→ $2\033[0m"; ((++FAIL)); }

echo "=== item 4 records its consumers and its limits ==="

[[ -f "$DOC" ]] || { fail "doc present" "missing: $DOC"; echo; echo "  Passed: $PASS  Failed: $FAIL"; exit 1; }

if grep -qF 'Per-workload named secrets' "$DOC"; then
    pass "control: the sequence table is still in the document"
else
    fail "control: item 4 exists" "every check below would be vacuous"
    echo ""; echo "  Passed: $PASS  Failed: $FAIL"; exit 1
fi

# --- the consumer, and what kind of evidence it is -------------------------
_n=0
grep -qF 'urb-agents-console' "$DOC" && _n=$((_n+1))
grep -qF "someone else's hands" "$DOC" && _n=$((_n+1))
if [[ "$_n" -eq 2 ]]; then
    pass "the second consumer is named, and so is what it demonstrates"
else
    fail "the consumer is recorded" "only $_n of 2 — the justification stays a prediction"
fi

# ⚠️ A new consumer must not read as a reordering.
if grep -qF 'It does not reorder anything' "$DOC"; then
    pass "it says the consumer confirms the order rather than revising it"
else
    fail "the ordering is unchanged" "a second consumer reads as a reprioritisation"
fi

# --- 🔴 the over-claim: item 4 does not make GitOps whole ------------------
_n=0
grep -qF 'still partial' "$DOC" && _n=$((_n+1))
grep -qF 'makes what is missing' "$DOC" && _n=$((_n+1))
if [[ "$_n" -eq 2 ]]; then
    pass "item 4 is documented as making the gap named, not closed"
else
    fail "the limit survives alongside the win" "only $_n of 2 — item 4 reads as closing GitOps"
fi

# --- 🔴 a consumer does not summon a vault --------------------------------
if grep -qF 'upstream of it either way' "$DOC"; then
    pass "the vault is placed downstream of item 4, with the reason"
else
    fail "the vault ordering is stated" "'we have a consumer now' becomes an argument for a vault"
fi

# --- 🔴 the Principle 0 objection to encrypted secrets in git --------------
# The objection is NOT secrecy — Sealed Secrets and SOPS are sound in a public
# repo. It is that they bind a secret to one key holder, so the same tree cannot
# come up on a laptop. A page that omits this invites the obvious wrong answer.
_n=0
grep -qF 'not secrecy, it is portability' "$DOC" && _n=$((_n+1))
grep -qF 'Principle 0' "$DOC" && _n=$((_n+1))
if [[ "$_n" -eq 2 ]]; then
    pass "encrypted-secrets-in-git is refused on portability, not on secrecy"
else
    fail "the real objection is stated" "only $_n of 2 — someone reads 'public repo' and reaches for SOPS"
fi

# --- and the two questions must stay separable ----------------------------
if grep -qF 'stays swappable' "$DOC"; then
    pass "naming a secret is kept separate from delivering one"
else
    fail "the two halves are decoupled" "the cheap half gets bound to the expensive one"
fi

echo ""
echo "  Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
