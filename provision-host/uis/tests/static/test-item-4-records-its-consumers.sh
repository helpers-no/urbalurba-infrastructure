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

# ---------------------------------------------------------------------------
# urb-agents#1692 — a proposal that `uis argocd register` provision from a
# `requires:` block in the repository.
#
# 🔴 `requires:` already means TWO things here (service-to-service hard deps in
# service.schema.json; tenant-needs-another-application in template-info.yaml,
# checked against .uis.extend/applications.yaml). A third shape would make one
# keyword answer three questions across three files.
#
# ⚠️ And the 1.6.24 `requires` defect is the precedent: UIS read a field no
# registry entry ever carried. A declaration nothing writes looks supported and
# is not — the same failure as SCRIPT_CONFIGURABLE on services with no handler.
# ---------------------------------------------------------------------------

_n=0
grep -qF 'hard dependencies between **platform services**' "$DOC" && _n=$((_n+1))
grep -qF 'another installed application' "$DOC" && _n=$((_n+1))
if [[ "$_n" -eq 2 ]]; then
    pass "the two existing meanings of requires: are recorded"
else
    fail "both meanings are recorded" "only $_n of 2 — a third shape looks like a free slot"
fi

if grep -qF '1.6.24' "$DOC"; then
    pass "the 1.6.24 requires defect is cited as the precedent"
else
    fail "the precedent is cited" "a declaration nothing writes gets added again"
fi

# 🔴 The prerequisite that is easy to miss: item 3 is not done.
if grep -qF 'prerequisite for a provisioning declaration' "$DOC"; then
    pass "item 3 is named as a prerequisite, not a tidy-up"
else
    fail "item 3 is a prerequisite" "a provisioning declaration inherits the false advertisement"
fi

# The gap the proposal does not close.
if grep -qF 'does not restart the pod consuming it' "$DOC"; then
    pass "the secretKeyRef restart gap is stated against 'register provisions'"
else
    fail "the restart gap is stated" "register would succeed while the app keeps its old credential"
fi

# And the fork itself must stay a fork, not be silently decided.
_n=0
grep -qF 'the ArgoCD path gains provisioning' "$DOC" && _n=$((_n+1))
grep -qF 'become templates' "$DOC" && _n=$((_n+1))
if [[ "$_n" -eq 2 ]]; then
    pass "both arms of the fork are recorded for the maintainer"
else
    fail "the fork is recorded" "only $_n of 2 — one arm gets adopted by default"
fi

# ---------------------------------------------------------------------------
# urb-agents#1710 — what retracting SCRIPT_CONFIGURABLE actually costs.
#
# 🔵 The flag and the handler are independent: the work is done by a handler
# FILE that does not exist either way, so retracting turns one refusal into an
# earlier and more accurate one. Recording that stops the decision being
# re-litigated as "would it break something".
#
# 🔴 And the two service-specific findings, because both say the handler is
# the small part: authentik needs its blueprint MOUNT made dynamic (three
# static entries in a product values file, read at startup, one slot), and
# redis ACLs are lost on restart without an aclfile that is not configured.
# ---------------------------------------------------------------------------

_n=0
grep -qF 'flag and the handler are independent' "$DOC" && _n=$((_n+1))
grep -qF 'earlier and more accurate one' "$DOC" && _n=$((_n+1))
if [[ "$_n" -eq 2 ]]; then
    pass "retracting the flag changes the message, not the capability"
else
    fail "retraction is documented as safe" "only $_n of 2 — it reads as removing a capability"
fi

_n=0
grep -qF 'The delivery is the obstacle' "$DOC" && _n=$((_n+1))
grep -qF 'exactly one slot exists' "$DOC" && _n=$((_n+1))
if [[ "$_n" -eq 2 ]]; then
    pass "the authentik obstacle is named as the mount, and the slot count given"
else
    fail "the authentik obstacle is named" "only $_n of 2 — a handler gets estimated as a script"
fi

if grep -qF 'built before item 4 would add per-app keys' "$DOC"; then
    pass "building authentik before item 4 is recorded as making SEC-F5 worse"
else
    fail "the item 4 ordering is stated" "a handler would add keys to a Secret replicated everywhere"
fi

_n=0
grep -qF 'lives in memory' "$DOC" && _n=$((_n+1))
grep -qF 'no `aclfile`' "$DOC" && _n=$((_n+1))
if [[ "$_n" -eq 2 ]]; then
    pass "redis ACLs are documented as lost on restart without an aclfile"
else
    fail "the redis catch is recorded" "only $_n of 2 — a handler would provision a user that vanishes"
fi
echo ""
echo "  Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
