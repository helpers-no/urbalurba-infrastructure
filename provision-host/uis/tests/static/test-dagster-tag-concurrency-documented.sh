#!/bin/bash
# test-dagster-tag-concurrency-documented.sh — the tag-concurrency mechanism
# ships generic; no tenant's rule ships with it
#
# 🔴 THE PRODUCT MANIFEST MUST NEVER NAME A TENANT'S TAG. The platform ships the
# MECHANISM (`concurrency.runs.tagConcurrencyLimits`, empty) in
# manifests/360-dagster-config.yaml; an installation's actual rule belongs in
# `.uis.extend/dagster-code-locations.yaml`'s `tag_concurrency_limits:`, never in
# the file every installation gets. See urb-agents#1847/#1850 for why this
# mechanism exists at all, and the doc page for the full worked example.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
MANIFEST="$REPO/manifests/360-dagster-config.yaml"
EXTEND_TEMPLATE="$REPO/provision-host/uis/templates/uis.extend/dagster-code-locations.yaml.default"
DOC="$REPO/website/docs/services/analytics/dagster.md"
PLAYBOOK="$REPO/ansible/playbooks/360-setup-dagster.yml"

PASS=0; FAIL=0
pass() { echo -e "  Testing: $1... \033[0;32mPASS\033[0m"; ((++PASS)); }
fail() { echo -e "  Testing: $1... \033[0;31mFAIL\033[0m"; echo -e "    \033[0;31m→ $2\033[0m"; ((++FAIL)); }

echo "=== Dagster tag-based run concurrency: mechanism ships, tenant rules do not ==="

for f in "$MANIFEST" "$EXTEND_TEMPLATE" "$DOC" "$PLAYBOOK"; do
    [[ -f "$f" ]] || { fail "file present: $f" "missing"; echo; echo "  Passed: $PASS  Failed: $FAIL"; exit 1; }
done

if grep -qF 'maxConcurrentRuns: 4' "$MANIFEST"; then
    pass "control: the manifest is readable and has the existing cap"
else
    fail "control: the manifest is readable" "every check below would be vacuous"
    echo ""; echo "  Passed: $PASS  Failed: $FAIL"; exit 1
fi

# The mechanism must be present in the shipped product manifest.
if grep -qF 'tagConcurrencyLimits: []' "$MANIFEST"; then
    pass "the manifest ships tagConcurrencyLimits, empty"
else
    fail "tagConcurrencyLimits present and empty in the product manifest" "mechanism missing, or shipped non-empty"
fi

# It must explain WHY run_coordinator-level config is the wrong application point.
_n=0
grep -qF 'runCoordinator' "$MANIFEST" && _n=$((_n+1))
grep -qF 'incompatible' "$MANIFEST" && _n=$((_n+1))
if [[ "$_n" -eq 2 ]]; then
    pass "the run_coordinator-vs-concurrency-block conflict is documented"
else
    fail "the wrong application point is named and why it conflicts" "only $_n of 2 — invites re-adding the incompatible shape"
fi

# The per-installation extension point must exist and be documented.
if grep -qF 'tag_concurrency_limits: []' "$EXTEND_TEMPLATE"; then
    pass "the extend template ships the tag_concurrency_limits extension point"
else
    fail "tag_concurrency_limits: [] present in the extend template" "missing"
fi

if grep -qF 'atlas/serialises-on' "$EXTEND_TEMPLATE"; then
    pass "the worked example uses the real incident's tag, not an invented one"
else
    fail "a worked example is present" "missing or uses an unreferenced example"
fi

# The playbook must actually read and render the new key, not just the template
# describing it.
_n=0
grep -qF '_tag_concurrency_limits' "$PLAYBOOK" && _n=$((_n+1))
grep -qF 'tagConcurrencyLimits' "$PLAYBOOK" && _n=$((_n+1))
if [[ "$_n" -eq 2 ]]; then
    pass "the setup playbook reads and renders tag_concurrency_limits"
else
    fail "the playbook wires the new key through to Helm" "only $_n of 2 — the template's promise is not implemented"
fi

# Doc page: the mechanism, the tenant-namespacing convention, and the queuing
# cost all need to be stated, not just the existence of a heading.
_n=0
grep -qF 'tagConcurrencyLimits' "$DOC" && _n=$((_n+1))
grep -qiE 'tenant-namespace' "$DOC" && _n=$((_n+1))
grep -qiE 'queuing cost' "$DOC" && _n=$((_n+1))
if [[ "$_n" -eq 3 ]]; then
    pass "the doc covers the mechanism, the naming convention, and the cost"
else
    fail "the doc explains mechanism + convention + cost" "only $_n of 3"
fi

echo ""
echo "  Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
