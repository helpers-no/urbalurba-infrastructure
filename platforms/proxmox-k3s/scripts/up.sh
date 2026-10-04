#!/bin/bash
# up.sh — Provision both k3s clusters end-to-end.
#
# Entry point: uis platform up proxmox-k3s
#
# Chains the three lifecycle scripts in order. All three are idempotent, so
# a warm re-run (nothing changed since the last `up`) is a fast no-op that
# still visibly confirms every step, not silent.
#
# Refuses with a clear pointer if config.sh is missing — does NOT auto-run
# init. init and up have different mental models (one asks questions, the
# other builds); a surprise wizard here would be a bigger surprise than
# refusing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$PLATFORM_DIR/config.sh"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "✗ No config.sh found at ${CONFIG_FILE#$PLATFORM_DIR/}" >&2
    echo "  Run './uis platform init proxmox-k3s' first." >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE"

echo "═══════════════════════════════════════════════════════════"
echo " Proxmox + k3s cluster provisioning"
echo " (uis platform up proxmox-k3s)"
echo " Hosts: ${PROXMOX_HOST1_NAME} ${PROXMOX_HOST2_NAME} ${PROXMOX_HOST3_NAME}"
echo "═══════════════════════════════════════════════════════════"
echo
echo "This creates 6 VMs across your 3 Proxmox hosts and forms two k3s"
echo "clusters. No cloud cost — it's your own hardware — but it does use"
echo "real disk/RAM/CPU on each host (see README.md's \"Sizing\")."
echo

echo "▶ 1/3 Preflight (verify the 3 Proxmox hosts are ready)..."
"$SCRIPT_DIR/00-preflight.sh"
echo

echo "▶ 2/3 Apply (create 6 VMs, form both k3s clusters)..."
"$SCRIPT_DIR/01-apply.sh"
echo

echo "▶ 3/3 Post-apply (kubeconfig + Traefik + switch UIS target)..."
"$SCRIPT_DIR/02-post-apply.sh"

echo
echo "═══════════════════════════════════════════════════════════"
echo " ✓ Both k3s clusters are up"
echo "═══════════════════════════════════════════════════════════"
echo "  Try: kubectl get nodes"
echo "       ./uis deploy nginx"
echo
echo "  Tear down: ./uis platform down proxmox-k3s"
