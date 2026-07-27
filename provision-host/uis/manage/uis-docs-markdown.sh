#!/bin/bash
# uis-docs-markdown.sh - Generate Markdown documentation from service metadata
#
# Scans service scripts for metadata and generates Docusaurus-compatible
# markdown pages for each service and category index pages.
#
# Usage:
#   ./uis-docs-markdown.sh [options] [output-dir]
#
# Options:
#   --force      Overwrite existing files (default: skip if exists)
#   --dry-run    Show what would be generated without writing files
#   --service ID Generate only for a specific service
#   --help       Show this help message
#
# Outputs:
#   website/docs/services/<category>/<service>.md  - Per-service pages
#   website/docs/services/<category>/index.md      - Category index pages

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UIS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$UIS_DIR/lib"
SERVICES_DIR="$UIS_DIR/services"

# Source libraries
source "$LIB_DIR/logging.sh"
source "$LIB_DIR/categories.sh"
source "$LIB_DIR/stacks.sh"

# Options
FORCE=false
DRY_RUN=false
SINGLE_SERVICE=""

# Detect output directory
_detect_docs_dir() {
    if [[ -n "${1:-}" ]]; then
        echo "$1"
        return 0
    fi
    # Container path
    if [[ -d "/mnt/urbalurbadisk/website" ]]; then
        echo "/mnt/urbalurbadisk/website/docs/services"
        return 0
    fi
    # Host path: derive from script location
    local base_dir
    base_dir="$(cd "$SCRIPT_DIR/../../.." && pwd)"
    if [[ -d "$base_dir/website" ]]; then
        echo "$base_dir/website/docs/services"
        return 0
    fi
    echo "./docs/services"
}

# ============================================================
# Metadata Extraction
# ============================================================

# Extract a single metadata field from a service script file
# Usage: extract_field "SCRIPT_ID" "/path/to/service-redis.sh"
extract_field() {
    local field_name="$1"
    local script_file="$2"
    local value=""
    while IFS= read -r line; do
        case "$line" in
            "${field_name}="*)
                value="${line#${field_name}=}"
                value="${value//\"/}"
                value="${value//\'/}"
                break
                ;;
        esac
    done < "$script_file"
    echo "$value"
}

# Build an associative-style lookup: for each service, which other services require it
# Output: lines of "service_id:dep1 dep2 dep3"
# Usage: build_required_by_map
build_required_by_map() {
    local script
    # Collect all service IDs and their SCRIPT_REQUIRES
    local -a all_ids=()
    local -a all_requires=()

    while IFS= read -r -d '' script; do
        [[ -f "$script" ]] || continue
        [[ "$(basename "$script")" == _* ]] && continue
        local id requires
        id=$(extract_field "SCRIPT_ID" "$script")
        requires=$(extract_field "SCRIPT_REQUIRES" "$script")
        [[ -z "$id" ]] && continue
        all_ids+=("$id")
        all_requires+=("$requires")
    done < <(find "$SERVICES_DIR" -name "service-*.sh" -type f -print0 2>/dev/null | sort -z)

    # For each service, find who requires it
    local i j
    for ((i=0; i<${#all_ids[@]}; i++)); do
        local target="${all_ids[$i]}"
        local required_by=""
        for ((j=0; j<${#all_ids[@]}; j++)); do
            local reqs="${all_requires[$j]}"
            for req in $reqs; do
                if [[ "$req" == "$target" ]]; then
                    required_by="${required_by:+$required_by }${all_ids[$j]}"
                fi
            done
        done
        echo "${target}:${required_by}"
    done
}

# ============================================================
# Service Page Generator
# ============================================================

generate_service_page() {
    local script_file="$1"
    local output_dir="$2"
    local required_by_map="$3"

    # Extract all metadata
    local id name desc category abstract summary website
    local helm_chart namespace image requires check_command
    id=$(extract_field "SCRIPT_ID" "$script_file")
    name=$(extract_field "SCRIPT_NAME" "$script_file")
    desc=$(extract_field "SCRIPT_DESCRIPTION" "$script_file")
    category=$(extract_field "SCRIPT_CATEGORY" "$script_file")
    abstract=$(extract_field "SCRIPT_ABSTRACT" "$script_file")
    summary=$(extract_field "SCRIPT_SUMMARY" "$script_file")
    website=$(extract_field "SCRIPT_WEBSITE" "$script_file")
    helm_chart=$(extract_field "SCRIPT_HELM_CHART" "$script_file")
    namespace=$(extract_field "SCRIPT_NAMESPACE" "$script_file")
    image=$(extract_field "SCRIPT_IMAGE" "$script_file")
    requires=$(extract_field "SCRIPT_REQUIRES" "$script_file")
    check_command=$(extract_field "SCRIPT_CHECK_COMMAND" "$script_file")

    [[ -z "$id" ]] && return 1

    # Get category display name
    local cat_name
    cat_name=$(get_category_name "$category" 2>/dev/null) || cat_name="$category"
    local cat_lower
    cat_lower=$(echo "$category" | tr '[:upper:]' '[:lower:]')

    # Resolve "required by" from map
    local required_by=""
    while IFS= read -r line; do
        local map_id="${line%%:*}"
        local map_deps="${line#*:}"
        if [[ "$map_id" == "$id" ]]; then
            required_by="$map_deps"
            break
        fi
    done <<< "$required_by_map"

    # Determine output file path
    local target_dir="${output_dir}/${cat_lower}"
    local target_file="${target_dir}/${id}.md"

    # Check if file exists (safe mode)
    if [[ -f "$target_file" ]] && [[ "$FORCE" != "true" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            echo "  SKIP (exists): $target_file"
        fi
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  GENERATE: $target_file"
        return 0
    fi

    mkdir -p "$target_dir"

    # Build the Helm/Image row for the info table
    local deploy_info_row=""
    if [[ -n "$helm_chart" ]]; then
        deploy_info_row="| **Helm chart** | \`${helm_chart}\` (unpinned) |"
    elif [[ -n "$image" ]]; then
        deploy_info_row="| **Image** | \`${image}\` |"
    fi

    # Build depends-on string
    local depends_on="None"
    if [[ -n "$requires" ]]; then
        depends_on=""
        for req in $requires; do
            depends_on="${depends_on:+$depends_on, }${req}"
        done
    fi

    # Build required-by string
    local required_by_str="None"
    if [[ -n "$required_by" ]]; then
        required_by_str=""
        for dep in $required_by; do
            required_by_str="${required_by_str:+$required_by_str, }${dep}"
        done
    fi

    # Build deploy prerequisites
    local deploy_prereqs=""
    if [[ -n "$requires" ]]; then
        deploy_prereqs="# Prerequisites — deploy dependencies first"
        for req in $requires; do
            deploy_prereqs="${deploy_prereqs}
./uis deploy ${req}"
        done
        deploy_prereqs="${deploy_prereqs}

"
    fi

    # Build verify manual check
    local verify_manual=""
    if [[ -n "$check_command" ]]; then
        # Extract the kubectl command from check_command (remove trailing grep/piping for readability)
        local kubectl_cmd
        kubectl_cmd=$(echo "$check_command" | sed 's/ 2>\/dev\/null.*//; s/ --no-headers//')
        verify_manual="
# Manual check
${kubectl_cmd}"
    fi

    # Build learn more section
    local learn_more=""
    if [[ -n "$website" ]]; then
        learn_more="- [Official ${name} documentation](${website})"
    fi

    # Write the page
    cat > "$target_file" <<MARKDOWN
---
title: ${name}
sidebar_label: ${name}
---

# ${name}

${desc}

| | |
|---|---|
| **Category** | ${cat_name} |
| **Deploy** | \`./uis deploy ${id}\` |
| **Undeploy** | \`./uis undeploy ${id}\` |
| **Depends on** | ${depends_on} |
| **Required by** | ${required_by_str} |
${deploy_info_row}
| **Default namespace** | \`${namespace:-default}\` |

## What It Does

${summary:-_No summary available. Edit this section to add a description of what ${name} does in UIS._}

## Deploy

\`\`\`bash
${deploy_prereqs}# Deploy ${name}
./uis deploy ${id}
\`\`\`

## Verify

\`\`\`bash
# Quick check
./uis verify ${id}
${verify_manual}
\`\`\`

## Configuration

<!-- MANUAL: Service-specific configuration details -->
_No configuration documentation yet. Edit this section to add details about ${name} settings, secrets, and customization options._

## Undeploy

\`\`\`bash
./uis undeploy ${id}
\`\`\`

## Troubleshooting

<!-- MANUAL: Common issues and solutions -->
_No troubleshooting documentation yet. Edit this section to add common issues and their solutions._

## Learn More

${learn_more:-_No external links available._}
MARKDOWN

    log_info "Generated: $target_file"
}

# ============================================================
# Category Index Page Generator
# ============================================================

# Check if a category is a package (has a stack)
is_package_category() {
    local cat_id="$1"
    local stack_id
    for stack_id in "${STACK_ORDER[@]}"; do
        local stack_cat
        stack_cat=$(get_stack_category "$stack_id" 2>/dev/null) || continue
        if [[ "$stack_cat" == "$cat_id" ]]; then
            echo "$stack_id"
            return 0
        fi
    done
    return 1
}

generate_category_index() {
    local cat_id="$1"
    local output_dir="$2"

    local cat_name cat_desc
    cat_name=$(get_category_name "$cat_id" 2>/dev/null) || cat_name="$cat_id"
    cat_desc=$(get_category_description "$cat_id" 2>/dev/null) || cat_desc=""
    local cat_lower
    cat_lower=$(echo "$cat_id" | tr '[:upper:]' '[:lower:]')

    local target_dir="${output_dir}/${cat_lower}"
    local target_file="${target_dir}/index.md"

    if [[ -f "$target_file" ]] && [[ "$FORCE" != "true" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            echo "  SKIP (exists): $target_file"
        fi
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  GENERATE: $target_file"
        return 0
    fi

    mkdir -p "$target_dir"

    # Find all services in this category
    local -a svc_ids=()
    local -a svc_names=()
    local -a svc_descs=()

    local script
    while IFS= read -r -d '' script; do
        [[ -f "$script" ]] || continue
        [[ "$(basename "$script")" == _* ]] && continue
        local svc_cat
        svc_cat=$(extract_field "SCRIPT_CATEGORY" "$script")
        if [[ "$svc_cat" == "$cat_id" ]]; then
            local svc_id svc_name svc_desc
            svc_id=$(extract_field "SCRIPT_ID" "$script")
            svc_name=$(extract_field "SCRIPT_NAME" "$script")
            svc_desc=$(extract_field "SCRIPT_DESCRIPTION" "$script")
            [[ -z "$svc_id" ]] && continue
            svc_ids+=("$svc_id")
            svc_names+=("${svc_name:-$svc_id}")
            svc_descs+=("${svc_desc:-}")
        fi
    done < <(find "$SERVICES_DIR" -name "service-*.sh" -type f -print0 2>/dev/null | sort -z)

    # Build services table
    local services_table=""
    local i
    for ((i=0; i<${#svc_ids[@]}; i++)); do
        services_table="${services_table}| [${svc_names[$i]}](./${svc_ids[$i]}.md) | ${svc_descs[$i]} | \`./uis deploy ${svc_ids[$i]}\` |
"
    done

    # Check if this category is a package (has a stack)
    local stack_id
    if stack_id=$(is_package_category "$cat_id"); then
        # Package index: integrated services with deploy sequence
        local deploy_sequence=""
        local services_csv
        services_csv=$(get_stack_services "$stack_id" 2>/dev/null)
        if [[ -n "$services_csv" ]]; then
            IFS=',' read -ra svc_array <<< "$services_csv"
            for svc in "${svc_array[@]}"; do
                deploy_sequence="${deploy_sequence}./uis deploy ${svc}
"
            done
        fi

        cat > "$target_file" <<MARKDOWN
---
title: ${cat_name}
sidebar_label: ${cat_name}
---

# ${cat_name}

${cat_desc}. All components are designed to work together as an integrated stack.

## Services

| Service | Description | Deploy |
|---------|-------------|--------|
${services_table}
## Quick Start

Deploy the full stack in order:

\`\`\`bash
./uis stack install ${stack_id}
\`\`\`

Or deploy individually:

\`\`\`bash
${deploy_sequence}\`\`\`
MARKDOWN
    else
        # Category index: independent services
        local deploy_cmds=""
        for ((i=0; i<${#svc_ids[@]}; i++)); do
            deploy_cmds="${deploy_cmds}./uis deploy ${svc_ids[$i]}
"
        done

        cat > "$target_file" <<MARKDOWN
---
title: ${cat_name}
sidebar_label: ${cat_name}
---

# ${cat_name}

${cat_desc}. Deploy the services your application needs.

## Services

| Service | Description | Deploy |
|---------|-------------|--------|
${services_table}
## Quick Start

Deploy the services you need:

\`\`\`bash
${deploy_cmds}\`\`\`
MARKDOWN
    fi

    log_info "Generated: $target_file"
}

# ============================================================
# Main
# ============================================================

usage() {
    echo "Usage: $(basename "$0") [options] [output-dir]"
    echo ""
    echo "Generate Markdown documentation from UIS service metadata."
    echo ""
    echo "Options:"
    echo "  --force        Overwrite existing files (default: skip)"
    echo "  --dry-run      Show what would be generated without writing"
    echo "  --service ID   Generate only for a specific service"
    echo "  --help         Show this help message"
    echo ""
    echo "Default output: website/docs/services/"
}

main() {
    local output_dir_arg=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) FORCE=true; shift ;;
            --dry-run) DRY_RUN=true; shift ;;
            --service) SINGLE_SERVICE="$2"; shift 2 ;;
            --help) usage; exit 0 ;;
            *) output_dir_arg="$1"; shift ;;
        esac
    done

    local OUTPUT_DIR
    OUTPUT_DIR=$(_detect_docs_dir "$output_dir_arg")

    print_section "UIS Markdown Documentation Generator"
    echo ""
    echo "Output directory: $OUTPUT_DIR"
    echo "Mode: $(if $FORCE; then echo "force (overwrite)"; elif $DRY_RUN; then echo "dry-run"; else echo "safe (skip existing)"; fi)"
    [[ -n "$SINGLE_SERVICE" ]] && echo "Service filter: $SINGLE_SERVICE"
    echo ""

    # Build the "required by" reverse lookup map
    log_info "Building dependency map..."
    local required_by_map
    required_by_map=$(build_required_by_map)

    # Generate service pages
    log_info "Generating service pages..."
    local count=0
    local script
    while IFS= read -r -d '' script; do
        [[ -f "$script" ]] || continue
        [[ "$(basename "$script")" == _* ]] && continue

        local id
        id=$(extract_field "SCRIPT_ID" "$script")
        [[ -z "$id" ]] && continue

        # Filter by single service if specified
        if [[ -n "$SINGLE_SERVICE" ]] && [[ "$id" != "$SINGLE_SERVICE" ]]; then
            continue
        fi

        generate_service_page "$script" "$OUTPUT_DIR" "$required_by_map"
        ((++count))
    done < <(find "$SERVICES_DIR" -name "service-*.sh" -type f -print0 2>/dev/null | sort -z)

    echo ""
    log_info "Processed $count service(s)"

    # Generate category index pages (unless filtering by single service)
    if [[ -z "$SINGLE_SERVICE" ]]; then
        echo ""
        log_info "Generating category index pages..."
        local cat_id
        for cat_id in "${CATEGORY_ORDER[@]}"; do
            generate_category_index "$cat_id" "$OUTPUT_DIR"
        done
    fi

    echo ""
    if [[ "$DRY_RUN" == "true" ]]; then
        log_success "Dry run complete"
    else
        log_success "Markdown generation complete"
    fi
}

# Run main if not sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
