#!/bin/bash
# test-prometheus-alert-rules.sh — shipped alert rules must be able to CLEAR.
#
# 🔴 An alert that fires on a condition which never goes away does not add
# noise; it spends the credibility of the channel. `PodNotReady` matched every
# Completed Job pod — 0/1 and ready=false forever — so on a cluster running
# Dagster nightly the alert group could never empty and re-notified every four
# hours, permanently, to say that jobs which had succeeded were unready.
#
# ⚠️ The cost was not the false alerts. They sat beside a REAL one that had been
# firing for four days (a production database with no metrics since a reboot),
# invisible among alerts that never mean anything (ops, urb-agents#633).
#
# These are shape checks on the shipped manifest, not a Prometheus test: there
# is no promtool in this environment and a rule's behaviour needs a live TSDB.
# What can be checked here is what was actually wrong — an expression matching
# terminal pods, and rules that cannot be acted on.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"

REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
CONF="$REPO_ROOT/manifests/030-prometheus-config.yaml"

print_test_section "shipped Prometheus alert rules"

start_test "the config is where the test thinks it is"
[[ -f "$CONF" ]] && pass_test || { fail_test "no $CONF"; print_summary; exit $?; }

if ! command -v yq >/dev/null 2>&1; then
    start_test "yq is available to parse the rules"
    skip_test "yq not installed — cannot parse the manifest"
    print_summary
    exit $?
fi

start_test "the manifest parses"
yq '.' "$CONF" >/dev/null 2>&1 && pass_test || fail_test "invalid YAML"

_expr_of() { alert="$1" yq -r '.. | select(has("alert")) | select(.alert == strenv(alert)) | .expr' "$CONF" 2>/dev/null; }
_alerts()  { yq -r '.. | select(has("alert")) | .alert' "$CONF" 2>/dev/null; }

# ============================================================================
print_test_section "🔴 pod-level rules must exclude terminal pods"
# ============================================================================

start_test "PodNotReady still exists"
[[ -n "$(_expr_of PodNotReady)" ]] && pass_test || fail_test "rule missing — was it renamed?"

start_test "🔴 PodNotReady cannot match a Succeeded pod"
_e="$(_expr_of PodNotReady)"
[[ "$_e" == *"unless"* && "$_e" == *"Succeeded"* ]] && pass_test \
    || fail_test "a Completed Job pod is ready=false forever and this would alert until its TTL: $_e"

start_test "PodNotReady cannot match a Failed pod either"
[[ "$_e" == *"Failed"* ]] && pass_test \
    || fail_test "a failed pod is equally terminal and equally unable to clear"

start_test "🔴 excluding Failed did not silently drop the coverage"
# Excluding Failed from PodNotReady is only legitimate because something else
# reports a Job that gave up. If that rule goes, the exclusion becomes a hole.
_alerts | grep -q '^KubeJobFailed$' && pass_test \
    || fail_test "PodNotReady excludes Failed pods, so a job-failure rule must exist to replace it"

start_test "the job-failure rule reads the Job's condition, not its pod-attempt count"
_j="$(_expr_of KubeJobFailed)"
[[ "$_j" == *"kube_job_failed"* ]] && pass_test \
    || fail_test "kube_job_status_failed counts POD attempts and is >0 during a retry that then succeeds: $_j"

start_test "any other rule on kube_pod_status_ready also excludes terminal pods"
# The defect was a shape, not one line. Any future rule with the same predicate
# inherits the same trap.
_bad=""
while IFS= read -r a; do
    [[ -z "$a" ]] && continue
    e="$(_expr_of "$a")"
    [[ "$e" == *"kube_pod_status_ready"* ]] || continue
    [[ "$e" == *"Succeeded"* ]] || _bad+="$a "
done < <(_alerts)
[[ -z "$_bad" ]] && pass_test || fail_test "these match completed pods and cannot clear: $_bad"

# ============================================================================
print_test_section "every alert can be acted on"
# ============================================================================

start_test "every alert has a summary"
_missing=""
while IFS= read -r a; do
    [[ -z "$a" ]] && continue
    sm="$(alert="$a" yq -r '.. | select(has("alert")) | select(.alert == strenv(alert)) | .annotations.summary // ""' "$CONF" 2>/dev/null)"
    [[ -n "$sm" && "$sm" != "null" ]] || _missing+="$a "
done < <(_alerts)
[[ -z "$_missing" ]] && pass_test || fail_test "no summary: $_missing"

start_test "every alert has a severity"
_missing=""
while IFS= read -r a; do
    [[ -z "$a" ]] && continue
    sv="$(alert="$a" yq -r '.. | select(has("alert")) | select(.alert == strenv(alert)) | .labels.severity // ""' "$CONF" 2>/dev/null)"
    [[ -n "$sv" && "$sv" != "null" ]] || _missing+="$a "
done < <(_alerts)
[[ -z "$_missing" ]] && pass_test || fail_test "no severity: $_missing"

# ============================================================================
print_test_section "positive controls — does the check actually catch it?"
# ============================================================================

_ctl="$(mktemp)"
cat > "$_ctl" <<'CTL'
groups:
  - name: workloads
    rules:
      - alert: PodNotReady
        expr: |
          kube_pod_status_ready{condition="false"} == 1
        for: 15m
        labels: { severity: warning }
        annotations:
          summary: "unready"
CTL

start_test "positive control: the pre-fix expression IS caught"
_e_ctl="$(alert=PodNotReady yq -r '.. | select(has("alert")) | select(.alert == strenv(alert)) | .expr' "$_ctl")"
[[ "$_e_ctl" == *"unless"* && "$_e_ctl" == *"Succeeded"* ]] \
    && fail_test "the check does not discriminate — it passed the broken rule" || pass_test

start_test "positive control: a rule with no severity IS caught"
printf 'groups:\n  - name: x\n    rules:\n      - alert: NoSev\n        expr: up == 0\n        annotations: { summary: "s" }\n' > "$_ctl"
_sv="$(alert=NoSev yq -r '.. | select(has("alert")) | select(.alert == strenv(alert)) | .labels.severity // ""' "$_ctl")"
[[ -z "$_sv" || "$_sv" == "null" ]] && pass_test || fail_test "severity check does not discriminate"
rm -f "$_ctl"

print_summary
