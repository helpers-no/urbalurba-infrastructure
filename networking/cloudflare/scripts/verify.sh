#!/bin/bash
# verify.sh — Run the full Cloudflare tunnel verification suite.
#
# Entry point: uis network verify cloudflare [--env <name>]
#
# Delegates to 822-verify-cloudflare.yml, which checks:
#   - urbalurba-secrets has a real (non-placeholder) tunnel token
#   - DNS + TCP/7844 connectivity to argotunnel.com
#   - cloudflared pod count and Running status
#   - Pod log markers ("Registered tunnel connection")
#   - End-to-end HTTPS probe to BASE_DOMAIN_CLOUDFLARE (if set)
#
# --env lets one installation manage more than one tunnel — see
# provision-host/uis/lib/cloudflare-envs.sh. Omitting it is byte-identical to
# this script's original single-tunnel behavior.

set -euo pipefail

# ----- Resolve paths -----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${UIS_REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
PLAYBOOK="$REPO_ROOT/ansible/playbooks/822-verify-cloudflare.yml"

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

# ----- Banner -----
echo "═══════════════════════════════════════════════════════════"
if [[ -n "$CF_ENV" ]]; then
    echo " Cloudflare tunnel verification — environment: $CF_ENV"
    echo " (uis network verify cloudflare --env ${CF_ENV,,})"
else
    echo " Cloudflare tunnel verification"
    echo " (uis network verify cloudflare)"
fi
echo "═══════════════════════════════════════════════════════════"
echo

# ----- Delegate -----
if [[ -n "$CF_ENV" ]]; then
    exec ansible-playbook "$PLAYBOOK" -e "cf_env=$CF_ENV"
else
    exec ansible-playbook "$PLAYBOOK"
fi
