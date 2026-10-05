#!/bin/bash
# down.sh — Tear down both k3s clusters (delegates to 06-destroy.sh).
#
# Entry point: uis platform down proxmox
#
# Thin pass-through. 06-destroy.sh owns the typed-name confirmation prompt
# and the UIS_DESTROY_CONFIRM=proxmox non-interactive escape hatch; this
# wrapper inherits both for free.
#
# config.sh is left in place after destroy — the next `up` reuses the same
# 3 hosts/addresses/sizing without re-asking. Delete it yourself for a full
# reset.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$PLATFORM_DIR/config.sh"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "✗ No config.sh found — nothing appears to be configured. Nothing to tear down." >&2
    exit 1
fi

echo "═══════════════════════════════════════════════════════════"
echo " Proxmox + k3s cluster tear-down"
echo " (uis platform down proxmox)"
echo "═══════════════════════════════════════════════════════════"
echo

if ! "$SCRIPT_DIR/06-destroy.sh"; then
    echo
    echo "═══════════════════════════════════════════════════════════"
    echo " ✗ Tear-down aborted or failed"
    echo "═══════════════════════════════════════════════════════════"
    echo "  One or more VMs may still exist. Check with:"
    echo "    ./uis platform status proxmox"
    echo "  Re-run when ready: ./uis platform down proxmox"
    exit 1
fi

echo
echo "═══════════════════════════════════════════════════════════"
echo " ✓ Both k3s clusters destroyed"
echo "═══════════════════════════════════════════════════════════"
echo "  config.sh is preserved. Recreate with the same settings:"
echo "    ./uis platform up proxmox"
echo
echo "  To fully reset (e.g. before changing which machines this targets):"
echo "    rm platforms/proxmox/config.sh"
