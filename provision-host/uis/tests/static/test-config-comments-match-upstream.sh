#!/bin/bash
# test-config-comments-match-upstream.sh — a comment that misdescribes a setting
# becomes the basis of a decision.
#
# 🔴 `manifests/360-dagster-config.yaml` carried the comment "Run-history
# retention is left at the chart default". The setting is TICK retention — the
# Dagster chart's own header says "data types such as schedule / sensor ticks",
# and the chart has no run-purge at all.
#
# ⚠️ The cost was not confusion. I reasoned from my own label instead of the
# chart and told ops-dev that enabling it would reap 35,040 run records a year,
# on a question they were about to put to Terje. It would not have removed one
# (#811).
#
# A wrong comment is more expensive than no comment: it is read as evidence.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
CFG="$REPO_ROOT/manifests/360-dagster-config.yaml"

PASS=0; FAIL=0
pass() { echo -e "  Testing: $1... \033[0;32mPASS\033[0m"; ((++PASS)); }
fail() { echo -e "  Testing: $1... \033[0;31mFAIL\033[0m"; echo -e "    \033[0;31m→ $2\033[0m"; ((++FAIL)); }

echo "=== config comments must describe what the setting does ==="

if [[ ! -f "$CFG" ]]; then
    fail "the dagster config is present" "missing: $CFG"
    echo ""; echo "  Passed: $PASS  Failed: $FAIL"; exit 1
fi

# The retention block and the comment immediately above it.
_block="$(awk '/^# .*TICK RETENTION|^# Run-history retention/,/^  enabled:/' "$CFG")"
[[ -z "$_block" ]] && _block="$(grep -B25 '^retention:' "$CFG")"

if grep -qi 'tick' <<< "$_block"; then
    pass "🔴 the retention comment says it governs TICKS"
else
    fail "🔴 the retention comment says it governs TICKS" \
         "the chart's header is 'data types such as schedule / sensor ticks'"
fi

# ⚠️ Matches the CLAIM, not the words. "Run-history retention is left at..." is
# the wrong claim; "this is not run-history retention" is the right one and
# contains the same words.
if grep -qiE '^#[^\n]*Run-history retention is' <<< "$_block"; then
    fail "the comment does not claim to be run-history retention" \
         "this setting removes no run records; no chart setting does"
else
    pass "the comment does not claim to be run-history retention"
fi

if grep -qiE 'no run-purge|NOT RUN-HISTORY|separate, unsolved' <<< "$_block"; then
    pass "it says run growth is a separate problem this does not solve"
else
    fail "it says run growth is a separate problem this does not solve" \
         "without that, the next reader re-derives the same wrong recommendation"
fi

# ── enabling it is a measured decision, and the values must be readable here ──
if grep -qE '^  enabled: true' <<< "$_block"; then
    pass "retention is enabled"
else
    fail "retention is enabled" "measured at 5.4% of the DB and left off"
fi

# ⚠️ Written out rather than inherited. A reader must not have to fetch the
# chart to learn what this deletes — which is the failure the comment records.
# ⚠️ NOT an awk range ending on `^[a-zA-Z#]`: `retention:` matches that pattern
# itself, so the range closed on its own start line and captured one line. It
# reported the config as missing values the config plainly had — a test failing
# against correct code, which is the third time tonight.
_ret="$(sed -n '/^retention:/,/^$/p' "$CFG")"
if grep -q 'skipped: 7' <<< "$_ret" && grep -q 'failure: -1' <<< "$_ret"; then
    pass "🔴 what it purges is stated in this file, not inherited"
else
    fail "🔴 what it purges is stated in this file, not inherited"          "enabled: true with no visible sub-values hides what gets deleted"
fi

if grep -q 'autoMaterialize' <<< "$_ret"; then
    pass "auto-materialize ticks are covered — the high-volume writer"
else
    fail "auto-materialize ticks are covered"          "a sensor-driven tenant's ticks are autoMaterialize, not sensor"
fi

# The concurrency cap comment makes a claim about a shared database; that one is
# correct and load-bearing, so it should stay.
if grep -q 'maxConcurrentRuns' "$CFG" && grep -qi 'shared\|hammer' "$CFG"; then
    pass "the concurrency cap still explains WHY it is a platform policy"
else
    fail "the concurrency cap still explains why" "the reason is what stops it being raised on request"
fi

# ── the run-pod resources block was INERT, and must not come back ───────────
# 🔴 REPLACES five assertions that checked the CONTENT of a setting which turned
# out to have no effect. 1.6.92 added `config.k8sRunLauncher.resources`, 1.6.93
# raised it to 1Gi, and imac then read the live object: run pods were created
# with the CODE-LOCATION default of 384Mi (ops-dev, urb-agents#1026).
#
# ⚠️ Those assertions were not wrong about the file. They were wrong about the
# world, and they passed the whole time. Replaced rather than deleted, because a
# deleted control and a satisfied control look identical in a green run.
#
# 🔵 Why it is inert, from chart dagster-1.13.19 rather than inferred:
# `includeConfigInLaunchedRuns` defaults true, which puts the deployment's whole
# container context — INCLUDING `resources` — on
# DAGSTER_CLI_API_GRPC_CONTAINER_CONTEXT; the chart calls the run launcher's own
# value a "Default". The code location's context is merged over it and wins.
_rl_code="$(sed -n '/^runLauncher:/,/^[a-z]/p' "$CFG" | grep -v '^[[:space:]]*#')"

if ! grep -q 'k8sRunLauncher' <<<"$_rl_code"; then
    pass "🔴 no inert run-launcher resources block — it never reached run pods"
else
    fail "🔴 no inert run-launcher resources block" \
         "a setting that looks like it sizes run pods and does not is worse than none: the next person sizes it and measures nothing"
fi

# ⚠️ AND THE FILE MUST SAY WHY, or the next reader re-adds it for the same
# reason it was added the first time.
if grep -q 'includeConfigInLaunchedRuns' "$CFG"; then
    pass "⚠️ the file records the mechanism that makes it inert"
else
    fail "⚠️ the file records the mechanism" "removal without the reason invites the re-add"
fi

if grep -q 'PRECEDENCE against the container context is NOT' "$CFG"; then
    pass "🔵 and names the lever whose precedence it has NOT established, rather than using it"
else
    fail "🔵 it names what is not established" \
         "guessing a precedence is how the inert block came to exist"
fi

# 🔴 `includeConfigInLaunchedRuns: false` would make the run launcher's value
# win — and stop the code location's env reaching run pods, which is the defect
# where a check's variable never arrived (#957).
# ⚠️ Pattern verified against the file's actual bytes BEFORE being written into
# the assertion. The first version required the phrase and the flag name on one
# line, which backticks around the flag broke, and its fallback was lowercase
# where the file is uppercase — so it matched nothing and failed a correct file.
# That is the fifth pattern-versus-target mismatch of the day.
if grep -q 'env_secrets' "$CFG" && grep -qF 'IS NOT AN OPTION' "$CFG"; then
    pass "🔴 it records why disabling that flag is not the way out"
else
    fail "🔴 it records why disabling the flag is not the way out" \
         "turning it off would break the env delivery the memory argument was in service of"
fi

# ⚠️ The concurrency cap is platform policy and must survive an edit to the
# block above it — a first version of this change deleted it along with the
# inert resources, and the test caught that.
if grep -qE '^\s+maxConcurrentRuns: [0-9]+' "$CFG"; then
    pass "⚠️ the concurrency cap is still set — it is policy, not part of the removal"
else
    fail "⚠️ the concurrency cap is still set" "removing the inert block took platform policy with it"
fi

# 🔵 And its coupling note now points at the lever that actually applies.
if grep -q "COUPLED TO THE CODE LOCATION'S" "$CFG"; then
    pass "🔵 the coupling note points at the code location, not at this file"
else
    fail "🔵 the coupling note points at the real lever" \
         "pointing at a setting that does nothing is the same defect one layer up"
fi

# ── the start-timeout comment must not name a cure it has not established ────
# 🔴 THE SAME DEFECT AS THE RETENTION COMMENT ABOVE, one setting down. For
# every release from 1.5.2 to 1.6.106 this comment said the cost was building
# the execution plan and that "the durable fix is on the tenant side — splitting
# a monolithic job". atlas read Dagster's source and both halves were wrong:
# plan construction is 0.01 s, and the cost is one per-check event written at
# RUN CREATION (urb-agents#1147, atlas#319).
#
# ⚠️ The cost was not confusion here either. The tenant was on the point of
# decomposing a job to satisfy a diagnosis this file asserted and had never
# checked.
_rm="$(sed -n '/^  runMonitoring:/,/^    startTimeoutSeconds:/p' "$CFG")"

# \u26a0\ufe0f MATCHED AGAINST THE BLOCK WITH ITS COMMENT MARKERS AND LINE BREAKS
# REMOVED, not against the raw lines. Every claim asserted below is longer than
# one wrapped comment line, so a raw-line pattern is dead the moment someone
# reflows the paragraph \u2014 and it dies SILENTLY, still green.
#
# \U0001f534 That is not hypothetical. The first version of these assertions matched
# "UIS has not re-read" on raw lines; the file wraps after "UIS has", so that
# alternative could never match anything. It passed on its other alternative and
# looked fine, and the mutation written to break it edited across the same line
# break and changed nothing. A dead pattern and a satisfied one are identical in
# a green run \u2014 the same trap the run-launcher assertions above fell into.
_rmflat="$(tr '\n' ' ' <<<"$_rm" | sed 's/#/ /g; s/  */ /g')"

if [[ -z "$_rm" ]]; then
    fail "the run-monitoring block is readable" "sed range matched nothing in $CFG"
elif grep -qiE 'lever is the tenant|durable fix is on the tenant side|splitting a monolithic job so|smaller jobs each pay' <<<"$_rmflat" \
     && ! grep -qiE 'NOT ESTABLISHED|store_event_batch' <<<"$_rmflat"; then
    fail "🔴 a tenant-side fix is named only with the evidence for it" \
         "1.6.107 removed this claim BECAUSE it was asserted bare, and a tenant decomposed a job for a reason that might not have been the reason"
else
    pass "🔴 a tenant-side fix is named only with the evidence for it"
fi

# 🔴 LIFETIME, NOT DEPTH — and this assertion exists because I got it wrong.
# I predicted the connection COUNT would read 1-3 during a launch and told the
# measurer that a stable count meant "pooled". It read ~23: the webserver, the
# daemon and a run pod hold connections while the churn happens underneath.
# Anyone repeating my guidance clears NullPool from the right query read the
# wrong way (urb-agents#1160).
if grep -qiE 'LIFETIME, NOT DEPTH' <<<"$_rmflat" \
   && grep -qiE 'uninformative in both directions' <<<"$_rmflat"; then
    pass "🔴 it says to measure connection LIFETIME, and that depth decides nothing"
else
    fail "🔴 it names lifetime as the discriminator" \
         "depth mixes a held cohort with a churning one and reads as neither — the next reader repeats the mistake this file records"
fi

# ⚠️ AND IT IS A LATENCY, NOT A FAILURE. `PythonError: too many retries for DB
# connection` was a hypothesis from #1046 and does not reproduce — two launches
# succeeded with zero occurrences of it. A file that still describes a failure
# sends the next reader hunting an exception nothing raises.
if grep -qiE 'DOES NOT REPRODUCE' <<<"$_rmflat" \
   && grep -qiE 'latency, not a failure' <<<"$_rmflat"; then
    pass "⚠️ the retry error is recorded as unreproduced, not as the symptom"
else
    fail "⚠️ it does not present the retry error as the symptom" \
         "the measured claim is that the launch is SLOW, which is smaller and different"
fi

# ⚠️ Matches the CLAIM, not the words — same reason as the retention assertion.
# "a very large plan can exhaust this" is the wrong claim; naming run creation
# is the right one.
if grep -qiE 'RUN CREATION' <<<"$_rmflat"; then
    pass "🔵 it names run creation as the cost, not plan construction"
else
    fail "🔵 it names run creation as the cost" \
         "building the plan is 0.01 s and one step; a comment that blames it sends the next reader at the tenant"
fi

# ⚠️ AND IT MUST SAY WHOSE READING IT IS. UIS has not re-read Dagster's source
# and has not measured this. A borrowed diagnosis stated flatly becomes this
# file's own authority the next time someone quotes it.
if grep -qiE "atlas's reading|has not re-read the source" <<<"$_rmflat"; then
    pass "⚠️ the diagnosis is attributed, not adopted as measured here"
else
    fail "⚠️ the diagnosis is attributed" \
         "this file has not measured it; an unattributed claim is quoted back as the platform's own"
fi

# 🔴 And 711 must not read as a ceiling. It is the event count of one plan
# that did not finish inside a TIME budget; there is no count limit to hold a
# margin against, and "the real margin is N and shrinking" was written down
# twice on that misreading.
if grep -q '711' <<<"$_rmflat" && ! grep -qiE '711 WAS NEVER A CAP|no count limit' <<<"$_rmflat"; then
    fail "🔴 711 is not presented as a cap" \
         "it is a TIME budget; margin arithmetic against 711 is against a boundary that does not exist"
else
    pass "🔴 711 is not presented as a cap"
fi

# ── 🔴 THE CHURN IS MEASURED; ITS CAUSE IS NOT ─────────────────────
# 1.6.110 shipped this block saying "the missing term is NullPool, and it is now
# MEASURED rather than read", naming `create_pg_engine` as hard-coding it. Both
# halves were wrong and atlas caught them at the pinned version
# (urb-agents#1177):
#
#   create_pg_engine only forwards **engine_kwargs; the CALLER passes NullPool
#   and the WEBSERVER — which serves launchPipelineExecution and therefore
#   creates the run — calls optimize_for_webserver and is POOLED
#
# ⚠️ So the file asserted connection setup per event about a process that pools,
# in the very block whose 1.6.107 revision exists to stop exactly that. The
# measurement stands; the explanation does not. A wrong mechanism stated as
# measured is worse than the unmeasured one it replaced, because the word
# "measured" is what stops the next reader checking.
# 🔴 AND THIS ASSERTION NEEDED THE ESCAPE CLAUSE IMMEDIATELY, which is the
# best available argument for the warning at _validate_template_info (#1174).
# Its first version fired on the phrase alone — and the corrected block QUOTES
# the retracted claim, because recording what the file used to say is the point.
# So the test failed the very commit that withdrew the claim, within the hour of
# writing down that a naive string gate finds exactly the retractions.
#
# ⚠️ The string is a finding only OUTSIDE a withdrawal. That is the same shape
# as the tenant-lever assertion above, and the third time this file has needed
# it.
if grep -qiE 'missing term is NullPool|hard-codes[^.]*NullPool|create_pg_engine hard' <<<"$_rmflat" \
   && ! grep -qiE 'WHAT IS \*NOT\* ESTABLISHED|Both halves were wrong' <<<"$_rmflat"; then
    fail "🔴 pooling is not named as the established cause of the churn" \
         "the webserver pools and is what creates the run; which process churns is still unknown"
else
    pass "🔴 pooling is named as retracted, never as the established cause"
fi

# ⚠️ AND THE UNKNOWN MUST BE NAMED, not merely left out. A block that quietly
# drops the wrong cause reads as though the churn were explained.
# ⚠️ ANCHORED ON THE CLAIM, NOT ON A COMMON PHRASE. The first version required
# "which process", which also occurs in "it does not depend on which process
# runs it" — a sentence about the VERIFIED half, for an unrelated reason. So
# deleting the open question left the assertion green.
#
# ⚠️ The `application_name` half needed the same treatment: it also appears in
# the sampler-exclusion note twenty lines down, so removing it from the
# INSTRUCTION left this green too. Both halves are now anchored on wording that
# exists only in the sentence being asserted. Fourth first-draft pattern today
# that matched something other than its subject — the failure is always the
# same, a word chosen because it is memorable rather than because it is unique.
if grep -qiE 'CHURN IS REAL AND UNEXPLAINED' <<<"$_rmflat" \
   && grep -qiE "application_name\`?, which dagster sets" <<<"$_rmflat"; then
    pass "⚠️ it says the churn is unexplained, and names the column that would settle it"
else
    fail "⚠️ the open question is stated with its next step" \
         "dropping a retracted cause without naming what replaced it reads as explained"
fi

# 🔵 AND THE TENANT LEVER MUST REST ON THE VERIFIED HALF. store_event_batch
# excluding this event type is source at the pinned version; the churn is a
# measurement with no attributed cause. The lever follows from the first and not
# the second, and the file has to say which.
# ⚠️ `store_event_batch` alone is too weak here too — it also appears in the
# durable-fix sentence at the end of the block, so the lever could lose its
# source and stay green. The anchor is a FILE-AND-LINE citation, which exists
# only where the claim is actually sourced.
if grep -qiE 'event_log\.py:[0-9]' <<<"$_rmflat" \
   && grep -qiE '1\.13\.19' <<<"$_rmflat" && grep -qiE '0\.29\.19' <<<"$_rmflat"; then
    pass "🔵 the verified claim cites file and line, and the version it was verified at"
else
    fail "🔵 the source claim names its version and lines" \
         "the first reading was fifteen patch releases behind the pin, and only luck kept its conclusion standing"
fi

echo ""
echo "  Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
