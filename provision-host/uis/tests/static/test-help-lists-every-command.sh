#!/bin/bash
# test-help-lists-every-command.sh — a command absent from `uis help` does not
# exist, as far as anyone using UIS is concerned.
#
# 🔴 This is not tidiness. `uis monitors` render/apply/check all work and the
# verb is missing from the usage text, so `ops` grepped the help, found nothing,
# and reported to Terje that Uptime Kuma's declarative tooling did not exist.
# `assist` had to correct them (urb-agents#648). `uis dagster` is the same:
# `imac` found it by guessing.
#
# Twice today the fix for a capability nobody could find was one line of help
# text — `--dry-run` in 1.6.52 was called "the clearest description of atlas
# that exists anywhere" by someone who found it only by reading a usage string.
#
# ⚠️ ALIASES ARE EXEMPT AND LISTED EXPLICITLY. A generated list with a silent
# skip rule is how a check like this ends up passing while missing the thing it
# was written for, so every exemption is named and has to be justified here.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"

REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
CLI="$REPO_ROOT/provision-host/uis/manage/uis-cli.sh"

# Flags and short aliases of a command that IS documented. Each is a deliberate
# omission, not an undocumented capability.
EXEMPT=(
    help --help -h              # the help itself
    version --version -v        # documented as `version`
    ls list                     # aliases of `services` / `list`
    cats                        # alias of `categories`
    enabled                     # alias listed under Service Discovery
    sync                        # subcommand-shaped alias
)

print_test_section "every dispatched command appears in uis help"

start_test "the CLI is where the test thinks it is"
[[ -f "$CLI" ]] && pass_test || { fail_test "no $CLI"; print_summary; exit $?; }

# ⚠️ THERE ARE TWO `case "$command" in` BLOCKS at this indent, and taking the
# first one is wrong. The first is a short pre-dispatch that decides which
# commands skip initialisation; the real table is the second. An earlier version
# of this parser read only the first, found 7 commands, and the
# "nothing is missing" assertion then PASSED VACUOUSLY — caught only by the
# count sanity check below, which is the reason that check exists.
#
# So: union every such block rather than picking one. A command handled in
# either is still a command, and this cannot break again by a block being added.
_dispatched() {
    awk '
        /^    case "\$command" in/ { inside=1; next }
        inside && /^    esac/      { inside=0; next }
        inside && /^        [a-z][a-z0-9|_.-]*\)/ {
            line=$0; sub(/\).*/, "", line); gsub(/[ \t]/, "", line); print line
        }
    ' "$CLI" | tr '|' '\n' | sort -u
}

start_test "the dispatch table can be read at all"
_verbs="$(_dispatched)"
_n=$(printf '%s\n' "$_verbs" | grep -c .)
# ⚠️ An empty parse would make this whole suite pass silently — the exact
# failure this file exists to prevent, one level up.
[[ "$_n" -ge 20 ]] && pass_test || fail_test "parsed only $_n commands; the awk range is probably wrong"

_is_exempt() { local v="$1" e; for e in "${EXEMPT[@]}"; do [[ "$v" == "$e" ]] && return 0; done; return 1; }

start_test "🔴 no dispatched command is missing from the help text"
_help="$(sed -n '/^cmd_help() {/,/^}/p' "$CLI")"
_missing=""
while IFS= read -r v; do
    [[ -z "$v" ]] && continue
    _is_exempt "$v" && continue
    # Case-insensitive: section headers are capitalised ("Host Management:").
    grep -qiE "(^|[^a-zA-Z0-9_-])${v}([^a-zA-Z0-9_-]|$)" <<< "$_help" || _missing+="$v "
done <<< "$_verbs"
[[ -z "$_missing" ]] && pass_test || fail_test "dispatched but undocumented: $_missing"

start_test "every exemption is still a real dispatched command"
# An exemption for a command that no longer exists quietly widens the skip.
_stale=""
for e in "${EXEMPT[@]}"; do
    [[ "$e" == -* ]] && continue
    grep -qxF "$e" <<< "$_verbs" || _stale+="$e "
done
[[ -z "$_stale" ]] && pass_test || fail_test "exempt but not dispatched — remove from EXEMPT: $_stale"

# ============================================================================
print_test_section "positive control"
# ============================================================================

start_test "positive control: an undocumented command IS caught"
_ctl="$(mktemp)"
cat > "$_ctl" <<'CTL'
cmd_help() {
    cat <<EOF
Usage: uis <command>
  deploy    Deploy a service
EOF
}
main() {
    case "$command" in
        deploy)
            cmd_deploy
            ;;
        secretverb)
            cmd_secret
            ;;
    esac
}
CTL
_h="$(sed -n '/^cmd_help() {/,/^}/p' "$_ctl")"
_v="$(awk '/^    case "\$command" in/{inside=1;next} inside&&/^    esac/{exit} inside&&/^        [a-z][a-z0-9|_.-]*\)/{l=$0;sub(/\).*/,"",l);gsub(/[ \t]/,"",l);print l}' "$_ctl")"
_hit=""
while IFS= read -r v; do
    [[ -z "$v" ]] && continue
    grep -qiE "(^|[^a-zA-Z0-9_-])${v}([^a-zA-Z0-9_-]|$)" <<< "$_h" || _hit+="$v "
done <<< "$_v"
[[ "$_hit" == *secretverb* ]] && pass_test || fail_test "the check does not discriminate; found: '$_hit'"
rm -f "$_ctl"

print_summary
