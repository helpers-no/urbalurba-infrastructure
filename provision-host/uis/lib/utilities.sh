#!/bin/bash
# utilities.sh - UIS Common Utilities
#
# Provides common helper functions used across UIS scripts.
#
# Usage:
#   source /path/to/utilities.sh

# Guard against multiple sourcing
[[ -n "${_UIS_UTILITIES_LOADED:-}" ]] && return 0
_UIS_UTILITIES_LOADED=1

# Determine the UIS root directory
get_uis_root() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    echo "$(dirname "$script_dir")"
}

# Get the base path for UIS operations
# Inside container: /mnt/urbalurbadisk
# On host: determined by environment or current directory
get_base_path() {
    if [[ -d "/mnt/urbalurbadisk" ]]; then
        echo "/mnt/urbalurbadisk"
    else
        echo "${UIS_BASE_PATH:-$(pwd)}"
    fi
}

# ============================================================================
# Error Handling Functions
# ============================================================================

# Exit codes
readonly EXIT_SUCCESS=0
readonly EXIT_GENERAL_ERROR=1
readonly EXIT_CONFIG_ERROR=2
readonly EXIT_K8S_ERROR=3
readonly EXIT_DEPENDENCY_ERROR=4

# Die with error message
die() {
    log_error "$1"
    exit "${2:-$EXIT_GENERAL_ERROR}"
}

# Die with configuration error
die_config() {
    log_error "Configuration error: $1"
    exit $EXIT_CONFIG_ERROR
}

# Die with Kubernetes error
die_k8s() {
    log_error "Kubernetes error: $1"
    log_error "Is the cluster running? Try: kubectl cluster-info"
    exit $EXIT_K8S_ERROR
}

# Die with dependency error
die_dependency() {
    log_error "Dependency error: $1"
    log_error "Try deploying the required service first"
    exit $EXIT_DEPENDENCY_ERROR
}

# ============================================================================
# Kubernetes Helpers
# ============================================================================

# Check if kubectl is available and can connect to cluster
check_kubernetes_connection() {
    if ! command -v kubectl &>/dev/null; then
        die_k8s "kubectl not found in PATH"
    fi

    if ! kubectl cluster-info &>/dev/null; then
        return 1
    fi
    return 0
}

# Get current Kubernetes context
get_k8s_context() {
    kubectl config current-context 2>/dev/null || echo "none"
}

# ============================================================================
# File Helpers
# ============================================================================

# Check if a file exists and is readable
require_file() {
    local file="$1"
    local description="${2:-File}"

    if [[ ! -f "$file" ]]; then
        die_config "$description not found: $file"
    fi

    if [[ ! -r "$file" ]]; then
        die_config "$description not readable: $file"
    fi
}

# Check if a directory exists
require_directory() {
    local dir="$1"
    local description="${2:-Directory}"

    if [[ ! -d "$dir" ]]; then
        die_config "$description not found: $dir"
    fi
}

# ============================================================================
# Config File Helpers
# ============================================================================

# Read lines from a config file, ignoring comments and empty lines
# Usage: read_config_lines "/path/to/config"
read_config_lines() {
    local config_file="$1"

    require_file "$config_file" "Config file"

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip comments
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        # Skip empty lines
        [[ -z "${line// }" ]] && continue
        # Trim whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        echo "$line"
    done < "$config_file"
}

# Check if a value exists in a config file
# Usage: config_contains "/path/to/config" "value"
config_contains() {
    local config_file="$1"
    local value="$2"

    while IFS= read -r line; do
        [[ "$line" == "$value" ]] && return 0
    done < <(read_config_lines "$config_file")

    return 1
}

# Add a value to a config file if it doesn't exist
# Usage: config_add "/path/to/config" "value"
config_add() {
    local config_file="$1"
    local value="$2"

    if ! config_contains "$config_file" "$value"; then
        echo "$value" >> "$config_file"
        return 0
    fi
    return 1
}

# Remove a value from a config file
# Usage: config_remove "/path/to/config" "value"
config_remove() {
    local config_file="$1"
    local value="$2"
    local temp_file

    temp_file=$(mktemp)

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Keep comments and empty lines
        if [[ "$line" =~ ^[[:space:]]*# ]] || [[ -z "${line// }" ]]; then
            echo "$line" >> "$temp_file"
            continue
        fi

        # Trim and compare
        local trimmed="${line#"${line%%[![:space:]]*}"}"
        trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"

        if [[ "$trimmed" != "$value" ]]; then
            echo "$line" >> "$temp_file"
        fi
    done < "$config_file"

    mv "$temp_file" "$config_file"
}

# ============================================================================
# String Helpers
# ============================================================================

# Check if a string is empty or whitespace only
is_empty() {
    [[ -z "${1// }" ]]
}

# Convert string to lowercase
to_lower() {
    echo "$1" | tr '[:upper:]' '[:lower:]'
}

# Convert string to uppercase
to_upper() {
    echo "$1" | tr '[:lower:]' '[:upper:]'
}
