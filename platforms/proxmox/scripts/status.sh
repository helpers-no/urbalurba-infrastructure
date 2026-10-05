#!/bin/bash
# status.sh — Report proxmox's state.
#
# Entry point: ./uis platform status proxmox
# Also invoked by pf_platform_summary (platform-switching.sh) as
# `status.sh --summary [--offline|--deep]`, which this honors:
# emits exactly one tab-separated line `<state>\t<hint>` on that path,
# where <state> is one of the four values pf_platform_summary validates
# against: not-initialized | configured-not-running | running | unreachable.
#
# Usage:
#   ./scripts/status.sh              # human-readable
#   ./scripts/status.sh --summary    # machine-readable, for platform list

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$PLATFORM_DIR/config.sh"
KUBECONFIG_ALL="/mnt/urbalurbadisk/kubeconfig/kubeconf-all"
PROD_CONTEXT="proxmox"

SUMMARY=0
for arg in "$@"; do
    [[ "$arg" == "--summary" ]] && SUMMARY=1
done

emit_summary() { echo -e "$1\t$2"; exit 0; }

if [[ ! -f "$CONFIG_FILE" ]]; then
    (( SUMMARY )) && emit_summary "not-initialized" "run: ./uis platform init proxmox"
    echo "not-initialized — run: ./uis platform init proxmox"
    exit 0
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE"

if [[ ! -f "$KUBECONFIG_ALL" ]] || ! KUBECONFIG="$KUBECONFIG_ALL" kubectl config get-contexts "$PROD_CONTEXT" >/dev/null 2>&1; then
    (( SUMMARY )) && emit_summary "configured-not-running" "run: ./uis platform up proxmox"
    echo "configured-not-running — config.sh exists, cluster not yet built — run: ./uis platform up proxmox"
    exit 0
fi

if ! KUBECONFIG="$KUBECONFIG_ALL" kubectl --context "$PROD_CONTEXT" --request-timeout=5s get --raw /version >/dev/null 2>&1; then
    (( SUMMARY )) && emit_summary "unreachable" "API server not answering — check the 3 Proxmox hosts and the 6 VMs"
    echo "unreachable — API server not answering. Check the 3 Proxmox hosts and the 6 k3s VMs are powered on."
    exit 0
fi

if (( SUMMARY )); then
    emit_summary "running" ""
fi

# ─── Human-readable ────────────────────────────────────────────────────────
echo "proxmox — running"
echo
echo "Production ($PROD_CONTEXT):"
KUBECONFIG="$KUBECONFIG_ALL" kubectl --context "$PROD_CONTEXT" get nodes
echo
if KUBECONFIG="$KUBECONFIG_ALL" kubectl config get-contexts "${PROD_CONTEXT}-test" >/dev/null 2>&1; then
    echo "Test (${PROD_CONTEXT}-test):"
    KUBECONFIG="$KUBECONFIG_ALL" kubectl --context "${PROD_CONTEXT}-test" get nodes
fi
