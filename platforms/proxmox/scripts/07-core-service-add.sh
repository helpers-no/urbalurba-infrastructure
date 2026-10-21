#!/bin/bash
# File: platforms/proxmox/scripts/07-core-service-add.sh
#
# Description:
#   Add ONE core service to this install — the per-service counterpart to
#   `uis deploy <service>` on the Kubernetes side, for the host-level guests
#   CORE_SERVICES manages (registry/bao/garage/pg/forgejo). Before this script existed, adding
#   a service meant hand-editing config.sh's CORE_SERVICES line and re-running
#   05-core-services-apply.sh, which (until this script's own fix) re-touched every
#   already-built guest too — this does exactly one.
#
#   Entry point: `uis platform core-service add proxmox <name>`
#
# What this does NOT do:
#   - Does not remove or reconfigure anything already running — see
#     08-core-service-remove.sh (not written yet) for teardown, a separate, more cautious
#     operation given these guests hold real data.
#   - Does not validate the service beyond whether its name is recognized — if
#     service-<name>.yml itself fails, 05-core-services-apply.sh's own error handling applies
#     unchanged (this script is a thin, config-editing front end to it, not a reimplementation).
#
# Usage:
#   ./scripts/07-core-service-add.sh forgejo

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
print_status()  { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$PLATFORM_DIR/config.sh"

NAME="${1:-}"
if [[ -z "$NAME" ]]; then
    print_error "Usage: $0 <name>"
    echo "  Known services: pg bao garage registry pg-test forgejo" >&2
    exit 2
fi

# 🔴 KEEP THIS LIST IN STEP WITH generate-ansible-config.sh's OWN `case "\$svc" in` ARMS — same
# "two places must agree" shape this repository already names explicitly elsewhere (e.g.
# build-uis-container.yml / test-uis.yml's paths-filter comment). A name missing here would
# refuse a service that script actually knows how to build; a name missing there would silently
# skip it with only a warning, after config.sh already claims it's configured.
case "$NAME" in
    pg|bao|garage|registry|pg-test|forgejo) ;;
    *)
        print_error "Unknown core service '$NAME'."
        echo "  Known services: pg bao garage registry pg-test forgejo" >&2
        exit 2
        ;;
esac

if [[ ! -f "$CONFIG_FILE" ]]; then
    print_error "No config.sh found at $CONFIG_FILE — run 'uis platform init proxmox' first."
    exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE"

_already_present=0
for _svc in $CORE_SERVICES; do
    [[ "$_svc" == "$NAME" ]] && _already_present=1 && break
done

if [[ "$_already_present" -eq 1 ]]; then
    print_status "'$NAME' is already in CORE_SERVICES — re-running its apply step is idempotent, proceeding to confirm/repair it."
else
    print_status "Adding '$NAME' to CORE_SERVICES in config.sh..."
    # 🔵 APPEND, NOT REPLACE — CORE_SERVICES is a single space-separated line; this must only
    # ever grow it, never touch an existing entry. Matches the existing value exactly (anchored
    # to the start and end of the quoted string) so a name that's a substring of another
    # (there are none today, but the check costs nothing) can never partially match.
    sed -i.bak -E "s/^CORE_SERVICES=\"(.*)\"\$/CORE_SERVICES=\"\1 ${NAME}\"/" "$CONFIG_FILE"
    rm -f "${CONFIG_FILE}.bak"
    print_success "'$NAME' added to CORE_SERVICES"
fi

print_status "Building '$NAME' (and only '$NAME' — every other already-built guest is untouched)..."
"$SCRIPT_DIR/05-core-services-apply.sh" "$NAME"
