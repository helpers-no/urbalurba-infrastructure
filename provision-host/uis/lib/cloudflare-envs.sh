#!/bin/bash
# cloudflare-envs.sh — the canonical list of named Cloudflare tunnel environments.
#
# One provision-host installation can manage more than one cluster/domain pair
# (e.g. a test and a prod k3s cluster reached via the same container,
# switching CLUSTER_TYPE). Each such pair gets its own Cloudflare Tunnel and
# its own CLOUDFLARE_*_<ENV> secret keys — see networking/cloudflare/scripts/init.sh.
#
# This file is the single source of truth for which <ENV> names are legal.
# Ansible has no clean way to source a bash array, so
# ansible/playbooks/820-deploy-network-cloudflare-tunnel.yml,
# ansible/playbooks/821-remove-network-cloudflare-tunnel.yml and
# ansible/playbooks/822-verify-cloudflare.yml each duplicate this same literal
# list — keep all four in sync if it ever changes.
#
# DEV is reserved for an existing separate installation that predates this
# change. It is not populated or migrated by this file's introduction — only
# TEST and PROD are in active use as of this writing.
#
# Dependency-free on purpose: sourced identically from
# provision-host/uis/lib/secrets-management.sh (which sources logging.sh/
# utilities.sh/paths.sh/first-run.sh) AND from the standalone
# networking/cloudflare/scripts/*.sh, which source nothing from lib/ today.

[[ -n "${_UIS_CLOUDFLARE_ENVS_LOADED:-}" ]] && return 0
_UIS_CLOUDFLARE_ENVS_LOADED=1

UIS_CLOUDFLARE_ENVS=(DEV TEST PROD)

# Usage: _cf_env_is_valid "TEST"  (expects the name already uppercased by the caller)
_cf_env_is_valid() {
    local name="$1" candidate
    for candidate in "${UIS_CLOUDFLARE_ENVS[@]}"; do
        [[ "$candidate" == "$name" ]] && return 0
    done
    return 1
}

# Usage: _cf_var_name CLOUDFLARE_TUNNEL_TOKEN "TEST"   -> CLOUDFLARE_TUNNEL_TOKEN_TEST
# Usage: _cf_var_name CLOUDFLARE_TUNNEL_TOKEN ""        -> CLOUDFLARE_TUNNEL_TOKEN
_cf_var_name() {
    local base="$1" env="${2:-}"
    if [[ -z "$env" ]]; then
        echo "$base"
    else
        echo "${base}_${env}"
    fi
}

# Usage: _cf_name_suffix "TEST"  -> -test   (for Deployment names, pod labels, file names)
# Usage: _cf_name_suffix ""      -> (empty)
_cf_name_suffix() {
    local env="${1:-}"
    if [[ -z "$env" ]]; then
        echo ""
    else
        echo "-${env,,}"
    fi
}
