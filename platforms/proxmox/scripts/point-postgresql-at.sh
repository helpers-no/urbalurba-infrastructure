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
#   🔴 CORRECTED 2026-10-05, found running this for real: pf_lockstep_flip is fully generic (any
#   kubectl context name, not only registered UIS platforms) — it keeps kubectl's current-context
#   AND cluster-config.sh's CLUSTER_TYPE/TARGET_HOST in lockstep for whichever target you give it.
#   An earlier version of this script used it only for "proxmox" and a bare
#   `kubectl config use-context` for "proxmox-test", wrongly assuming the lockstep writer was
#   production-only. Consequence: `uis deploy`/`uis verify` read cluster-config.sh, not kubectl's
#   live context, so they kept reporting "Target cluster: proxmox" after switching to test. Now
#   uses the real lockstep writer for both — see the fix at the call site below.
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
# 🔴 FOUND RUNNING THIS FOR REAL: pf_lockstep_flip is fully generic — it just does
# `kubectl config use-context "$1"` plus syncs cluster-config.sh's CLUSTER_TYPE/TARGET_HOST to
# match, for ANY context name, not only registered UIS platforms. An earlier version of this
# script used a plain `kubectl config use-context` for "proxmox-test" on the (wrong) assumption
# that the lockstep writer was production-only. Consequence: `uis deploy`/`uis verify` read
# cluster-config.sh's TARGET_HOST, not kubectl's live context — so they kept reporting
# "Target cluster: proxmox" even after switching kubectl to proxmox-test. Use the real lockstep
# writer for both targets; it's the only way "the active target" means the same thing to both
# kubectl and every uis command that trusts cluster-config.sh.
pf_lockstep_flip "$TARGET"

print_success "Active target: ${TARGET}. 'uis deploy postgresql' there now proxies to ${PG_NAME} (${PG_IP})."
echo "  Existing in-cluster consumers (PGHOST=postgresql.default) are unaffected — only the"
echo "  external address the proxy forwards to changed."

# ── sync the postgres superuser's password to match what the cluster already expects ─────────
# 🔴 FOUND RUNNING THIS FOR REAL: the postgres role never sets a password on the `postgres`
# superuser (loopback-only access didn't need one). The external-service proxy connects over the
# network, and `uis verify postgresql` (and anything else using PGPASSWORD from
# urbalurba-secrets) authenticates with a REAL password — so without this, every such connection
# fails "password authentication failed", even once pg_hba.conf correctly allows the address.
# ⚠️ ONLY RUNS IF urbalurba-secrets ALREADY EXISTS — on a brand-new lab, core-services get built
# before any `uis deploy`/`uis secrets generate` has ever run, so this secret may not exist yet.
# That's fine: this step is specifically "wire an existing cluster to this postgres", which by
# definition happens after the cluster has secrets. Skipping quietly here, not failing, is correct
# for that ordering — rerun this script once secrets exist if this skips.
PGPASSWORD_B64="$(kubectl get secret urbalurba-secrets -n default -o jsonpath='{.data.PGPASSWORD}' 2>/dev/null || true)"
if [[ -n "$PGPASSWORD_B64" ]]; then
    print_status "Syncing ${PG_NAME}'s postgres superuser password to match urbalurba-secrets..."
    REAL_PG_PASSWORD="$(echo "$PGPASSWORD_B64" | base64 -d)"
    ssh -i "$PROXMOX_SSH_KEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new "root@${PG_IP}" \
        "sudo -u postgres psql -c \"ALTER ROLE postgres WITH PASSWORD '${REAL_PG_PASSWORD}'\"" >/dev/null
    print_success "${PG_NAME}'s postgres password now matches urbalurba-secrets's PGPASSWORD."
else
    echo "  (urbalurba-secrets not found on ${TARGET} yet — skipping password sync. Run this"
    echo "   script again after 'uis secrets generate' / a first deploy if postgresql verify"
    echo "   fails with \"password authentication failed\".)"
fi
