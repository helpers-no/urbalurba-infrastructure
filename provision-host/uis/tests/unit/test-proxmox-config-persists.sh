#!/bin/bash
# test-proxmox-config-persists.sh — platforms/proxmox/config.sh must live under a
# persistent mount, never inside platforms/proxmox/ itself.
#
# urb-agents#1935, found by ops running `uis platform init proxmox` for real, against a
# live lab, for the first time: `platforms/proxmox/` is part of the running container's
# own image layer, not a bind mount to anything persistent (confirmed via `docker
# inspect` — only `.uis.extend` and `.uis.secrets` are). Every script that read or wrote
# config.sh at `$PLATFORM_DIR/config.sh` was writing into state that silently vanishes
# on the next `uis pull` — fill in config.sh today, pull tomorrow for an unrelated
# reason, and the entire lab config is gone with no warning.
#
# The rest of this codebase already had the answer: platform-switching.sh's
# PF_CLUSTER_CONFIG and azure-aks's own init.sh both correctly root their persistent
# config under .uis.extend / .uis.secrets. This is a repo-wide regression guard across
# every file in platforms/proxmox/ that touches config.sh's path, so this class of bug
# cannot reappear silently in a 15th file nobody thought to check.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/test-framework.sh"
REPO="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
PROXMOX_SCRIPTS="$REPO/platforms/proxmox/scripts"

print_test_section "no script computes config.sh's path inside platforms/proxmox/ itself"

start_test "the sweep has files to check"
_n=$(find "$PROXMOX_SCRIPTS" -maxdepth 1 -name '*.sh' | wc -l)
[[ "$_n" -ge 10 ]] && pass_test || fail_test "only $_n scripts found — the sweep path is probably wrong"

start_test "🔴 no script reads/writes config.sh via a bare \$PLATFORM_DIR/config.sh path"
_bad=""
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    grep -qE '(CONFIG_FILE="\$PLATFORM_DIR/config\.sh"|source "\$PLATFORM_DIR/config\.sh")' "$f" \
        && _bad+="${f#$REPO/} "
done < <(find "$PROXMOX_SCRIPTS" -maxdepth 1 -name '*.sh')
[[ -z "$_bad" ]] && pass_test || fail_test "still points config.sh inside the non-persistent platforms/proxmox/ tree: $_bad"

start_test "every script that defines CONFIG_FILE roots it under .uis.secrets/platforms/proxmox/"
_bad=""
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    grep -q '^CONFIG_FILE=' "$f" || continue
    grep -qF 'CONFIG_FILE="$REPO_ROOT/.uis.secrets/platforms/proxmox/config.sh"' "$f" || _bad+="${f#$REPO/} "
done < <(find "$PROXMOX_SCRIPTS" -maxdepth 1 -name '*.sh')
[[ -z "$_bad" ]] && pass_test || fail_test "CONFIG_FILE defined but not pointed at the persistent path: $_bad"

start_test "generate-ansible-config.sh (no CONFIG_FILE var, sources config.sh directly) is also fixed"
grep -qF 'source "$REPO_ROOT/.uis.secrets/platforms/proxmox/config.sh"' \
    "$PROXMOX_SCRIPTS/generate-ansible-config.sh" && pass_test \
    || fail_test "generate-ansible-config.sh still sources config.sh from the wrong place"

start_test "REPO_ROOT honors a pre-set UIS_REPO_ROOT, same contract as azure-aks's own init.sh"
_bad=""
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    grep -q '^REPO_ROOT=' "$f" || continue
    grep -qF 'REPO_ROOT="${UIS_REPO_ROOT:-$(cd "$PLATFORM_DIR/../.." && pwd)}"' "$f" || _bad+="${f#$REPO/} "
done < <(find "$PROXMOX_SCRIPTS" -maxdepth 1 -name '*.sh')
[[ -z "$_bad" ]] && pass_test || fail_test "REPO_ROOT computed differently (or not honoring the override) in: $_bad"

start_test "init.sh creates the persistent directory before writing into it"
grep -qF 'mkdir -p "$(dirname "$CONFIG_FILE")"' "$PROXMOX_SCRIPTS/init.sh" && pass_test \
    || fail_test "init.sh writes config.sh without first ensuring .uis.secrets/platforms/proxmox/ exists"

start_test "the stale platforms/proxmox/config.sh .gitignore entry is gone (config.sh never lands there again)"
grep -qxF 'platforms/proxmox/config.sh' "$REPO/.gitignore" && fail_test "still present — config.sh no longer writes there" \
    || pass_test

start_test "config.sh is still covered by the repo's blanket .uis.secrets/ gitignore entry"
grep -qxF '.uis.secrets/' "$REPO/.gitignore" && pass_test || fail_test "the blanket entry is missing — config.sh would be committable"

print_test_section "positive control"

start_test "positive control: the old pattern IS caught by this sweep"
_ctl="$(mktemp)"
cat > "$_ctl" <<'CTL'
PLATFORM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$PLATFORM_DIR/config.sh"
CTL
grep -qE '(CONFIG_FILE="\$PLATFORM_DIR/config\.sh"|source "\$PLATFORM_DIR/config\.sh")' "$_ctl" \
    && pass_test || fail_test "the sweep's own pattern does not match the known-bad shape — it would miss a regression"
rm -f "$_ctl"

print_summary
