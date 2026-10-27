#!/bin/bash
# test-reflector-epinio-collision-guard.sh — urb-agents#2044 (imac, live)
#
# Epinio's own upstream Helm chart already bundles emberstack/reflector as a subchart
# dependency, including a cluster-scoped ClusterRole literally named "reflector" - a
# standalone install of the same chart under a different release name collides with it
# and Helm correctly refuses. reflector has no release-scoped RBAC of its own design, so
# any already-running controller satisfies this service's whole purpose regardless of
# which release owns it. This asserts the detect-and-skip logic is actually there, both
# in the setup playbook and in the service's own check command (which must agree, or
# `uis status` would report "not deployed" when the capability is already satisfied).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"

REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
PLAYBOOK="$REPO_ROOT/ansible/playbooks/028-setup-reflector.yml"
SERVICE="$REPO_ROOT/provision-host/uis/services/management/service-reflector.sh"

print_test_section "reflector detects an existing controller before installing a second one"

start_test "the playbook and service files are where this test thinks they are"
if [[ -f "$PLAYBOOK" && -f "$SERVICE" ]]; then
    pass_test
else
    fail_test "missing one of: $PLAYBOOK, $SERVICE"
    print_summary
    exit 1
fi

pb="$(grep -v '^[[:space:]]*#' "$PLAYBOOK")"

start_test "control: the scan still sees real tasks"
if grep -qF 'kubernetes.core.k8s_info' <<< "$pb"; then
    pass_test
else
    fail_test "control" "comment-stripping removed everything — every check below is vacuous"
    print_summary
    exit 1
fi

start_test "checks for an existing reflector controller CLUSTER-WIDE (-A), not scoped to its own namespace"
grep -qF 'kubectl get pods -A -l app.kubernetes.io/name=reflector' <<< "$pb" \
    && pass_test \
    || fail_test "no cluster-wide check found" "Epinio's own bundled reflector lives in the epinio namespace, not the reflector namespace — a namespace-scoped check would never see it"

start_test "🔴 namespace creation and the Helm install are both gated on NOT already present"
if grep -qF 'when: not reflector_already_present' <<< "$pb"; then
    _gated_count="$(grep -cF 'when: not reflector_already_present' <<< "$pb")"
    if [[ "$_gated_count" -ge 2 ]]; then
        pass_test
    else
        fail_test "only $_gated_count task(s) gated, expected at least 2 (namespace create + helm install)"
    fi
else
    fail_test "no gating found" "would attempt a colliding Helm install every time this runs on a cluster where Epinio is already deployed — the exact combination this service exists for"
fi

start_test "the service's own SCRIPT_CHECK_COMMAND agrees — also cluster-wide, not namespace-scoped"
if grep -qF 'kubectl get pods -A -l app.kubernetes.io/name=reflector' "$SERVICE"; then
    pass_test
else
    fail_test "SCRIPT_CHECK_COMMAND not cluster-wide" "uis status/deploy would report 'not deployed' even when Epinio's bundled copy already satisfies this service's whole purpose"
fi

# 🔴 urb-agents#2045 (imac, live): the detection task's jsonpath value has an unquoted
# space inside `{range .items[*]}` - ansible.builtin.command's own shlex-based argument
# splitting breaks it into two argv tokens, and kubectl errors on a stray second
# argument. The whole jsonpath value must be single-quoted.
start_test "🔴 the jsonpath detection command is quoted, not split by its own internal space"
if grep -qF -- "-o 'jsonpath={range .items[*]}" <<< "$pb"; then
    pass_test
elif grep -qF "jsonpath={range .items[*]}" <<< "$pb"; then
    fail_test "jsonpath value is unquoted" "found live by imac: ansible.builtin.command's shlex-based splitting breaks on the space inside {range .items[*]}, and kubectl errors on a stray second argument"
else
    fail_test "could not find the jsonpath detection command at all" "has task 6 moved or been renamed?"
fi

print_summary
