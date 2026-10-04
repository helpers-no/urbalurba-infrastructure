#!/bin/bash
# down.sh — Tear down both k3s clusters (delegates to 03-destroy.sh).
#
# Entry point: uis platform down proxmox-k3s
#
# Thin pass-through. 03-destroy.sh owns the typed-name confirmation prompt
# and the UIS_DESTROY_CONFIRM=proxmox-k3s non-interactive escape hatch; this
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
echo " (uis platform down proxmox-k3s)"
echo "═══════════════════════════════════════════════════════════"
echo

if ! "$SCRIPT_DIR/03-destroy.sh"; then
    echo
    echo "═══════════════════════════════════════════════════════════"
    echo " ✗ Tear-down aborted or failed"
    echo "═══════════════════════════════════════════════════════════"
    echo "  One or more VMs may still exist. Check with:"
    echo "    ./uis platform status proxmox-k3s"
    echo "  Re-run when ready: ./uis platform down proxmox-k3s"
    exit 1
fi

echo
echo "═══════════════════════════════════════════════════════════"
echo " ✓ Both k3s clusters destroyed"
echo "═══════════════════════════════════════════════════════════"
echo "  config.sh is preserved. Recreate with the same settings:"
echo "    ./uis platform up proxmox-k3s"
echo
echo "  To fully reset (e.g. before changing which machines this targets):"
echo "    rm platforms/proxmox-k3s/config.sh"
