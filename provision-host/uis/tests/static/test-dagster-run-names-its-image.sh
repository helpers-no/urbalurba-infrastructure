#!/bin/bash
# test-dagster-run-names-its-image.sh — a green run must say which image ran.
#
# urb-agents#1272, measured on 2026-09-19: two consecutive `uis dagster run`
# invocations reported SUCCESS in 136.3 s and 129.5 s and EXECUTED THE PREVIOUS
# BUILD. dbt built the model, the tests passed, the job was green — and the
# release's post-hooks were not in the image that ran, so they never executed
# and no surface said why.
#
# 🔴 The code location pod was CORRECT, and so was its DAGSTER_CURRENT_IMAGE.
# Dagster resolves a run's image from the webserver's CACHED code-location
# handle, not from the live Deployment, and the webserver pod was two days old.
# So every existing check passed while every run was wrong.
#
# These assertions pin the two surfaces that now answer it: the run reports the
# image it executed, and verify notices a webserver older than the code
# location it must serve.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"

if [[ -d "/mnt/urbalurbadisk/ansible" ]]; then
    REPO="/mnt/urbalurbadisk"
else
    REPO="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
fi
RUN="$REPO/ansible/playbooks/362-dagster-run.yml"
VERIFY="$REPO/ansible/playbooks/360-test-dagster.yml"

_code_only() { grep -vE '^[[:space:]]*#' "$@"; }

print_test_section "a green Dagster run must name the image it executed"

start_test "both playbooks exist"
if [[ -f "$RUN" && -f "$VERIFY" ]]; then pass_test; else fail_test "missing playbook"; fi

start_test "the run reads the image from the RUN POD, keyed on the run id"
# The run pod's own spec is the only honest source. Reading the Deployment would
# reproduce the defect exactly: that was correct while the runs were not.
if _code_only "$RUN" | grep -qF 'dagster/run-id={{ _run_id }}'; then
    pass_test
else
    fail_test "the executed image is not read from the run pod for this run"
fi

start_test "the run compares it against what the code location advertises"
# Printing it is not enough. A human reading two long digests will not spot a
# difference; the comparison has to be the machine's job.
if _code_only "$RUN" | grep -qF 'THESE DISAGREE'; then
    pass_test
else
    fail_test "the two images are printed but never compared"
fi

start_test "an unreadable image is reported, not silently omitted"
# An absent line is indistinguishable from agreement, which is the failure mode
# being fixed rather than a smaller version of it.
if _code_only "$RUN" | grep -qF 'NOT compared'; then
    pass_test
else
    fail_test "a missing image would read as agreement"
fi

start_test "verify notices a webserver older than the code location"
if _code_only "$VERIFY" | grep -qF 'STALE'; then
    pass_test
else
    fail_test "verify still answers only 'is the code location correct', which passed during the incident"
fi

start_test "verify distinguishes 'could not look' from 'not stale'"
# A renamed chart label returns empty, and empty must not read as healthy.
if _code_only "$VERIFY" | grep -qF 'UNREADABLE'; then
    pass_test
else
    fail_test "an empty read would pass as fresh"
fi

start_test "both remedies name the rollout restart, since deploy will not do it"
_n=0
grep -qF 'rollout restart deploy/dagster-dagster-webserver' "$RUN" && _n=$((_n+1))
grep -qF 'rollout restart deploy/dagster-dagster-webserver' "$VERIFY" && _n=$((_n+1))
if [[ "$_n" -eq 2 ]]; then
    pass_test
else
    fail_test "only $_n of 2 surfaces tell the operator how to fix it"
fi

# ---------------------------------------------------------------------------
# 1.6.133: a warning nobody sees is not a warning.
#
# urb-agents#1278. F3 fired correctly on a real cluster and was still unusable:
# the exit code was 0 and THE SUMMARY WAS IDENTICAL TO A HEALTHY ONE, so the
# only evidence lived 27 tasks up-scroll in a stream an operator running
# `./uis dagster verify | tail -20` has already piped away.
# ---------------------------------------------------------------------------

start_test "the handle verdict reaches the SUMMARY, not only the task stream"
if _code_only "$VERIFY" | grep -qF '"F. Code-location handle:'; then
    pass_test
else
    fail_test "a stale handle leaves the summary indistinguishable from healthy"
fi

start_test "the summary verdict is computed once, so it cannot disagree with the gate"
# Two independent reads of _handle_age could print FRESH and fail as STALE.
if _code_only "$VERIFY" | grep -qF '_handle_verdict'; then
    pass_test
else
    fail_test "the summary and the exit code derive the verdict separately"
fi

start_test "the advisory exit code is stated in the output, not just chosen"
# "If advisory is deliberate, saying so is the difference between a decision and
# an omission." An operator must learn it from the output, not the source.
if _code_only "$VERIFY" | grep -qF 'ADVISORY'; then
    pass_test
else
    fail_test "exiting 0 under STALE is silent, which is how #1278 described the defect"
fi

start_test "--strict can turn a stale handle into a failure"
_n=0
_code_only "$VERIFY" | grep -qF 'strict | default(false)' && _n=$((_n+1))
grep -qF -- '--strict' "$REPO/provision-host/uis/manage/uis-cli.sh" && _n=$((_n+1))
if [[ "$_n" -eq 2 ]]; then
    pass_test
else
    fail_test "only $_n of 2 — a script cannot gate on a stale handle"
fi

start_test "the agreeing path prints a verdict, not two strings to eyeball"
# The whole reason the comparison is the machine's job: it reads fine with short
# tags that differ visibly, and does not with sha256: digests.
if _code_only "$RUN" | grep -qF 'they agree'; then
    pass_test
else
    fail_test "when the images match, the comparison is left to the reader"
fi

print_summary
