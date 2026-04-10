#!/bin/bash
# service-scanner.sh - UIS Service Discovery and Metadata Extraction
#
# Scans service scripts for metadata and provides functions to query services.
#
# Usage:
#   source /path/to/service-scanner.sh
#   scan_setup_scripts "/path/to/services"
#   check_service_deployed "prometheus"

# Guard against multiple sourcing
[[ -n "${_UIS_SERVICE_SCANNER_LOADED:-}" ]] && return 0
_UIS_SERVICE_SCANNER_LOADED=1

# Determine script directory for sourcing paths.sh
_SCANNER_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source paths.sh for SERVICES_DIR (skip if already loaded)
[[ -z "${_UIS_PATHS_LOADED:-}" ]] && source "$_SCANNER_SCRIPT_DIR/paths.sh"

# Note: SERVICES_DIR is set by paths.sh

# Cache for scanned services (bash 3.x compatible using indexed arrays)
# Format: "service_id|/path/to/script"
_SERVICE_CACHE_DATA=()

# Helper: Find in cache by service ID
_find_in_cache() {
    local service_id="$1"
    for entry in "${_SERVICE_CACHE_DATA[@]}"; do
        if [[ "${entry%%|*}" == "$service_id" ]]; then
            echo "${entry#*|}"
            return 0
        fi
    done
    return 1
}

# Helper: Add to cache
_add_to_cache() {
    local service_id="$1"
    local script_path="$2"
    _SERVICE_CACHE_DATA+=("$service_id|$script_path")
}

# Scan directory for service scripts and output metadata
# Usage: scan_setup_scripts [directory]
# Output: tab-separated: basename, id, name, description, category
scan_setup_scripts() {
    local dir="${1:-$SERVICES_DIR}"

    # Find all .sh files in the directory tree
    while IFS= read -r -d '' script; do
        [[ -f "$script" ]] || continue
        # Skip files that start with underscore (helpers)
        [[ "$(basename "$script")" == _* ]] && continue
        extract_script_metadata "$script"
    done < <(find "$dir" -name "*.sh" -type f -print0 2>/dev/null)
}

# Extract metadata from a service script
# Usage: extract_script_metadata <script_path>
# Output: tab-separated line of metadata
extract_script_metadata() {
    local script="$1"
    local basename
    basename=$(basename "$script")

    # Read metadata by parsing the file (safer than sourcing unknown scripts)
    local id="" name="" desc="" cat=""

    while IFS= read -r line; do
        case "$line" in
            SCRIPT_ID=*)
                id="${line#SCRIPT_ID=}"
                id="${id//\"/}"
                id="${id//\'/}"
                ;;
            SCRIPT_NAME=*)
                name="${line#SCRIPT_NAME=}"
                name="${name//\"/}"
                name="${name//\'/}"
                ;;
            SCRIPT_DESCRIPTION=*)
                desc="${line#SCRIPT_DESCRIPTION=}"
                desc="${desc//\"/}"
                desc="${desc//\'/}"
                ;;
            SCRIPT_CATEGORY=*)
                cat="${line#SCRIPT_CATEGORY=}"
                cat="${cat//\"/}"
                cat="${cat//\'/}"
                ;;
        esac
    done < "$script"

    # Only output if we found an ID
    if [[ -n "$id" ]]; then
        printf "%s\t%s\t%s\t%s\t%s\n" "$basename" "$id" "$name" "$desc" "$cat"
    fi
}

# Check if a service is deployed by running its check command
# Usage: check_service_deployed <service_id>
# Returns: 0 if deployed, 1 if not
check_service_deployed() {
    local service_id="$1"
    local script
    script=$(find_service_script "$service_id")
    [[ -z "$script" ]] && return 1

    # Extract SCRIPT_CHECK_COMMAND from script
    local check_cmd=""
    while IFS= read -r line; do
        case "$line" in
            SCRIPT_CHECK_COMMAND=*)
                check_cmd="${line#SCRIPT_CHECK_COMMAND=}"
                check_cmd="${check_cmd//\"/}"
                check_cmd="${check_cmd//\'/}"
                break
                ;;
        esac
    done < "$script"

    [[ -z "$check_cmd" ]] && return 1

    # Run the check command
    eval "$check_cmd" >/dev/null 2>&1
}

# Get a specific metadata field from a service
# Usage: get_service_value <service_id> <field_name>
# Example: get_service_value "prometheus" "SCRIPT_PLAYBOOK"
get_service_value() {
    local service_id="$1"
    local field_name="$2"
    local script
    script=$(find_service_script "$service_id")
    [[ -z "$script" ]] && return 1

    # Extract the requested field from script
    local value=""
    while IFS= read -r line; do
        case "$line" in
            "${field_name}"=*)
                value="${line#${field_name}=}"
                value="${value//\"/}"
                value="${value//\'/}"
                break
                ;;
        esac
    done < "$script"

    echo "$value"
}

# Find script file by service ID
# Usage: find_service_script <service_id>
# Output: full path to script, or empty if not found
find_service_script() {
    local service_id="$1"
    local dir="${SERVICES_DIR}"

    # Check cache first
    local cached
    cached=$(_find_in_cache "$service_id")
    if [[ -n "$cached" ]]; then
        echo "$cached"
        return 0
    fi

    # Search for the script
    while IFS= read -r -d '' script; do
        [[ -f "$script" ]] || continue

        local id=""
        while IFS= read -r line; do
            case "$line" in
                SCRIPT_ID=*)
                    id="${line#SCRIPT_ID=}"
                    id="${id//\"/}"
                    id="${id//\'/}"
                    break
                    ;;
            esac
        done < "$script"

        if [[ "$id" == "$service_id" ]]; then
            _add_to_cache "$service_id" "$script"
            echo "$script"
            return 0
        fi
    done < <(find "$dir" -name "*.sh" -type f -print0 2>/dev/null)

    return 1
}

# Get all services as an array of IDs
# Usage: get_all_service_ids
# Output: service IDs, one per line
get_all_service_ids() {
    local dir="${SERVICES_DIR}"

    while IFS= read -r -d '' script; do
        [[ -f "$script" ]] || continue
        [[ "$(basename "$script")" == _* ]] && continue

        local id=""
        while IFS= read -r line; do
            case "$line" in
                SCRIPT_ID=*)
                    id="${line#SCRIPT_ID=}"
                    id="${id//\"/}"
                    id="${id//\'/}"
                    break
                    ;;
            esac
        done < "$script"

        [[ -n "$id" ]] && echo "$id"
    done < <(find "$dir" -name "*.sh" -type f -print0 2>/dev/null)
}

# Get services by category
# Usage: get_services_by_category <category_id>
# Output: service IDs, one per line
get_services_by_category() {
    local category="$1"
    local dir="${SERVICES_DIR}"

    while IFS= read -r -d '' script; do
        [[ -f "$script" ]] || continue

        local id="" cat=""
        while IFS= read -r line; do
            case "$line" in
                SCRIPT_ID=*)
                    id="${line#SCRIPT_ID=}"
                    id="${id//\"/}"
                    id="${id//\'/}"
                    ;;
                SCRIPT_CATEGORY=*)
                    cat="${line#SCRIPT_CATEGORY=}"
                    cat="${cat//\"/}"
                    cat="${cat//\'/}"
                    ;;
            esac
        done < "$script"

        if [[ "$cat" == "$category" && -n "$id" ]]; then
            echo "$id"
        fi
    done < <(find "$dir" -name "*.sh" -type f -print0 2>/dev/null)
}

# Clear the service cache (useful after adding/removing services)
clear_service_cache() {
    _SERVICE_CACHE_DATA=()
}
