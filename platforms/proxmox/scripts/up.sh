#!/bin/bash
# up.sh — Provision both k3s clusters end-to-end.
#
# Entry point: uis platform up proxmox
#
# Chains the three lifecycle scripts in order. All three are idempotent, so
# a warm re-run (nothing changed since the last `up`) is a fast no-op that
# still visibly confirms every step, not silent.
#
# Refuses with a clear pointer if config.sh is missing — does NOT auto-run
# init. init and up have different mental models (one asks questions, the
# other builds); a surprise wizard here would be a bigger surprise than
# refusing.
#
# ⚠️ 01-cluster-join.sh and 05-core-services-apply.sh aren't written yet —
# see STRUCTURE.md. This chain runs storage-ensure (safe mode — no disk is
# touched without --create-pool, run that yourself once per fresh lab) then
# stops at a manual reminder for cluster join, same gap README.md's "Before
# you start" already documents. Will grow to a single unbroken chain once
# 01 and 05 exist.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$PLATFORM_DIR/config.sh"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "✗ No config.sh found at ${CONFIG_FILE#$PLATFORM_DIR/}" >&2
    echo "  Run './uis platform init proxmox' first." >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE"

echo "═══════════════════════════════════════════════════════════"
echo " Proxmox + k3s cluster provisioning"
echo " (uis platform up proxmox)"
echo " Hosts: ${PROXMOX_HOST1_NAME} ${PROXMOX_HOST2_NAME} ${PROXMOX_HOST3_NAME}"
echo "═══════════════════════════════════════════════════════════"
echo
echo "This creates 6 VMs across your 3 Proxmox hosts and forms two k3s"
echo "clusters. No cloud cost — it's your own hardware — but it does use"
echo "real disk/RAM/CPU on each host (see README.md's \"Sizing\")."
echo

echo "▶ 1/4 Storage (bootstrap the control key, verify all 3 hosts — safe, no disk touched)..."
"$SCRIPT_DIR/00-storage-ensure.sh"
echo
echo "  ⚠️ If this is a fresh lab, run './scripts/00-storage-ensure.sh --create-pool' yourself"
echo "  once (destructive, asks for a typed YES per host) before continuing — not auto-run here."
echo "  ⚠️ Then join the 3 hosts into one Proxmox cluster by hand — see README.md's"
echo "  \"Before you start\" (01-cluster-join.sh doesn't exist yet, see STRUCTURE.md)."
echo

echo "▶ 2/4 Preflight (verify the 3 Proxmox hosts are ready)..."
"$SCRIPT_DIR/02-k3s-preflight.sh"
echo

echo "▶ 3/4 Apply (create 6 VMs, form both k3s clusters)..."
"$SCRIPT_DIR/03-k3s-apply.sh"
echo

echo "▶ 4/4 Post-apply (kubeconfig + Traefik + switch UIS target)..."
"$SCRIPT_DIR/04-k3s-post-apply.sh"

echo
echo "═══════════════════════════════════════════════════════════"
echo " ✓ Both k3s clusters are up"
echo "═══════════════════════════════════════════════════════════"
echo "  Try: kubectl get nodes"
echo "       ./uis deploy nginx"
echo
echo "  Tear down: ./uis platform down proxmox"
