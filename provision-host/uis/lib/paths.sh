#!/bin/bash
# paths.sh - Centralized path detection for UIS
#
# This is the SINGLE SOURCE OF TRUTH for all UIS paths.
# All other libraries should use these functions instead of implementing their own.
#
# Path detection logic:
# 1. If global variable already set, use it
# 2. If container path exists (/mnt/urbalurbadisk/...), use it
# 3. Fall back to host path using get_base_path()

# Guard against multiple sourcing
[[ -n "${_UIS_PATHS_LOADED:-}" ]] && return 0
_UIS_PATHS_LOADED=1

# Determine script directory for sourcing siblings
_PATHS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source utilities for get_base_path()
[[ -z "${_UIS_UTILITIES_LOADED:-}" ]] && source "$_PATHS_SCRIPT_DIR/utilities.sh"

# ============================================================
# Core Path Detection Functions
# ============================================================

# Get UIS templates directory (container or host)
# Output: Path to provision-host/uis/templates/
get_templates_dir() {
    # If already set, use it
    [[ -n "${TEMPLATES_DIR:-}" ]] && echo "$TEMPLATES_DIR" && return 0

    # Container path
    if [[ -d "/mnt/urbalurbadisk/provision-host/uis/templates" ]]; then
        echo "/mnt/urbalurbadisk/provision-host/uis/templates"
        return 0
    fi

    # Host path: derive from this script's location
    local templates_dir
    templates_dir="$(dirname "$_PATHS_SCRIPT_DIR")/templates"
    if [[ -d "$templates_dir" ]]; then
        echo "$templates_dir"
        return 0
    fi

    # Fallback to container path
    echo "/mnt/urbalurbadisk/provision-host/uis/templates"
}

# Get user's extend directory (.uis.extend/)
# Output: Path to .uis.extend/ directory
get_extend_dir() {
    # If already set, use it
    [[ -n "${EXTEND_DIR:-}" ]] && echo "$EXTEND_DIR" && return 0

    # Container path
    if [[ -d "/mnt/urbalurbadisk/.uis.extend" ]]; then
        echo "/mnt/urbalurbadisk/.uis.extend"
        return 0
    fi

    # Host path: use get_base_path
    echo "$(get_base_path)/.uis.extend"
}

# Get user's secrets directory (.uis.secrets/)
# Output: Path to .uis.secrets/ directory
get_secrets_dir() {
    # If already set, use it
    [[ -n "${SECRETS_DIR:-}" ]] && echo "$SECRETS_DIR" && return 0

    # Container path
    if [[ -d "/mnt/urbalurbadisk/.uis.secrets" ]]; then
        echo "/mnt/urbalurbadisk/.uis.secrets"
        return 0
    fi

    # Host path: use get_base_path
    echo "$(get_base_path)/.uis.secrets"
}

# Get services directory (service scripts)
# Output: Path to provision-host/uis/services/
get_services_dir() {
    # If already set, use it
    [[ -n "${SERVICES_DIR:-}" ]] && echo "$SERVICES_DIR" && return 0

    # Container path
    if [[ -d "/mnt/urbalurbadisk/provision-host/uis/services" ]]; then
        echo "/mnt/urbalurbadisk/provision-host/uis/services"
        return 0
    fi

    # Host path: derive from this script's location
    local services_dir
    services_dir="$(dirname "$_PATHS_SCRIPT_DIR")/services"
    if [[ -d "$services_dir" ]]; then
        echo "$services_dir"
        return 0
    fi

    # Fallback to container path
    echo "/mnt/urbalurbadisk/provision-host/uis/services"
}

# Get tools directory (tool install scripts)
# Output: Path to provision-host/uis/tools/
get_tools_dir() {
    # If already set, use it
    [[ -n "${TOOLS_DIR:-}" ]] && echo "$TOOLS_DIR" && return 0

    # Container path
    if [[ -d "/mnt/urbalurbadisk/provision-host/uis/tools" ]]; then
        echo "/mnt/urbalurbadisk/provision-host/uis/tools"
        return 0
    fi

    # Host path: derive from this script's location
    local tools_dir
    tools_dir="$(dirname "$_PATHS_SCRIPT_DIR")/tools"
    if [[ -d "$tools_dir" ]]; then
        echo "$tools_dir"
        return 0
    fi

    # Fallback to container path
    echo "/mnt/urbalurbadisk/provision-host/uis/tools"
}

# ============================================================
# Derived Path Functions
# ============================================================

# Get host templates directory (for host configurations)
# Output: Path to templates/uis.extend/hosts/
get_hosts_templates_dir() {
    echo "$(get_templates_dir)/uis.extend/hosts"
}

# Get secrets templates directory (for secrets templates)
# Output: Path to templates/uis.secrets/
get_secrets_templates_dir() {
    echo "$(get_templates_dir)/uis.secrets"
}

# Get cloud-init templates directory
# Output: Path to templates/ubuntu-cloud-init/
get_cloud_init_templates_dir() {
    echo "$(get_templates_dir)/ubuntu-cloud-init"
}

# ============================================================
# Global Variables (for backward compatibility)
# ============================================================
# These are set once when paths.sh is sourced, for libraries that
# use global variables instead of function calls.

TEMPLATES_DIR="${TEMPLATES_DIR:-$(get_templates_dir)}"
EXTEND_DIR="${EXTEND_DIR:-$(get_extend_dir)}"
SECRETS_DIR="${SECRETS_DIR:-$(get_secrets_dir)}"
SERVICES_DIR="${SERVICES_DIR:-$(get_services_dir)}"
TOOLS_DIR="${TOOLS_DIR:-$(get_tools_dir)}"

# Export for subprocesses
export TEMPLATES_DIR EXTEND_DIR SECRETS_DIR SERVICES_DIR TOOLS_DIR

# ============================================================
# Derived Secrets Path Functions
# ============================================================

# Get SSH key directory path
# Output: Path to .uis.secrets/ssh/
get_ssh_key_path() {
    echo "$(get_secrets_dir)/ssh"
}

# Get Kubernetes secrets output path
# Output: Path to .uis.secrets/generated/kubernetes/
get_kubernetes_secrets_path() {
    echo "$(get_secrets_dir)/generated/kubernetes"
}

# Get cloud-init output path
# Output: Path to .uis.secrets/generated/ubuntu-cloud-init/
get_cloud_init_output_path() {
    echo "$(get_secrets_dir)/generated/ubuntu-cloud-init"
}

# Get kubeconfig output path
# Output: Path to .uis.secrets/generated/kubeconfig/
get_kubeconfig_path() {
    echo "$(get_secrets_dir)/generated/kubeconfig"
}

# Get Tailscale auth key file path
# Output: Path to .uis.secrets/service-keys/tailscale.env
get_tailscale_key_path() {
    echo "$(get_secrets_dir)/service-keys/tailscale.env"
}

# Get Cloudflare credentials file path
# Output: Path to .uis.secrets/service-keys/cloudflare.env
get_cloudflare_token_path() {
    echo "$(get_secrets_dir)/service-keys/cloudflare.env"
}

# Get cloud account credentials path
# Output: Path to .uis.secrets/cloud-accounts/<provider>-default.env
get_cloud_credentials_path() {
    local provider="${1:-azure}"
    echo "$(get_secrets_dir)/cloud-accounts/${provider}-default.env"
}

# ============================================================
# Helper Functions for Scripts
# ============================================================

# Check if secrets directory exists
# Returns: 0 if .uis.secrets/ structure exists, 1 if not
is_using_new_paths() {
    [[ -d "$(get_secrets_dir)" ]]
}

# Ensure a directory exists, creating it if needed
# Usage: ensure_path_exists <path>
ensure_path_exists() {
    local path="$1"
    [[ -d "$path" ]] || mkdir -p "$path"
}
