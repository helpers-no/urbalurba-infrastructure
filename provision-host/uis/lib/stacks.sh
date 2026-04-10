#!/bin/bash
# stacks.sh - UIS Service Stack Definitions
#
# Defines service stacks - groups of services that work together.
# Compatible with bash 3.x (macOS default) and bash 4.x+
#
# Stacks allow installing multiple related services with a single command:
#   uis stack install observability
#
# Usage:
#   source /path/to/stacks.sh
#   get_stack_name "observability"         # Returns "Observability Stack"
#   get_stack_services "observability"     # Returns "prometheus tempo loki otel-collector grafana"
#   is_valid_stack "ai-local"              # Returns 0 (true)

# Guard against multiple sourcing
[[ -n "${_UIS_STACKS_LOADED:-}" ]] && return 0
_UIS_STACKS_LOADED=1

# Stack definitions as indexed arrays (bash 3.x compatible)
# Format: id|name|description|category|tags|abstract|services|optional_services|summary|docs|logo
_STACK_DATA=(
    "observability|Observability Stack|Complete monitoring with metrics, logs, and distributed tracing|OBSERVABILITY|monitoring,metrics,logs,tracing,grafana,prometheus|Full observability with Prometheus, Loki, Tempo, and Grafana|prometheus,tempo,loki,otel-collector,grafana|otel-collector|The observability stack provides full visibility into your infrastructure. Prometheus collects metrics, Loki aggregates logs, Tempo stores traces, and Grafana visualizes everything in unified dashboards. The OpenTelemetry Collector receives telemetry data from applications.|/docs/stacks/observability|observability-stack-logo.svg"
    "ai-local|Local AI Stack|Run AI models locally with a unified API and chat interface|AI|ai,llm,ollama,openai,chat,local|Self-hosted AI with LiteLLM proxy and Open WebUI|litellm,openwebui||The local AI stack provides a unified LLM interface. LiteLLM proxies to external Ollama (on host Mac) and cloud providers, while Open WebUI offers a ChatGPT-like interface for users. Note: Ollama runs on the host machine, not in-cluster.|/docs/stacks/ai-local|ai-local-stack-logo.svg"
    "analytics|Analytics Stack|Collaborative data science platform with notebooks and distributed computing|ANALYTICS|analytics,spark,jupyter,notebooks,datascience|Analytics platform with Spark, JupyterHub, and Unity Catalog|spark,jupyterhub,unity-catalog|unity-catalog|The analytics stack provides a complete platform for data analysis and ML workflows. Apache Spark handles distributed computing, JupyterHub provides collaborative notebooks, and Unity Catalog manages data governance.|/docs/stacks/analytics|datascience-stack-logo.svg"
)

# Stack display order (just the IDs)
STACK_ORDER=(observability ai-local analytics)

# Internal: Find stack data by ID
# Usage: _find_stack_data "observability"
# Returns: The full data string or empty if not found
_find_stack_data() {
    local stack_id="$1"
    local entry
    for entry in "${_STACK_DATA[@]}"; do
        local id="${entry%%|*}"
        if [[ "$id" == "$stack_id" ]]; then
            echo "$entry"
            return 0
        fi
    done
    return 1
}

# Helper to extract field by position
# Format: id|name|description|category|tags|abstract|services|optional|summary|docs|logo
#         0   1      2          3       4      5        6       7        8      9    10
_get_field() {
    local data="$1"
    local field_num="$2"
    local i=0
    local rest="$data"

    while [[ $i -lt $field_num ]]; do
        rest="${rest#*|}"
        ((++i))
    done
    echo "${rest%%|*}"
}

# Get display name for a stack
# Usage: get_stack_name "observability"
# Output: "Observability Stack"
get_stack_name() {
    local data
    data=$(_find_stack_data "$1") || return 1
    _get_field "$data" 1
}

# Get description for a stack
# Usage: get_stack_description "observability"
# Output: "Complete monitoring with metrics, logs, and distributed tracing"
get_stack_description() {
    local data
    data=$(_find_stack_data "$1") || return 1
    _get_field "$data" 2
}

# Get category for a stack
# Usage: get_stack_category "observability"
# Output: "OBSERVABILITY"
get_stack_category() {
    local data
    data=$(_find_stack_data "$1") || return 1
    _get_field "$data" 3
}

# Get tags for a stack (comma-separated)
# Usage: get_stack_tags "observability"
# Output: "monitoring,metrics,logs,tracing,grafana,prometheus"
get_stack_tags() {
    local data
    data=$(_find_stack_data "$1") || return 1
    _get_field "$data" 4
}

# Get abstract for a stack
# Usage: get_stack_abstract "observability"
# Output: "Full observability with Prometheus, Loki, Tempo, and Grafana"
get_stack_abstract() {
    local data
    data=$(_find_stack_data "$1") || return 1
    _get_field "$data" 5
}

# Get services list for a stack (comma-separated)
# Usage: get_stack_services "observability"
# Output: "prometheus,tempo,loki,otel-collector,grafana"
get_stack_services() {
    local data
    data=$(_find_stack_data "$1") || return 1
    _get_field "$data" 6
}

# Get services as space-separated list (for iteration)
# Usage: get_stack_services_list "observability"
# Output: "prometheus tempo loki otel-collector grafana"
get_stack_services_list() {
    local services
    services=$(get_stack_services "$1") || return 1
    echo "${services//,/ }"
}

# Get optional services for a stack (comma-separated)
# Usage: get_stack_optional_services "observability"
# Output: "otel-collector"
get_stack_optional_services() {
    local data
    data=$(_find_stack_data "$1") || return 1
    _get_field "$data" 7
}

# Check if a service is optional in a stack
# Usage: is_optional_service "observability" "otel-collector"
# Returns: 0 if optional, 1 if required
is_optional_service() {
    local stack_id="$1"
    local service_id="$2"
    local optional
    optional=$(get_stack_optional_services "$stack_id") || return 1
    [[ ",$optional," == *",$service_id,"* ]]
}

# Get summary for a stack
# Usage: get_stack_summary "observability"
get_stack_summary() {
    local data
    data=$(_find_stack_data "$1") || return 1
    _get_field "$data" 8
}

# Get docs path for a stack
# Usage: get_stack_docs "observability"
# Output: "/docs/stacks/observability"
get_stack_docs() {
    local data
    data=$(_find_stack_data "$1") || return 1
    _get_field "$data" 9
}

# Get logo for a stack
# Usage: get_stack_logo "observability"
get_stack_logo() {
    local data
    data=$(_find_stack_data "$1") || return 1
    _get_field "$data" 10
}

# Check if a stack ID is valid
# Usage: is_valid_stack "observability"
# Returns: 0 if valid, 1 if not
is_valid_stack() {
    local stack_id="$1"
    _find_stack_data "$stack_id" >/dev/null 2>&1
}

# List all stack IDs in display order
# Usage: list_stacks
# Output: One stack ID per line
list_stacks() {
    local stack_id
    for stack_id in "${STACK_ORDER[@]}"; do
        echo "$stack_id"
    done
}

# Get service count in a stack
# Usage: get_stack_service_count "observability"
# Output: "5"
get_stack_service_count() {
    local services
    services=$(get_stack_services "$1") || return 1
    local count=0
    local IFS=','
    for _ in $services; do
        ((++count))
    done
    echo "$count"
}

# Print stacks in a formatted table
# Usage: print_stacks_table
print_stacks_table() {
    printf "%-15s %-25s %-10s %s\n" "ID" "NAME" "SERVICES" "DESCRIPTION"
    printf "%-15s %-25s %-10s %s\n" "───────────────" "─────────────────────────" "──────────" "───────────────────────────"

    local stack_id
    for stack_id in "${STACK_ORDER[@]}"; do
        local name desc count
        name=$(get_stack_name "$stack_id")
        desc=$(get_stack_description "$stack_id")
        count=$(get_stack_service_count "$stack_id")
        printf "%-15s %-25s %-10s %s\n" "$stack_id" "$name" "$count" "$desc"
    done
}

# Print detailed stack info
# Usage: print_stack_info "observability"
print_stack_info() {
    local stack_id="$1"

    if ! is_valid_stack "$stack_id"; then
        echo "Error: Unknown stack '$stack_id'" >&2
        return 1
    fi

    local name desc category services optional summary abstract docs
    name=$(get_stack_name "$stack_id")
    desc=$(get_stack_description "$stack_id")
    category=$(get_stack_category "$stack_id")
    services=$(get_stack_services "$stack_id")
    optional=$(get_stack_optional_services "$stack_id")
    summary=$(get_stack_summary "$stack_id")
    abstract=$(get_stack_abstract "$stack_id")
    docs=$(get_stack_docs "$stack_id")

    echo "Stack: $name"
    echo "ID: $stack_id"
    echo "Category: $category"
    echo "Abstract: $abstract"
    echo "Description: $desc"
    echo "Docs: $docs"
    echo ""
    echo "Services (in installation order):"

    local pos=1
    local IFS=','
    for service in $services; do
        local marker=""
        if is_optional_service "$stack_id" "$service"; then
            marker=" (optional)"
        fi
        printf "  %d. %s%s\n" "$pos" "$service" "$marker"
        ((++pos))
    done

    echo ""
    echo "Summary:"
    echo "  $summary"
}

# Generate JSON output for stacks (used by uis-docs.sh)
# Usage: generate_stacks_json_internal
# Output: JSON object with stacks array
generate_stacks_json_internal() {
    cat <<'HEADER'
{
  "@context": "https://schema.org",
  "@type": "ItemList",
  "name": "UIS Stacks",
  "description": "Service stacks - groups of services that work together in the Urbalurba Infrastructure Stack",
  "itemListElement": [
HEADER

    local first=true
    local stack_id

    for stack_id in "${STACK_ORDER[@]}"; do
        [[ "$first" != "true" ]] && echo ","
        first=false

        local name desc category tags abstract services optional summary docs logo
        name=$(get_stack_name "$stack_id")
        desc=$(get_stack_description "$stack_id")
        category=$(get_stack_category "$stack_id")
        tags=$(get_stack_tags "$stack_id")
        abstract=$(get_stack_abstract "$stack_id")
        services=$(get_stack_services "$stack_id")
        optional=$(get_stack_optional_services "$stack_id")
        summary=$(get_stack_summary "$stack_id")
        docs=$(get_stack_docs "$stack_id")
        logo=$(get_stack_logo "$stack_id")

        # Convert comma-separated tags to JSON array
        local tags_json="["
        local tag_first=true
        IFS=',' read -ra tag_array <<< "$tags"
        for tag in "${tag_array[@]}"; do
            [[ "$tag_first" != "true" ]] && tags_json+=", "
            tag_first=false
            tags_json+="\"$tag\""
        done
        tags_json+="]"

        # Start stack object
        cat <<EOF
    {
      "@type": "SoftwareSourceCode",
      "identifier": "$stack_id",
      "name": "$name",
      "description": "$desc",
      "category": "$category",
      "tags": $tags_json,
      "abstract": "$abstract",
      "logo": "$logo",
      "summary": "$summary",
      "docs": "$docs",
      "components": [
EOF

        # Add components
        local comp_first=true
        local pos=1
        IFS=',' read -ra svc_array <<< "$services"
        for service in "${svc_array[@]}"; do
            [[ "$comp_first" != "true" ]] && echo ","
            comp_first=false

            local is_opt="false"
            if is_optional_service "$stack_id" "$service"; then
                is_opt="true"
            fi

            # Get service description for note
            local note=""
            case "$service" in
                prometheus) note="Metrics collection and storage" ;;
                tempo) note="Distributed tracing backend" ;;
                loki) note="Log aggregation" ;;
                otel-collector) note="Telemetry data receiver" ;;
                grafana) note="Visualization and dashboards" ;;
                ollama) note="LLM inference engine" ;;
                litellm) note="Unified API gateway" ;;
                openwebui) note="User-facing chat interface" ;;
                spark) note="Distributed computing engine" ;;
                jupyterhub) note="Multi-user notebook server" ;;
                unity-catalog) note="Data catalog and governance" ;;
                *) note="" ;;
            esac

            if [[ "$is_opt" == "true" ]]; then
                cat <<COMP
        {
          "service": "$service",
          "position": $pos,
          "note": "$note",
          "optional": true
        }
COMP
            else
                cat <<COMP
        {
          "service": "$service",
          "position": $pos,
          "note": "$note"
        }
COMP
            fi
            ((++pos))
        done

        # Close components array and stack object
        echo "      ]"
        printf "    }"
    done

    # Close itemListElement and root object
    cat <<'FOOTER'

  ]
}
FOOTER
}
