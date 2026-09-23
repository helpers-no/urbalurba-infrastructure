#!/bin/bash
# test-secret-version-propagation.sh — a pod that reads a secret must say what
# happens when the secret changes.
#
# urb-agents#1415. A secretKeyRef env var binds at CONTAINER START. If nothing
# in the pod template changes when the secret does, a re-applied secret reaches
# no running pod — and every surface reports success: the deploy exits 0, the
# pod is healthy, the rollout completes, and the only symptom is a process
# holding a value that is no longer true.
#
# 🔴 TWO OF TWO EXAMINED WERE DEFECTS, AND NEITHER WAS FOUND BY READING.
# oauth2-proxy (1.6.126) surfaced through a credential rotation that rolled
# nothing. postgrest (1.6.144) surfaced because a published document advertised
# the wrong hostname. Ten more consumed a secretKeyRef and had never been
# looked at.
#
# 🔵 THE GATE ENUMERATES; IT DOES NOT CONSULT A LIST. A hand-maintained list of
# exempt files keeps entries for files that no longer exist — which is the
# defect the checker exists to catch, one level up. The reason lives next to
# the secretKeyRef, so deleting the file deletes the exemption with it.
#
# Three states, all of them explicit:
#   the annotation          the pod template changes when the secret does
#   SECRET-VERSION: none    examined, genuinely does not need it, with a reason
#   SECRET-VERSION: pending examined, needs it, not done yet, with a reason
#
# ⚠️ `pending` PASSES. The gate's job is that nothing is added unexamined and
# nothing is silent — not to hold the build hostage to work that is scheduled.
# The count is printed every run so it cannot quietly grow.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"

if [[ -d "/mnt/urbalurbadisk/manifests" ]]; then
    REPO="/mnt/urbalurbadisk"
else
    REPO="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
fi

print_test_section "a secretKeyRef must say what happens when the secret changes"

_consumers() {
    local f
    for f in $(grep -rl "secretKeyRef" "$REPO/manifests" "$REPO/ansible" 2>/dev/null); do
        grep -qE "kind: (Deployment|StatefulSet|DaemonSet|Job|CronJob|Pod)" "$f" || continue
        echo "$f"
    done
}

start_test "the sweep finds pod templates that consume a secret"
# An empty result here would make every check below vacuous, and the whole
# point of this gate is that an empty result is the thing to distrust.
_n=$(_consumers | wc -l)
if [[ "$_n" -ge 5 ]]; then
    pass_test
else
    fail_test "only $_n pod templates found consuming secretKeyRef — the sweep is broken, not the repo"
fi

start_test "every one of them is annotated or carries a reasoned SECRET-VERSION marker"
_unmarked=""
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    grep -q 'urbalurba.io/secret-version' "$f" && continue
    grep -qE '#\s*SECRET-VERSION:\s*(none|pending)\b' "$f" && continue
    _unmarked="$_unmarked
    ${f#$REPO/}"
done <<< "$(_consumers)"
if [[ -z "$_unmarked" ]]; then
    pass_test
else
    fail_test "these read a secret and say nothing about what happens when it changes:$_unmarked"
fi

start_test "no marker is a bare verdict without a reason"
# "SECRET-VERSION: none" alone is a boolean wearing a comment's clothes. The
# reasons differ — "never rotated" and "the process re-reads it" are different
# claims with different risks — and hiding that behind a word loses it.
_bare=""
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if grep -qE '#\s*SECRET-VERSION:\s*(none|pending)\s*$' "$f"; then
        _bare="$_bare ${f#$REPO/}"
    fi
done <<< "$(_consumers)"
if [[ -z "$_bare" ]]; then
    pass_test
else
    fail_test "marker with no reason given:$_bare"
fi

start_test "the two services that were fixed still carry the annotation"
# Regression guard: these are the only two known-correct cases, and both were
# found the hard way.
_n=0
grep -q 'urbalurba.io/secret-version' "$REPO/manifests/072-oauth2-proxy-deployment.yaml.j2" && _n=$((_n+1))
grep -q 'urbalurba.io/secret-version' "$REPO/ansible/playbooks/templates/088-postgrest-config.yml.j2" && _n=$((_n+1))
if [[ "$_n" -eq 2 ]]; then
    pass_test
else
    fail_test "only $_n of 2 fixed services still annotated"
fi

# Visible every run, so the remaining work cannot quietly grow.
_pend=$(_consumers | xargs grep -lE '#\s*SECRET-VERSION:\s*pending' 2>/dev/null | wc -l)
echo "  ℹ pod templates still pending the annotation: $_pend"

print_summary
