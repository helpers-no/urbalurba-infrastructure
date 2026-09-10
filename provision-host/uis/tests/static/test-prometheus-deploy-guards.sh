#!/bin/bash
# test-prometheus-deploy-guards.sh — the prometheus deploy must not report
# success while its own workload is broken.
#
# 🔴 TWO DEFECTS, both measured on production by ops (urb-agents#660):
#
# 1. `chat_id: 0` was substituted when ALERTMANAGER_TELEGRAM_CHAT_ID was unset,
#    with a comment saying the alternative "would make Alertmanager fail to load
#    its config, which takes ALL alerting down." Alertmanager treats 0 as absent
#    and refuses the config identically — so the mitigation caused the outcome it
#    was written to prevent, on every installation without a chat id.
#
# 2. The play waited for `component=server` only, then printed
#    "✓ Prometheus deployed successfully" while prometheus-alertmanager-0 sat in
#    CrashLoopBackOff. Alerting was down eight minutes.
#
# ⚠️ Alertmanager is the one workload whose failure suppresses every other
# signal, and it was the one the deploy did not look at.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"

REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
PB="$REPO_ROOT/ansible/playbooks/030-setup-prometheus.yml"
VALUES="$REPO_ROOT/manifests/030-prometheus-config.yaml"

print_test_section "prometheus deploy: the alerting path"

start_test "the playbook and values file are where the test thinks they are"
[[ -f "$PB" && -f "$VALUES" ]] && pass_test || { fail_test "missing $PB or $VALUES"; print_summary; exit $?; }

# ============================================================================
print_test_section "🔴 a config Alertmanager will refuse must never be rendered"
# ============================================================================

start_test "no task substitutes 'chat_id: 0'"
# ⚠️ Non-comment lines only. The comment explaining this fix quotes the old
# value, and the first version of this assertion fired on that — a check that
# cannot tell what the code DOES from what the code SAYS ABOUT ITSELF.
if grep -v '^\s*#' "$PB" | grep -q 'chat_id: 0'; then
    fail_test "0 is not a chat id; Alertmanager reads it as absent and refuses the whole config"
else
    pass_test
fi

start_test "the disable path removes telegram_configs instead"
grep -q 'del(.alertmanager.config.receivers\[\] | select(.name == "telegram") | .telegram_configs)' "$PB" \
    && pass_test || fail_test "a receiver with a name and no configs is the valid way to discard notifications"

start_test "a token with no chat id is REFUSED, not silently degraded"
# Somebody created a bot and the delivery target is missing. Discarding every
# alert by default is how an outage goes unnoticed for days.
grep -q 'ALERTMANAGER_TELEGRAM_CHAT_ID is empty but a bot token IS configured' "$PB" \
    && pass_test || fail_test "token-set/chat-id-unset must fail the play"

start_test "and that refusal names an override rather than being a dead end"
grep -q 'alertmanager_allow_no_receiver' "$PB" \
    && pass_test || fail_test "a guard with no documented override gets worked around badly"

start_test "the no-receiver warning names WHICH half is missing"
# It was gated on the token alone, so the one broken combination was silent.
_w="$(awk '/4.3 Warn when alerting has no receiver/,/^    - name: "4\.4/' "$PB")"
[[ "$_w" == *"_tg_chat"* && "$_w" == *"_tg_token"* ]] \
    && pass_test || fail_test "the warning must consider both credentials"

start_test "a leftover placeholder is caught before Helm sees it"
grep -q 'still contains' "$PB" && grep -q 'TELEGRAM_CHAT_ID_PLACEHOLDER' "$PB" \
    && pass_test || fail_test "neither substitution firing must not install a config that cannot load"

start_test "the placeholder guard reads grep's COUNT, not its exit code"
# ⚠️ grep exits 1 with a count of 0 when it matches nothing, so rc would treat
# "no placeholder" as failure and "grep could not run" as success.
grep -q '_placeholder_left.stdout | default' "$PB" \
    && pass_test || fail_test "reading rc here inverts the meaning"

# ============================================================================
print_test_section "🔴 the deploy must check every pod it owns"
# ============================================================================

start_test "readiness is checked across the release, not one component"
grep -q 'app.kubernetes.io/instance=prometheus' "$PB" \
    && pass_test || fail_test "waiting on component=server alone is what missed Alertmanager"

_until="$(awk '/6b\. Wait for EVERY pod the release owns/,/changed_when: false/' "$PB")"

start_test "🔴 its until requires rc == 0 — a failed kubectl prints nothing"
[[ "$_until" == *"_stack_ready.rc == 0"* ]] \
    && pass_test || fail_test "empty output would otherwise read as 'no unready pods'"

start_test "🔴 its until requires the check to have SEEN pods"
# If the selector is wrong this finds none, and an empty unready list passes
# vacuously. A check that cannot see the workload must fail, not succeed.
[[ "$_until" == *"| first | int) > 0"* ]] \
    && pass_test || fail_test "a vacuous pass is the failure mode of every check like this"

start_test "the failure distinguishes 'not ready' from 'could not look'"
grep -q 'COULD NOT CHECK pod readiness' "$PB" \
    && pass_test || fail_test "could-not-check is not a negative answer"

start_test "the failure names the pods and shows evidence"
grep -q 'never became Ready' "$PB" && grep -q '_stack_evidence' "$PB" \
    && pass_test || fail_test "a failure an operator cannot act on costs another round"

# ============================================================================
print_test_section "positive controls"
# ============================================================================

_ctl="$(mktemp)"

start_test "positive control: 'chat_id: 0' in a TASK is caught"
printf 'sed -i "s/x/chat_id: 0/" f\n' > "$_ctl"
grep -v '^\s*#' "$_ctl" | grep -q 'chat_id: 0' && pass_test || fail_test "the grep does not match its own target"

start_test "negative control: 'chat_id: 0' in a COMMENT is not caught"
printf '# it used to substitute chat_id: 0 and that was the defect\n' > "$_ctl"
grep -v '^\s*#' "$_ctl" | grep -q 'chat_id: 0' && fail_test "a comment about the defect is not the defect" || pass_test

start_test "positive control: an until without rc IS caught"
printf 'until: >\n  _x.stdout | int == 0\n' > "$_ctl"
_c="$(cat "$_ctl")"
[[ "$_c" != *".rc == 0"* ]] && pass_test || fail_test "the check does not discriminate"
rm -f "$_ctl"

start_test "the values file still declares exactly one receiver the route names"
if command -v yq >/dev/null 2>&1; then
    _r="$(yq -r '.alertmanager.config.route.receiver' "$VALUES")"
    _n="$(yq -r '[.alertmanager.config.receivers[].name] | join(",")' "$VALUES")"
    [[ ",$_n," == *",$_r,"* ]] && pass_test || fail_test "route names '$_r'; receivers are '$_n'"
else
    skip_test "yq not installed"
fi

print_summary
