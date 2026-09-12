#!/bin/bash
# test-operational-fields-reach-install.sh — a field an application declares must
# not be visible on one surface and silently absent on the other.
#
# 🔴 THIS IS THE THIRD INSTANCE OF ONE SHAPE, all in this file:
#
#   #745  `digest:` — declared by atlas, enforced by the deploy, and never
#         written by the renderer. Every deploy-time check skipped silently.
#   #756  `.operational.automation` — "Ships stopped… enabling the schedules is
#         a go-live decision" — rendered by `template info`, NOT by the
#         installer. The one person guaranteed to be reading never saw it.
#
# ⚠️ Its cost is not hypothetical. The acceptance host held a correct,
# verified, digest-pinned install whose register had stopped tracking reality
# **12.8 hours earlier**, with 3,075 unapplied changes, while every check stayed
# green. It surfaced because Terje asked a question, not because anything failed.
#
# The rule: every `.operational.*` field `template info` reads must either be
# rendered by the INSTALLER too, or be named here with a reason. "Info-only" is
# a decision someone has to make on purpose, not a thing that happens by
# forgetting.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"

LIB="$(cd "$SCRIPT_DIR/../../lib" && pwd)/template.sh"

# Fields `info` shows that the installer deliberately does not. Each needs a
# reason, and the reason has to survive being read aloud.
#
#   install.takes        — how long installing takes, printed AFTER it has
#                          finished. Useful before, not after.
#   install.deploys      — what it deploys; the installer has just shown the
#                          plan it actually executed, which is stronger.
#   first_data.why       — why the API is empty; `install.note` says this in the
#                          application's own words at exactly that moment.
#   first_data.how       — how to load it; the installer prints the job list,
#                          which is the actionable half of the same field.
#   cadence              — the schedule table. Reference material, and with
#                          automation stopped it describes what WOULD run. The
#                          installer points at what IS on instead.
#   external_services    — who it contacts. Nothing is contacted until
#                          automation is enabled, and the automation line the
#                          installer now prints is the moment that matters.
#   timezone             — reference; means nothing until a schedule runs.
EXEMPT=(
    "install.takes"
    "install.deploys"
    "first_data.why"
    "first_data.how"
    "cadence"
    "external_services"
    "timezone"
)

print_test_section "every operational field reaches the surface that needs it"

start_test "both renderers are where the test thinks they are"
if grep -q '^_install_summary_operational() {' "$LIB" && grep -q '^_template_info_operational() {' "$LIB"; then
    pass_test
else
    fail_test "one of the operational renderers is missing from $LIB"; print_summary; exit $?
fi

_fields_of() {
    sed -n "/^$1() {/,/^}/p" "$LIB" \
        | grep -oE '\.operational\.[a-z_]+(\.[a-z_]+)?' \
        | sed 's/^\.operational\.//' | sort -u
}

_info_fields="$(_fields_of _template_info_operational)"
_install_fields="$(_fields_of _install_summary_operational)"

start_test "the field scan finds something to compare"
_n=$(printf '%s\n' "$_info_fields" | grep -c .)
# ⚠️ An empty parse would make the assertion below pass on no evidence — the
# same vacuous-pass this file exists to catch.
[[ "$_n" -ge 5 ]] && pass_test || fail_test "parsed only $_n info fields; the sed range is probably wrong"

_is_exempt() { local f="$1" e; for e in "${EXEMPT[@]}"; do [[ "$f" == "$e" ]] && return 0; done; return 1; }

start_test "🔴 no operational field is shown by info and silently absent from install"
_missing=""
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    _is_exempt "$f" && continue
    grep -qx "$f" <<< "$_install_fields" || _missing+="$f "
done <<< "$_info_fields"
[[ -z "$_missing" ]] && pass_test \
    || fail_test "declared, rendered by info, invisible at install: $_missing — render it, or add it to EXEMPT with a reason"

start_test "every exemption is still a field info actually reads"
# An exemption for a field nobody renders any more quietly widens the skip.
_stale=""
for e in "${EXEMPT[@]}"; do
    grep -qx "$e" <<< "$_info_fields" || _stale+="$e "
done
[[ -z "$_stale" ]] && pass_test || fail_test "exempt but not read by info — remove from EXEMPT: $_stale"

start_test "🔴 the installer renders the automation sentence"
grep -qx "automation" <<< "$_install_fields" && pass_test \
    || fail_test "the go-live decision is the one line an installer must not drop"

start_test "the installer names assets with no schedule at all"
# ⚠️ An asset driven by an automation condition has no schedule to switch on.
# Someone told to "enable the schedules" would enable every schedule and still
# not be running it (imac, #756).
grep -qx "unscheduled" <<< "$_install_fields" && pass_test \
    || fail_test "'enable the schedules' is wrong advice for a sensor-driven asset"

start_test "the installer does not go silent when an application declares nothing"
_fn="$(sed -n '/^_install_summary_operational() {/,/^}/p' "$LIB")"
grep -q 'does not state whether its automation' <<< "$_fn" && pass_test \
    || fail_test "an application that omits automation: must not buy back the old silence"

start_test "the installer points at a command UIS can actually honour"
# 🔴 `uis dagster automation` REPORTS. It cannot start anything: the mutation
# signatures were never verified against the deployed chart, and the playbook
# says so. Advice to "run uis dagster start" would be advice to run nothing.
if grep -q './uis dagster automation' <<< "$_fn" && ! grep -qE 'dagster (start|enable)' <<< "$_fn"; then
    pass_test
else
    fail_test "the installer must not imply UIS can switch automation on"
fi

start_test "the summary printer returns success"
# Without an explicit `return 0` it exits with the status of its last test, so
# an application with no `unscheduled` list returned 1 from a printer that had
# succeeded.
printf '%s\n' "$_fn" | tail -3 | grep -q 'return 0' && pass_test \
    || fail_test "the function can exit non-zero on a successful summary"

print_summary
