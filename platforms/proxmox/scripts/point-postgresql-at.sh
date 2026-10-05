#!/bin/bash
# File: platforms/proxmox/scripts/point-postgresql-at.sh
#
# Description:
#   Switches the active k3s cluster target AND keeps UIS's external-services.yaml "postgresql:"
#   entry pointed at the RIGHT guest for that target, in one atomic step.
#
#   🔴 WHY THIS EXISTS. .uis.extend/external-services.yaml is ONE global file — not scoped per
#   k3s context — but this platform manages TWO clusters (production "proxmox", test
#   "proxmox-test") from the same provision-host container, each meant to use its OWN postgres
#   (production and test data must never share a database). `uis deploy postgresql`'s external-
#   service proxy (see website/docs/.../PLAN-system-external-services-001-proxy-convention.md)
#   has no idea two clusters exist — it just reads whatever this one file says. This script is
#   what keeps the file's answer correct for whichever cluster is actually active.
#
#   ⚠️ THE SHARED pf_lockstep_flip MECHANISM ONLY COVERS "proxmox" (production) — switching TO
#   "proxmox-test" today is just `kubectl config use-context`, bypassing cluster-config.sh
#   entirely (see 04-k3s-post-apply.sh's own printed instructions). This script does the right
#   thing for both: the blessed lockstep flip for production, a plain context switch for test —
#   and updates external-services.yaml either way.
#
#   ⚠️ THIS FILE MAY ALREADY HOLD REAL, UNRELATED PRODUCTION CONFIG for a different installation
#   entirely (found 2026-10-05: a stale `postgresql:`/`minio:` pointing at a now-wiped host).
#   Re-check what's actually in it before trusting this script blindly if this container is ever
#   shared with a real, live, unrelated UIS install again.
#
# Usage:
#   ./scripts/point-postgresql-at.sh proxmox        # production: pg (VMID 405)
#   ./scripts/point-postgresql-at.sh proxmox-test   # test: pg-test (VMID 406)

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
print_status()  { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

TARGET="${1:-}"
case "$TARGET" in
    proxmox)      PG_VMID=405; PG_NAME="pg" ;;
    proxmox-test) PG_VMID=406; PG_NAME="pg-test" ;;
    *)
        print_error "Usage: $0 proxmox|proxmox-test"
        exit 2
        ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$PLATFORM_DIR/config.sh"

if [[ ! -f "$CONFIG_FILE" ]]; then
    print_error "No config.sh found at $CONFIG_FILE"
    exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE"

ssh_h1() { ssh -i "$PROXMOX_SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "root@${PROXMOX_HOST1_ADDR}" "$@"; }

print_status "Finding ${PG_NAME}'s guest IP (VMID ${PG_VMID})..."
PG_IP="$(ssh_h1 "pct exec ${PG_VMID} -- hostname -I" 2>/dev/null | awk '{print $1}')"
if [[ -z "$PG_IP" ]]; then
    print_error "Could not get an IP for ${PG_NAME} (VMID ${PG_VMID})."
    echo "  Is \"${PG_NAME}\" in CORE_SERVICES in config.sh? Has ./scripts/05-core-services-apply.sh run?"
    exit 1
fi

EXTEND_DIR="${EXTEND_DIR:-/mnt/urbalurbadisk/.uis.extend}"
EXT_FILE="$EXTEND_DIR/external-services.yaml"
mkdir -p "$EXTEND_DIR"
[[ -f "$EXT_FILE" ]] || cp "/mnt/urbalurbadisk/provision-host/uis/templates/uis.extend/external-services.yaml.default" "$EXT_FILE"

print_status "Pointing external-services.yaml's postgresql: entry at ${PG_IP} (${PG_NAME})..."
yq -i "
  .postgresql.host = \"${PG_IP}\" |
  .postgresql.port = 5432 |
  .postgresql.why = \"platforms/proxmox core-services guest ${PG_NAME} (vmid ${PG_VMID}), reached over the LAN — active target: ${TARGET}\"
" "$EXT_FILE"

print_status "Switching the active cluster target to ${TARGET}..."
source /mnt/urbalurbadisk/provision-host/uis/lib/platform-switching.sh
if [[ "$TARGET" == "proxmox" ]]; then
    # The blessed path — keeps cluster-config.sh in lockstep too.
    pf_lockstep_flip "proxmox"
else
    kubectl config use-context "$TARGET"
fi

print_success "Active target: ${TARGET}. 'uis deploy postgresql' there now proxies to ${PG_NAME} (${PG_IP})."
echo "  Existing in-cluster consumers (PGHOST=postgresql.default) are unaffected — only the"
echo "  external address the proxy forwards to changed."
