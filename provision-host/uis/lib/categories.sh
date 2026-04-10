#!/bin/bash
# categories.sh - UIS Service Category Definitions
#
# Defines the service categories used to organize UIS services.
# Compatible with bash 3.x (macOS default) and bash 4.x+
#
# Categories align with cloud provider terminology (Azure/AWS/GCP):
#   OBSERVABILITY: Metrics, logs, tracing (030-039)
#   DATABASES: Data storage and caching (040-099)
#   AI: AI and machine learning (200-229)
#   IDENTITY: Authentication and SSO (070-079)
#   ANALYTICS: Data science and analytics (300-399)
#   MANAGEMENT: Admin tools, GitOps, test services (600-799)
#   NETWORKING: VPN tunnels and network access
#   STORAGE: Platform storage (000-009)
#   INTEGRATION: Messaging and API gateways
#
# Usage:
#   source /path/to/categories.sh
#   get_category_name "OBSERVABILITY"  # Returns "Observability"
#   is_valid_category "AI"             # Returns 0 (true)

# Guard against multiple sourcing
[[ -n "${_UIS_CATEGORIES_LOADED:-}" ]] && return 0
_UIS_CATEGORIES_LOADED=1

# Category definitions as indexed arrays (bash 3.x compatible)
# Format: ID|Display Name|Description|tags|icon|logo
_CATEGORY_DATA=(
    "OBSERVABILITY|Observability|Metrics, logs, and tracing|monitoring,observability|chart-line|monitoring-logo.svg"
    "AI|AI & ML|AI and machine learning services|ai,ml,llm|brain|ai-logo.svg"
    "ANALYTICS|Analytics|Data science and analytics platforms|analytics,datascience|flask|datascience-logo.svg"
    "IDENTITY|Identity|Identity and access management|identity,auth,sso|shield|authentication-logo.svg"
    "DATABASES|Databases|Data storage and caching services|database,storage|database|databases-logo.svg"
    "MANAGEMENT|Management|Admin tools, GitOps, and test services|admin,management|cog|management-logo.svg"
    "APPLICATIONS|Applications|End-user applications and collaboration platforms|applications,collaboration|briefcase|development-logo.svg"
    "NETWORKING|Networking|VPN tunnels and network access|network,vpn|globe|core-logo.svg"
    "STORAGE|Storage|Platform storage infrastructure|storage,persistent|hard-drive|core-logo.svg"
    "INTEGRATION|Integration|Messaging, API gateways, and event streams|integration,messaging|inbox|queues-logo.svg"
)

# Category display order (just the IDs)
CATEGORY_ORDER=(OBSERVABILITY AI ANALYTICS IDENTITY DATABASES MANAGEMENT APPLICATIONS NETWORKING STORAGE INTEGRATION)

# Internal: Find category data by ID
# Usage: _find_category_data "OBSERVABILITY"
# Returns: The full data string or empty if not found
_find_category_data() {
    local cat_id="$1"
    local entry
    for entry in "${_CATEGORY_DATA[@]}"; do
        local id="${entry%%|*}"
        if [[ "$id" == "$cat_id" ]]; then
            echo "$entry"
            return 0
        fi
    done
    return 1
}

# Get display name for a category
# Usage: get_category_name "OBSERVABILITY"
# Output: "Observability"
get_category_name() {
    local cat_id="$1"
    local data
    data=$(_find_category_data "$cat_id") || return 1
    # Format: ID|Name|Description|tags|icon
    local rest="${data#*|}"  # Remove ID|
    echo "${rest%%|*}"       # Get Name (before next |)
}

# Get description for a category
# Usage: get_category_description "OBSERVABILITY"
# Output: "Metrics, logs, and tracing"
get_category_description() {
    local cat_id="$1"
    local data
    data=$(_find_category_data "$cat_id") || return 1
    # Format: ID|Name|Description|tags|icon
    local rest="${data#*|}"      # Remove ID|
    rest="${rest#*|}"            # Remove Name|
    echo "${rest%%|*}"           # Get Description (before next |)
}

# Get tags for a category
# Usage: get_category_tags "OBSERVABILITY"
# Output: "monitoring,observability"
get_category_tags() {
    local cat_id="$1"
    local data
    data=$(_find_category_data "$cat_id") || return 1
    # Format: ID|Name|Description|tags|icon
    local rest="${data#*|}"      # Remove ID|
    rest="${rest#*|}"            # Remove Name|
    rest="${rest#*|}"            # Remove Description|
    echo "${rest%%|*}"           # Get tags (before next |)
}

# Get icon for a category
# Usage: get_category_icon "OBSERVABILITY"
# Output: "chart-line"
get_category_icon() {
    local cat_id="$1"
    local data
    data=$(_find_category_data "$cat_id") || return 1
    # Format: ID|Name|Description|tags|icon|logo
    local rest="${data#*|}"      # Remove ID|
    rest="${rest#*|}"            # Remove Name|
    rest="${rest#*|}"            # Remove Description|
    rest="${rest#*|}"            # Remove tags|
    echo "${rest%%|*}"           # Get icon (before next |)
}

# Get logo filename for a category
# Usage: get_category_logo "OBSERVABILITY"
# Output: "monitoring-logo.svg"
get_category_logo() {
    local cat_id="$1"
    local data
    data=$(_find_category_data "$cat_id") || return 1
    # Format: ID|Name|Description|tags|icon|logo
    echo "${data##*|}"           # Get logo (after last |)
}

# Check if a category ID is valid
# Usage: is_valid_category "OBSERVABILITY"
# Returns: 0 if valid, 1 if not
is_valid_category() {
    local cat_id="$1"
    _find_category_data "$cat_id" >/dev/null 2>&1
}

# List all category IDs in display order
# Usage: list_categories
# Output: One category ID per line
list_categories() {
    local cat_id
    for cat_id in "${CATEGORY_ORDER[@]}"; do
        echo "$cat_id"
    done
}

# Generate JSON output for categories (used by uis-docs.sh)
# Usage: generate_categories_json_internal
# Output: JSON object with categories array
generate_categories_json_internal() {
    echo '{"categories": ['
    local first=true
    local order=0
    local cat_id

    for cat_id in "${CATEGORY_ORDER[@]}"; do
        [[ "$first" != "true" ]] && echo ","
        first=false

        local name desc icon logo
        name=$(get_category_name "$cat_id")
        desc=$(get_category_description "$cat_id")
        icon=$(get_category_icon "$cat_id")
        logo=$(get_category_logo "$cat_id")

        cat <<EOF
    {
      "id": "$cat_id",
      "name": "$name",
      "order": $order,
      "description": "$desc",
      "icon": "$icon",
      "logo": "$logo"
    }
EOF
        ((++order))
    done

    echo ']}'
}

# Print categories in a formatted table
# Usage: print_categories_table
print_categories_table() {
    printf "%-15s %-25s %s\n" "ID" "NAME" "DESCRIPTION"
    printf "%-15s %-25s %s\n" "───────────────" "─────────────────────────" "───────────────────────────"

    local cat_id
    for cat_id in "${CATEGORY_ORDER[@]}"; do
        local name desc
        name=$(get_category_name "$cat_id")
        desc=$(get_category_description "$cat_id")
        printf "%-15s %-25s %s\n" "$cat_id" "$name" "$desc"
    done
}
