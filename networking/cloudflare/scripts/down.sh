#!/bin/bash
# down.sh — Tear down the in-cluster Cloudflare tunnel deployment.
#
# Entry point: uis network down cloudflare [--env <name>]
#
# Removes the cloudflared Deployment via 821-remove playbook. Leaves the
# Cloudflare-side tunnel intact (the dashboard config is the source of truth
# for routing — destroying it via API is out of scope for this script).
#
# Q12-style preservation: the .uis.secrets/service-keys/cloudflare<-env>.env
# file and the patched CLOUDFLARE_* lines in 00-common-values.env.template stay
# untouched. The user typically re-deploys against the same tunnel; re-running
# the wizard would force them to paste the same token again.
#
# --env lets one installation manage more than one tunnel — see
# provision-host/uis/lib/cloudflare-envs.sh. Omitting it is byte-identical to
# this script's original single-tunnel behavior.

set -euo pipefail

# ----- Resolve paths -----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${UIS_REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"

# ----- Parse --env (optional) -----
source "$REPO_ROOT/provision-host/uis/lib/cloudflare-envs.sh"
CF_ENV=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --env) CF_ENV="${2:-}"; shift 2 || { echo "✗ --env requires a value" >&2; exit 1; } ;;
        --env=*) CF_ENV="${1#--env=}"; shift ;;
        *) echo "✗ Unknown argument: $1" >&2; exit 1 ;;
    esac
done
if [[ -n "$CF_ENV" ]]; then
    CF_ENV="${CF_ENV^^}"
    if ! _cf_env_is_valid "$CF_ENV"; then
        echo "✗ Unknown --env '$CF_ENV'. Supported: ${UIS_CLOUDFLARE_ENVS[*]}" >&2
        exit 1
    fi
fi
CF_SUFFIX="$(_cf_name_suffix "$CF_ENV")"
CF_POD_LABEL="cloudflared${CF_SUFFIX}"
CF_DEPLOYMENT_NAME="cloudflare-tunnel${CF_SUFFIX}"

ENV_FILE="$REPO_ROOT/.uis.secrets/service-keys/cloudflare${CF_SUFFIX}.env"
ENV_FILE_REL=".uis.secrets/service-keys/cloudflare${CF_SUFFIX}.env"
PLAYBOOK="$REPO_ROOT/ansible/playbooks/821-remove-network-cloudflare-tunnel.yml"

# ----- Banner -----
echo "═══════════════════════════════════════════════════════════"
if [[ -n "$CF_ENV" ]]; then
    echo " Cloudflare tunnel tear-down — environment: $CF_ENV"
    echo " (uis network down cloudflare --env ${CF_ENV,,})"
else
    echo " Cloudflare tunnel tear-down"
    echo " (uis network down cloudflare)"
fi
echo "═══════════════════════════════════════════════════════════"
echo
echo "This removes cloudflared pods from the cluster."
echo "The Cloudflare-side tunnel (Zero Trust dashboard) is preserved."
echo

# ----- Delegate to the remove playbook -----
if [[ -n "$CF_ENV" ]]; then
    playbook_ok=0; ansible-playbook "$PLAYBOOK" -e "cf_env=$CF_ENV" || playbook_ok=1
else
    playbook_ok=0; ansible-playbook "$PLAYBOOK" || playbook_ok=1
fi
if [[ "$playbook_ok" -ne 0 ]]; then
    echo
    echo "═══════════════════════════════════════════════════════════"
    echo " ✗ Tear-down failed or partial"
    echo "═══════════════════════════════════════════════════════════"
    echo "  Check pods:    kubectl -n default get pods -l app=$CF_POD_LABEL"
    echo "  Force delete:  kubectl -n default delete deployment $CF_DEPLOYMENT_NAME"
    exit 1
fi

# ----- Summary -----
echo
echo "═══════════════════════════════════════════════════════════"
echo " ✓ Cloudflare tunnel removed${CF_ENV:+ — environment: $CF_ENV}"
echo "═══════════════════════════════════════════════════════════"
echo "  Config is preserved at:"
echo "    $ENV_FILE_REL"
echo
echo "  To redeploy:  ./uis network up cloudflare${CF_ENV:+ --env ${CF_ENV,,}}"
echo "  To reset:     rm $ENV_FILE_REL"
echo
echo "  Cloudflare dashboard cleanup (optional, if retiring the tunnel):"
echo "    https://one.dash.cloudflare.com → Networks → Tunnels → delete tunnel"
