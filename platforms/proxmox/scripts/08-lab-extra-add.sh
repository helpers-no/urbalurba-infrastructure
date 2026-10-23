#!/bin/bash
# File: platforms/proxmox/scripts/08-lab-extra-add.sh
#
# Description:
#   Add ONE opt-in lab extra to this install — same mechanism as
#   07-core-service-add.sh, deliberately kept as a SEPARATE script/list rather than a 7th
#   CORE_SERVICES case arm. See config.sh-template's "Lab extras" section and
#   urb-agents#1970/#1971/#1972: these are guests judged genuinely useful to SOME labs but not
#   assumed as a UIS default (unlike pg/bao/garage/registry/forgejo/pg-test, which ship as the
#   reference lab's own real configuration) — keeping the list itself visibly separate is the
#   point, not an implementation detail.
#
#   Entry point: `uis platform lab-extra add proxmox <name>`
#
# What this does NOT do:
#   - Does not remove or reconfigure anything already running — same caution as
#     07-core-service-add.sh for the same reason (these guests can hold real data).
#   - Does not validate the service beyond whether its name is recognized.
#
# Usage:
#   ./scripts/08-lab-extra-add.sh dns-resolver

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
print_status()  { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="${UIS_REPO_ROOT:-$(cd "$PLATFORM_DIR/../.." && pwd)}"
CONFIG_FILE="$REPO_ROOT/.uis.secrets/platforms/proxmox/config.sh"

NAME="${1:-}"
if [[ -z "$NAME" ]]; then
    print_error "Usage: $0 <name>"
    echo "  Known lab extras: dns-resolver nas forgejo-runner" >&2
    exit 2
fi

# 🔴 KEEP THIS LIST IN STEP WITH generate-ansible-config.sh's OWN `case "$extra" in` ARMS — same
# "two places must agree" shape 07-core-service-add.sh's header already names for CORE_SERVICES.
case "$NAME" in
    dns-resolver|nas|forgejo-runner) ;;
    *)
        print_error "Unknown lab extra '$NAME'."
        echo "  Known lab extras: dns-resolver nas forgejo-runner" >&2
        exit 2
        ;;
esac

if [[ ! -f "$CONFIG_FILE" ]]; then
    print_error "No config.sh found at $CONFIG_FILE — run 'uis platform init proxmox' first."
    exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE"
LAB_EXTRAS="${LAB_EXTRAS:-}"
CORE_SERVICES="${CORE_SERVICES:-}"

# 🔴 forgejo-runner DEPENDS ON forgejo BEING A SELECTED CORE_SERVICES ENTRY — a runner with no
# Forgejo instance to register against is useless (urb-agents#1982). dns-resolver/nas both stand
# alone; this is the first lab-extra with a real dependency on another opt-in piece.
if [[ "$NAME" == "forgejo-runner" ]]; then
    _has_forgejo=0
    for _svc in $CORE_SERVICES; do [[ "$_svc" == "forgejo" ]] && _has_forgejo=1 && break; done
    if [[ "$_has_forgejo" -eq 0 ]]; then
        print_error "forgejo-runner needs 'forgejo' in CORE_SERVICES first — it has nothing to register against otherwise."
        echo "  Run 'uis platform core-service add proxmox forgejo' first." >&2
        exit 1
    fi
fi

_already_present=0
for _e in $LAB_EXTRAS; do
    [[ "$_e" == "$NAME" ]] && _already_present=1 && break
done

if [[ "$_already_present" -eq 1 ]]; then
    print_status "'$NAME' is already in LAB_EXTRAS — re-running its apply step is idempotent, proceeding to confirm/repair it."
else
    print_status "Adding '$NAME' to LAB_EXTRAS in config.sh..."
    if grep -q '^LAB_EXTRAS="' "$CONFIG_FILE"; then
        sed -i.bak -E "s/^LAB_EXTRAS=\"(.*)\"\$/LAB_EXTRAS=\"\1 ${NAME}\"/" "$CONFIG_FILE"
        rm -f "${CONFIG_FILE}.bak"
    else
        # 🔵 An older config.sh, written before this convention existed, never had the line at
        # all — append it rather than refusing. Same "defaulted, not required" treatment
        # generate-ansible-config.sh gives LAB_EXTRAS for the same reason.
        {
            echo ""
            echo "LAB_EXTRAS=\"${NAME}\""
        } >> "$CONFIG_FILE"
    fi
    print_success "'$NAME' added to LAB_EXTRAS"
fi

print_status "Building '$NAME' (and only '$NAME' — every other already-built guest is untouched)..."
"$SCRIPT_DIR/09-lab-extras-apply.sh" "$NAME"
