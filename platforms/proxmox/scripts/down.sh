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
# config.sh is per-install REAL STATE (host addresses, VMIDs, which services are
# selected) -- it must survive a container restart/uis-pull the same way every
# other platform's own persistent config already does (platform-switching.sh's
# PF_CLUSTER_CONFIG, azure-aks's own .uis.secrets/cloud-accounts/azure-default.env).
# platforms/proxmox/ itself is part of the container's image layer, not a
# persistent mount -- a config.sh written there silently vanishes on the next
# pull (urb-agents#1935, found running `uis platform init proxmox` for real,
# against a live lab, for the first time).
REPO_ROOT="${UIS_REPO_ROOT:-$(cd "$PLATFORM_DIR/../.." && pwd)}"
CONFIG_FILE="$REPO_ROOT/.uis.secrets/platforms/proxmox/config.sh"

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
