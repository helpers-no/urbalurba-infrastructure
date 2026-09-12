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

# ============================================================================
print_test_section "the published surface table matches the code"
# ============================================================================
#
# 🔴 atlas asked for exactly this, and the reason is the strongest argument for
# a test I have been given:
#
#   "If that list is readable from the UIS side, a pointer to it in the docs
#    would stop this recurring; if it moves, the sentence I just wrote quietly
#    becomes wrong again." (#758)
#
# ⚠️ An application author reads that table and makes EDITORIAL decisions on the
# strength of it — which warning to repeat, which to lean on a sibling field
# for. A stale table does not mislead a reader about a detail; it makes their
# writing wrong in a way neither side can see. That is how the `automation`
# sentence came to be written blind in the first place.

DOC="$(cd "$SCRIPT_DIR/../../../.." && pwd)/website/docs/reference/uis-cli-reference.md"

start_test "the published surface table is where the test expects it"
if [[ -f "$DOC" ]] && grep -q 'OPERATIONAL-SURFACE-TABLE' "$DOC"; then
    pass_test
else
    fail_test "no OPERATIONAL-SURFACE-TABLE marker in $DOC — the docs and this test have parted company"
    print_summary; exit $?
fi

# Rows look like:  | `first_data.jobs` | yes | yes |
_doc_rows="$(sed -n '/OPERATIONAL-SURFACE-TABLE/,/^:::/p' "$DOC" \
    | grep -E '^\| `[a-z_.]+` *\|' \
    | awk -F'|' '{gsub(/[ `]/,"",$2); gsub(/ /,"",$4); print $2" "$4}')"

_doc_install="$(awk '$2=="yes"{print $1}' <<< "$_doc_rows" | sort -u)"
_doc_info="$(awk '{print $1}' <<< "$_doc_rows" | sort -u)"

start_test "the table parses into rows"
_rows=$(printf '%s\n' "$_doc_rows" | grep -c .)
# ⚠️ A table that stopped parsing would make every comparison below pass on no
# evidence — the vacuous pass this whole file exists to refuse.
[[ "$_rows" -ge 10 ]] && pass_test || fail_test "parsed $_rows rows; the table format has changed"

start_test "🔴 every field the docs promise at install IS rendered at install"
_doc_lies=""
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    grep -qx "$f" <<< "$_install_fields" || _doc_lies+="$f "
done <<< "$_doc_install"
[[ -z "$_doc_lies" ]] && pass_test \
    || fail_test "documented as reaching install, but the installer does not read it: $_doc_lies"

start_test "🔴 every field the installer renders IS promised by the docs"
# The other direction matters just as much: a field rendered but undocumented
# leaves an author writing for a surface they do not know they reach.
_undocumented=""
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    grep -qx "$f" <<< "$_doc_install" || _undocumented+="$f "
done <<< "$_install_fields"
[[ -z "$_undocumented" ]] && pass_test \
    || fail_test "rendered at install but not in the table: $_undocumented"

start_test "the table lists every field info actually reads"
_doc_missing=""
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    grep -qx "$f" <<< "$_doc_info" || _doc_missing+="$f "
done <<< "$_info_fields"
[[ -z "$_doc_missing" ]] && pass_test \
    || fail_test "read by info and absent from the table: $_doc_missing"

start_test "the table does not name fields neither renderer reads"
_doc_ghosts=""
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    grep -qx "$f" <<< "$_info_fields" || _doc_ghosts+="$f "
done <<< "$_doc_info"
[[ -z "$_doc_ghosts" ]] && pass_test \
    || fail_test "documented but read by neither renderer: $_doc_ghosts"

start_test "the docs warn that an info-only field cannot be leaned on"
# The specific trap atlas hit: first_data.why ("enabling does not backfill") is
# info-only, so an `automation` sentence must repeat it rather than assume it.
grep -q 'cannot be leaned on' "$DOC" && pass_test \
    || fail_test "nothing tells an author that a 'no' field may not have been read"

print_summary
