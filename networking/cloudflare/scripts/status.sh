#!/bin/bash
# status.sh — Show Cloudflare tunnel status (config + pods + connectivity).
#
# Entry point: uis network status cloudflare
#
# --summary flag: emits one tab-separated line "<state>\t<hint>" for the
# `uis network list` table (C-1 contract). State machine:
#   1. env file missing                                  → not-initialized
#   2. env present, no cloudflared Deployment in cluster → configured-not-running
#   3. deployment present, at least one pod Running     → running
#   4. deployment present, no pods Running              → unreachable

set -euo pipefail

# ----- Resolve paths -----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${UIS_REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
ENV_FILE="$REPO_ROOT/.uis.secrets/service-keys/cloudflare.env"
ENV_FILE_REL=".uis.secrets/service-keys/cloudflare.env"
KUBECONFIG_PATH="${UIS_KUBECONFIG:-/mnt/urbalurbadisk/.uis.secrets/generated/kubeconfig/kubeconf-all}"

# ----- Flag parsing -----
SUMMARY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --summary) SUMMARY=1; shift ;;
        *) shift ;;
    esac
done

# ----- Helpers -----
_kubectl() {
    if [[ -f "$KUBECONFIG_PATH" ]]; then
        KUBECONFIG="$KUBECONFIG_PATH" kubectl "$@"
    else
        kubectl "$@"
    fi
}

# Count running cloudflared pods. Echoes "<running>/<total>". On failure (e.g.
# no cluster reachable) echoes "0/0" so the caller treats it as not-running.
_pod_counts() {
    local pods total running
    pods=$(_kubectl -n default get pods -l app=cloudflared \
            -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null || echo "")
    if [[ -z "$pods" ]]; then
        echo "0/0"; return
    fi
    total=$(printf '%s\n' "$pods" | grep -c . || true)
    running=$(printf '%s\n' "$pods" | grep -c '^Running$' || true)
    echo "${running}/${total}"
}

# Cluster touch — true iff cloudflared Deployment exists in default namespace.
_deployment_present() {
    _kubectl -n default get deployment cloudflare-tunnel >/dev/null 2>&1
}

# A RUNNING POD IS NOT A WORKING TUNNEL.
#
# cloudflared's liveness/readiness probe hits /ready on :2000, which reports
# whether it is connected to Cloudflare's EDGE. It says nothing about whether the
# origin named in the dashboard route is reachable. So a pod can sit Running and
# Ready forever while every request returns 502 — which is exactly what happened
# in testing (2026-09-18), where this script printed "1/1 cloudflared running" as its
# verdict on a tunnel that served nothing.
#
# The connector logs the origin it is using as `originService=`, and logs an
# "Unable to reach the origin service" error when it cannot connect. Both are in
# the logs of a RUNNING pod, which is why reading logs only when no pod is running
# looked at the one state where the answer cannot be.
#
# Echoes "<reported-origin>" when the connector is failing to reach its origin,
# or nothing when it is not.
_origin_failure() {
    local logs
    logs=$(_kubectl -n default logs -l app=cloudflared --tail=100 2>/dev/null || echo "")
    [[ -z "$logs" ]] && return 0
    printf '%s\n' "$logs" | grep -q 'Unable to reach the origin service' || return 0
    printf '%s\n' "$logs" \
        | grep -oE 'originService=[^ ]+' \
        | sed 's/^originService=//' \
        | sort -u \
        | paste -sd', ' -
}

# ----- Summary path (C-1 contract for `uis network list`) -----
if (( SUMMARY )); then
    if [[ ! -f "$ENV_FILE" ]]; then
        printf 'not-initialized\trun '\''./uis network init cloudflare'\'' to set up\n'
        exit 0
    fi
    if ! _deployment_present; then
        printf 'configured-not-running\trun '\''./uis network up cloudflare'\'' to deploy\n'
        exit 0
    fi
    counts=$(_pod_counts)
    running="${counts%/*}"
    total="${counts#*/}"
    if [[ "$running" -gt 0 ]]; then
        bad_origin="$(_origin_failure)"
        if [[ -n "$bad_origin" ]]; then
            printf 'degraded\tpods up but the origin is unreachable (%s); run '\''./uis network verify cloudflare'\''\n' "$bad_origin"
        else
            printf 'running\t%s/%s cloudflared pods up\n' "$running" "$total"
        fi
    else
        printf 'unreachable\tdeployment exists but no Running pods; check '\''kubectl -n default logs -l app=cloudflared'\''\n'
    fi
    exit 0
fi

# ----- Full status -----
echo "═══════════════════════════════════════════════════════════"
echo " Cloudflare tunnel status"
echo " (uis network status cloudflare)"
echo "═══════════════════════════════════════════════════════════"
echo

if [[ ! -f "$ENV_FILE" ]]; then
    echo "  Config:    not initialized"
    echo "  Setup:     ./uis network init cloudflare"
    exit 0
fi

# shellcheck source=/dev/null
source "$ENV_FILE"
echo "  Config:    $ENV_FILE_REL"
# ${VAR:+...} suppressed the length for an empty token but left the literal
# word "set", so an empty value rendered as "Token:     set ()".
if [[ -n "${CLOUDFLARE_TUNNEL_TOKEN:-}" ]]; then
    echo "  Token:     set (${#CLOUDFLARE_TUNNEL_TOKEN} chars)"
else
    echo "  Token:     not set — run './uis network init cloudflare'"
fi
echo "  Domain:    ${BASE_DOMAIN_CLOUDFLARE:-not set}"

if ! _deployment_present; then
    echo "  Pods:      not deployed"
    echo
    echo "  Deploy:    ./uis network up cloudflare"
    exit 0
fi

counts=$(_pod_counts)
running="${counts%/*}"
total="${counts#*/}"
echo "  Pods:      ${running}/${total} cloudflared running"

if [[ "$running" -eq 0 ]]; then
    echo
    echo "  Pods exist but none are Running. Recent logs:"
    _kubectl -n default logs -l app=cloudflared --tail=20 2>&1 | sed 's/^/    /' || true
    echo
    echo "  Verify:    ./uis network verify cloudflare"
    exit 0
fi

bad_origin="$(_origin_failure)"
if [[ -n "$bad_origin" ]]; then
    echo "  Origin:    ✗ UNREACHABLE"
    echo
    echo "  The pod is connected to Cloudflare, but the connector cannot reach the"
    echo "  origin named in your dashboard route, so every request fails:"
    echo
    echo "    connector reports:  $bad_origin"
    echo "    this cluster has:   http://traefik.kube-system.svc.cluster.local:80"
    echo
    echo "  If those differ, fix the Service URL on both published application"
    echo "  routes in Zero Trust > Networks > Tunnels. The connector reloads from"
    echo "  the edge within seconds — no redeploy needed."
    echo
    echo "  Confirm Traefik:  kubectl get svc -A | grep -i traefik"
else
    echo "  Origin:    reachable (no origin errors in recent logs)"
fi
echo
echo "  Verify e2e: ./uis network verify cloudflare"
echo "  Remove:     ./uis network down cloudflare"
