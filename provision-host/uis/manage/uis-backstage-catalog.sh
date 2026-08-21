#!/bin/bash
# uis-backstage-catalog.sh - Generate Backstage catalog YAML from service definitions
#
# Scans UIS service metadata files and generates a complete Backstage catalog
# with Domain, Systems, Components, Resources, Groups, and Users.
#
# Usage:
#   ./uis-backstage-catalog.sh [--output-dir DIR] [--dry-run]
#
# Options:
#   --output-dir DIR   Output directory (default: generated/backstage/catalog/)
#   --dry-run          Show what would be generated without writing files

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UIS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$UIS_DIR/lib"
SERVICES_DIR="$UIS_DIR/services"

# Source libraries
source "$LIB_DIR/logging.sh"
source "$LIB_DIR/categories.sh"
source "$LIB_DIR/service-scanner.sh"

# ============================================================
# Defaults
# ============================================================

DRY_RUN=false

_detect_output_dir() {
    # Container path
    if [[ -d "/mnt/urbalurbadisk" ]]; then
        echo "/mnt/urbalurbadisk/generated/backstage/catalog"
        return 0
    fi

    # Host path: derive from script location
    local base_dir
    base_dir="$(cd "$SCRIPT_DIR/../../.." && pwd)"
    echo "$base_dir/generated/backstage/catalog"
}

OUTPUT_DIR="$(_detect_output_dir)"

# ============================================================
# Parse arguments
# ============================================================

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            # Positional arg = output dir (uis-docs.sh pattern)
            OUTPUT_DIR="$1"
            shift
            ;;
    esac
done

# ============================================================
# Bash 3.2 compatible helpers
# ============================================================

# Lowercase a string (bash 3.2 compatible — no ${var,,})
to_lower() {
    echo "$1" | tr '[:upper:]' '[:lower:]'
}

# Simple key-value store using a flat string (bash 3.2 — no associative arrays)
# Format: "key1=value1\nkey2=value2\n..."
_KIND_MAP=""

_kind_map_set() {
    local key="$1" value="$2"
    _KIND_MAP="${_KIND_MAP}${key}=${value}"$'\n'
}

_kind_map_get() {
    local key="$1"
    local result
    result=$(echo "$_KIND_MAP" | grep "^${key}=" | head -1 | cut -d= -f2)
    echo "${result:-Component}"
}

# Simple set using a flat string for tracking categories with services
_CATS_WITH_SERVICES=""

_cats_add() {
    local cat="$1"
    # Only add if not already present
    case "$_CATS_WITH_SERVICES" in
        *"|${cat}|"*) ;;
        *) _CATS_WITH_SERVICES="${_CATS_WITH_SERVICES}|${cat}|" ;;
    esac
}

_cats_has() {
    local cat="$1"
    case "$_CATS_WITH_SERVICES" in
        *"|${cat}|"*) return 0 ;;
        *) return 1 ;;
    esac
}

# ============================================================
# YAML helper
# ============================================================

# Escape a string for YAML double-quoted values
yaml_escape() {
    local str="$1"
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    echo "$str"
}

# Write content to file (or print in dry-run mode)
write_file() {
    local file_path="$1"
    local content="$2"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[dry-run] Would write: $file_path"
        return 0
    fi

    mkdir -p "$(dirname "$file_path")"
    printf '%s\n' "$content" > "$file_path"
}

# ============================================================
# Extract all metadata from a service script in a single pass
# ============================================================

extract_all_metadata() {
    local script_file="$1"

    # Reset variables
    _id="" _name="" _desc="" _category=""
    _namespace="" _requires="" _docs=""
    _kind="" _type="" _owner="" _check_command=""
    _provides_apis="" _consumes_apis=""

    while IFS= read -r line; do
        case "$line" in
            SCRIPT_ID=*)
                _id="${line#SCRIPT_ID=}"
                _id="${_id//\"/}"; _id="${_id//\'/}"
                ;;
            SCRIPT_NAME=*)
                _name="${line#SCRIPT_NAME=}"
                _name="${_name//\"/}"; _name="${_name//\'/}"
                ;;
            SCRIPT_DESCRIPTION=*)
                _desc="${line#SCRIPT_DESCRIPTION=}"
                _desc="${_desc//\"/}"; _desc="${_desc//\'/}"
                ;;
            SCRIPT_CATEGORY=*)
                _category="${line#SCRIPT_CATEGORY=}"
                _category="${_category//\"/}"; _category="${_category//\'/}"
                ;;
            SCRIPT_NAMESPACE=*)
                _namespace="${line#SCRIPT_NAMESPACE=}"
                _namespace="${_namespace//\"/}"; _namespace="${_namespace//\'/}"
                ;;
            SCRIPT_REQUIRES=*)
                _requires="${line#SCRIPT_REQUIRES=}"
                _requires="${_requires//\"/}"; _requires="${_requires//\'/}"
                ;;
            SCRIPT_DOCS=*)
                _docs="${line#SCRIPT_DOCS=}"
                _docs="${_docs//\"/}"; _docs="${_docs//\'/}"
                ;;
            SCRIPT_KIND=*)
                _kind="${line#SCRIPT_KIND=}"
                _kind="${_kind//\"/}"; _kind="${_kind//\'/}"
                # Strip inline comments and trailing whitespace
                _kind="${_kind%%#*}"
                _kind="${_kind%% *}"
                _kind="${_kind%	*}"
                ;;
            SCRIPT_TYPE=*)
                _type="${line#SCRIPT_TYPE=}"
                _type="${_type//\"/}"; _type="${_type//\'/}"
                _type="${_type%%#*}"
                _type="${_type%% *}"
                _type="${_type%	*}"
                ;;
            SCRIPT_OWNER=*)
                _owner="${line#SCRIPT_OWNER=}"
                _owner="${_owner//\"/}"; _owner="${_owner//\'/}"
                _owner="${_owner%%#*}"
                _owner="${_owner%% *}"
                _owner="${_owner%	*}"
                ;;
            SCRIPT_CHECK_COMMAND=*)
                _check_command="${line#SCRIPT_CHECK_COMMAND=}"
                _check_command="${_check_command//\"/}"; _check_command="${_check_command//\'/}"
                ;;
            SCRIPT_PROVIDES_APIS=*)
                _provides_apis="${line#SCRIPT_PROVIDES_APIS=}"
                _provides_apis="${_provides_apis//\"/}"; _provides_apis="${_provides_apis//\'/}"
                # Strip inline comments, then trailing whitespace. NOT "%% *" like
                # the scalar fields above: this is a space-separated LIST, and
                # truncating at the first space would silently drop every entry
                # after the first.
                _provides_apis="${_provides_apis%%#*}"
                _provides_apis="${_provides_apis%"${_provides_apis##*[![:space:]]}"}"
                ;;
            SCRIPT_CONSUMES_APIS=*)
                _consumes_apis="${line#SCRIPT_CONSUMES_APIS=}"
                _consumes_apis="${_consumes_apis//\"/}"; _consumes_apis="${_consumes_apis//\'/}"
                _consumes_apis="${_consumes_apis%%#*}"
                _consumes_apis="${_consumes_apis%"${_consumes_apis##*[![:space:]]}"}"
                ;;
        esac
    done < "$script_file"
}

# ============================================================
# Build lookup table: service_id -> SCRIPT_KIND
# Used for dependsOn prefix resolution
# ============================================================

build_kind_map() {
    local script
    while IFS= read -r -d '' script; do
        [[ -f "$script" ]] || continue
        [[ "$(basename "$script")" == _* ]] && continue

        local sid="" skind=""
        while IFS= read -r line; do
            case "$line" in
                SCRIPT_ID=*)
                    sid="${line#SCRIPT_ID=}"
                    sid="${sid//\"/}"; sid="${sid//\'/}"
                    ;;
                SCRIPT_KIND=*)
                    skind="${line#SCRIPT_KIND=}"
                    skind="${skind//\"/}"; skind="${skind//\'/}"
                    skind="${skind%%#*}"; skind="${skind%% *}"; skind="${skind%	*}"
                    ;;
            esac
        done < "$script"

        [[ -z "$sid" ]] && continue
        _kind_map_set "$sid" "${skind:-Component}"
    done < <(find "$SERVICES_DIR" -name "*.sh" -type f -print0 2>/dev/null)
}

# Map category ID to lowercase system name
category_to_system() {
    to_lower "$1"
}

# Determine system owner based on category
category_owner() {
    local cat_id="$1"
    case "$cat_id" in
        AI|ANALYTICS|APPLICATIONS|INTEGRATION) echo "app-team" ;;
        *) echo "platform-team" ;;
    esac
}

# ============================================================
# Generate entities
# ============================================================

generate_domain() {
    local content
    content="apiVersion: backstage.io/v1alpha1
kind: Domain
metadata:
  name: uis-infrastructure
  description: \"The Urbalurba Infrastructure Stack (UIS) - a complete, sovereign self-hosted platform\"
  annotations:
    backstage.io/techdocs-ref: url:https://uis.sovereignsky.no/docs
    uis.sovereignsky.no/docs-url: \"https://uis.sovereignsky.no/docs\"
  links:
    - url: https://uis.sovereignsky.no/docs
      title: UIS Documentation
      icon: docs
    - url: https://github.com/helpers-no/urbalurba-infrastructure
      title: GitHub Repository
      icon: github
spec:
  owner: platform-team"

    write_file "$OUTPUT_DIR/domains/uis-infrastructure.yaml" "$content"
    log_success "Domain: uis-infrastructure"
}

generate_system() {
    local cat_id="$1"
    local system_name
    system_name="$(category_to_system "$cat_id")"
    local owner
    owner="$(category_owner "$cat_id")"
    local cat_name
    cat_name="$(get_category_name "$cat_id")"

    local content
    content="apiVersion: backstage.io/v1alpha1
kind: System
metadata:
  name: ${system_name}
  description: \"${cat_name} system within the UIS platform\"
  annotations:
    backstage.io/techdocs-ref: url:https://uis.sovereignsky.no/docs/packages/${system_name}
    uis.sovereignsky.no/docs-url: \"https://uis.sovereignsky.no/docs/packages/${system_name}\"
  links:
    - url: https://uis.sovereignsky.no/docs/packages/${system_name}
      title: \"${cat_name} Docs\"
      icon: docs
spec:
  owner: ${owner}
  domain: uis-infrastructure"

    write_file "$OUTPUT_DIR/systems/${system_name}.yaml" "$content"
    log_success "System: ${system_name}"
}

generate_groups() {
    local content

    # platform-team
    content="apiVersion: backstage.io/v1alpha1
kind: Group
metadata:
  name: platform-team
  description: \"Platform engineering team responsible for infrastructure, observability, identity, networking and management\"
  annotations:
    uis.sovereignsky.no/docs-url: \"https://uis.sovereignsky.no/docs\"
spec:
  type: team
  children: []
  members:
    - terje"
    write_file "$OUTPUT_DIR/groups/platform-team.yaml" "$content"
    log_success "Group: platform-team"

    # app-team
    content="apiVersion: backstage.io/v1alpha1
kind: Group
metadata:
  name: app-team
  description: \"Application team responsible for AI, integration, analytics and applications\"
  annotations:
    uis.sovereignsky.no/docs-url: \"https://uis.sovereignsky.no/docs\"
spec:
  type: team
  children: []
  members:
    - developer1"
    write_file "$OUTPUT_DIR/groups/app-team.yaml" "$content"
    log_success "Group: app-team"

    # business-owners
    content="apiVersion: backstage.io/v1alpha1
kind: Group
metadata:
  name: business-owners
  description: \"Business ownership group - referenced as business owner on all UIS services\"
  annotations:
    uis.sovereignsky.no/docs-url: \"https://uis.sovereignsky.no/docs\"
spec:
  type: business-unit
  children: []"
    write_file "$OUTPUT_DIR/groups/business-owners.yaml" "$content"
    log_success "Group: business-owners"
}

generate_users() {
    local content

    # terje
    content="apiVersion: backstage.io/v1alpha1
kind: User
metadata:
  name: terje
  description: \"UIS team member\"
spec:
  profile:
    displayName: \"Terje Christensen\"
    email: \"terje@sovereignsky.no\"
  memberOf:
    - platform-team"
    write_file "$OUTPUT_DIR/users/terje.yaml" "$content"
    log_success "User: terje"

    # developer1
    content="apiVersion: backstage.io/v1alpha1
kind: User
metadata:
  name: developer1
  description: \"UIS team member\"
spec:
  profile:
    displayName: \"App Developer\"
    email: \"developer@sovereignsky.no\"
  memberOf:
    - app-team"
    write_file "$OUTPUT_DIR/users/developer1.yaml" "$content"
    log_success "User: developer1"
}

# Generate a Component or Resource entity from service metadata
generate_service_entity() {
    local id="$1" name="$2" desc="$3" category="$4"
    local namespace="$5" requires="$6" docs="$7"
    local kind="$8" type="$9" owner="${10}" check_command="${11}"
    local provides_apis="${12}" consumes_apis="${13}"

    # Defaults
    kind="${kind:-Component}"
    type="${type:-service}"
    owner="${owner:-platform-team}"
    namespace="${namespace:-default}"

    local system
    system="$(category_to_system "$category")"

    # Determine docs URL
    local docs_url="https://uis.sovereignsky.no${docs}"

    # Determine output subdirectory
    local subdir="components"
    [[ "$kind" == "Resource" ]] && subdir="resources"

    # Build the entity
    local escaped_desc
    escaped_desc="$(yaml_escape "$desc")"

    local content
    content="apiVersion: backstage.io/v1alpha1
kind: ${kind}
metadata:
  name: ${id}
  description: \"${escaped_desc}\""

    # Annotations
    content+="
  annotations:
    backstage.io/techdocs-ref: url:${docs_url}"

    # Components and Resources get kubernetes annotations
    if [[ "$kind" == "Component" || "$kind" == "Resource" ]]; then
        # Extract label selector from SCRIPT_CHECK_COMMAND (e.g., "-l app.kubernetes.io/name=nginx")
        local label_selector=""
        if [[ "$check_command" =~ -l[[:space:]]*([^[:space:]]+) ]]; then
            label_selector="${BASH_REMATCH[1]}"
        fi

        content+="
    backstage.io/kubernetes-namespace: ${namespace}"
        if [[ -n "$label_selector" ]]; then
            content+="
    backstage.io/kubernetes-label-selector: \"${label_selector}\""
        else
            # Fallback for services without SCRIPT_CHECK_COMMAND
            content+="
    backstage.io/kubernetes-id: ${id}"
        fi
    fi

    content+="
    grafana/dashboard-selector: \"tag:${id}\"
    uis.sovereignsky.no/docs-url: \"${docs_url}\"
    uis.sovereignsky.no/business-owner: \"business-owners\""

    # Links
    content+="
  links:
    - url: ${docs_url}
      title: \"${id} Docs\"
      icon: docs"

    # Spec
    content+="
spec:
  type: ${type}
  lifecycle: production
  owner: ${owner}
  system: ${system}"

    # providesApis
    if [[ -n "$provides_apis" ]]; then
        content+="
  providesApis:"
        local api
        for api in $provides_apis; do
            content+="
    - ${api}"
        done
    fi

    # consumesApis
    if [[ -n "$consumes_apis" ]]; then
        content+="
  consumesApis:"
        local api
        for api in $consumes_apis; do
            content+="
    - ${api}"
        done
    fi

    # dependsOn
    if [[ -n "$requires" ]]; then
        content+="
  dependsOn:"
        local req
        for req in $requires; do
            local req_kind
            req_kind="$(_kind_map_get "$req")"
            local prefix="component"
            [[ "$req_kind" == "Resource" ]] && prefix="resource"
            content+="
    - ${prefix}:${req}"
        done
    fi

    write_file "$OUTPUT_DIR/${subdir}/${id}.yaml" "$content"
    log_success "${kind}: ${id}"

    # Track for all.yaml
    ALL_TARGETS+=("    - ./${subdir}/${id}.yaml")
}

# Collect API metadata from all service definitions for API entity generation
# Stores: "|api_name|desc|owner|system|docs|namespace|check_command\n..."
_API_REGISTRY=""

_api_register() {
    local api_name="$1" desc="$2" owner="$3" system="$4" docs="$5"
    local namespace="$6" check_command="$7"
    # Only register if not already present
    case "$_API_REGISTRY" in
        *"|${api_name}|"*) ;;
        *) _API_REGISTRY="${_API_REGISTRY}|${api_name}|${desc}|${owner}|${system}|${docs}|${namespace}|${check_command}"$'\n' ;;
    esac
}

# Register APIs from a service's SCRIPT_PROVIDES_APIS
register_service_apis() {
    local provides_apis="$1" desc="$2" owner="$3" system="$4" docs="$5"
    local namespace="$6" check_command="$7"
    [[ -z "$provides_apis" ]] && return
    local api
    for api in $provides_apis; do
        _api_register "$api" "$desc" "$owner" "$system" "$docs" "$namespace" "$check_command"
    done
}

# Generate all API entities from the registry
generate_api_entities() {
    [[ -z "$_API_REGISTRY" ]] && return

    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        # Parse: |api_name|desc|owner|system|docs|namespace|check_command
        local api_name desc owner system docs namespace check_command
        api_name=$(echo "$line" | cut -d'|' -f2)
        desc=$(echo "$line" | cut -d'|' -f3)
        owner=$(echo "$line" | cut -d'|' -f4)
        system=$(echo "$line" | cut -d'|' -f5)
        docs=$(echo "$line" | cut -d'|' -f6)
        namespace=$(echo "$line" | cut -d'|' -f7)
        check_command=$(echo "$line" | cut -d'|' -f8)

        [[ -z "$api_name" ]] && continue

        local docs_url="https://uis.sovereignsky.no${docs}"
        local escaped_desc
        escaped_desc="$(yaml_escape "$desc")"

        local content
        content="apiVersion: backstage.io/v1alpha1
kind: API
metadata:
  name: ${api_name}
  description: \"${escaped_desc}\"
  annotations:
    backstage.io/techdocs-ref: url:${docs_url}"

        # Add K8s annotations from parent service
        if [[ -n "$namespace" ]]; then
            content+="
    backstage.io/kubernetes-namespace: ${namespace}"
        fi
        if [[ -n "$check_command" ]]; then
            local label_selector=""
            if [[ "$check_command" =~ -l[[:space:]]*([^[:space:]]+) ]]; then
                label_selector="${BASH_REMATCH[1]}"
            fi
            if [[ -n "$label_selector" ]]; then
                content+="
    backstage.io/kubernetes-label-selector: \"${label_selector}\""
            fi
        fi

        content+="
    uis.sovereignsky.no/docs-url: \"${docs_url}\"
  links:
    - url: ${docs_url}
      title: \"${api_name} Docs\"
      icon: docs
spec:
  type: description
  lifecycle: production
  owner: ${owner}
  system: ${system}
  definition: \"${escaped_desc}\""

        write_file "$OUTPUT_DIR/apis/${api_name}.yaml" "$content"
        log_success "API: ${api_name}"
        ALL_TARGETS+=("    - ./apis/${api_name}.yaml")
    done <<< "$_API_REGISTRY"
}

# Generate static component entries for bundled services without service definitions
generate_static_components() {
    # Tika - bundled with AI stack, no service definition
    local content
    content="apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: tika
  description: \"Document text extraction service for AI pipelines (PDF, DOCX, etc.)\"
  annotations:
    backstage.io/techdocs-ref: url:https://uis.sovereignsky.no/docs/packages/ai/tika
    backstage.io/kubernetes-label-selector: \"app.kubernetes.io/instance=tika\"
    backstage.io/kubernetes-namespace: ai
    grafana/dashboard-selector: \"tag:tika\"
    uis.sovereignsky.no/docs-url: \"https://uis.sovereignsky.no/docs/packages/ai/tika\"
    uis.sovereignsky.no/business-owner: \"business-owners\"
  links:
    - url: https://uis.sovereignsky.no/docs/packages/ai/tika
      title: \"tika Docs\"
      icon: docs
spec:
  type: service
  lifecycle: production
  owner: app-team
  system: ai
  providesApis:
    - tika-api"

    write_file "$OUTPUT_DIR/components/tika.yaml" "$content"
    log_success "Component: tika (static)"
    ALL_TARGETS+=("    - ./components/tika.yaml")

    # OnlyOffice - bundled with Nextcloud, no service definition
    content="apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: onlyoffice
  description: \"Document editor for Nextcloud (DOCX, XLSX, PPTX editing in browser)\"
  annotations:
    backstage.io/techdocs-ref: url:https://uis.sovereignsky.no/docs/packages/applications/onlyoffice
    backstage.io/kubernetes-label-selector: \"app=onlyoffice\"
    backstage.io/kubernetes-namespace: nextcloud
    grafana/dashboard-selector: \"tag:onlyoffice\"
    uis.sovereignsky.no/docs-url: \"https://uis.sovereignsky.no/docs/packages/applications/onlyoffice\"
    uis.sovereignsky.no/business-owner: \"business-owners\"
  links:
    - url: https://uis.sovereignsky.no/docs/packages/applications/onlyoffice
      title: \"onlyoffice Docs\"
      icon: docs
spec:
  type: service
  lifecycle: production
  owner: app-team
  system: applications
  dependsOn:
    - component:nextcloud"

    write_file "$OUTPUT_DIR/components/onlyoffice.yaml" "$content"
    log_success "Component: onlyoffice (static)"
    ALL_TARGETS+=("    - ./components/onlyoffice.yaml")
}

generate_all_yaml() {
    # Sort targets for deterministic output
    local sorted_targets
    sorted_targets=$(printf '%s\n' "${ALL_TARGETS[@]}" | sort)

    # Group targets by type
    local groups_list="" users_list="" domains_list="" systems_list=""
    local resources_list="" components_list="" apis_list=""

    while IFS= read -r target; do
        [[ -z "$target" ]] && continue
        case "$target" in
            *./groups/*) groups_list+="$target"$'\n' ;;
            *./users/*) users_list+="$target"$'\n' ;;
            *./domains/*) domains_list+="$target"$'\n' ;;
            *./systems/*) systems_list+="$target"$'\n' ;;
            *./resources/*) resources_list+="$target"$'\n' ;;
            *./components/*) components_list+="$target"$'\n' ;;
            *./apis/*) apis_list+="$target"$'\n' ;;
        esac
    done <<< "$sorted_targets"

    local content
    content="# UIS Backstage Catalog - Master Location File
# Generated by uis-backstage-catalog.sh — do not edit manually.
# Load this file in your Backstage app-config.yaml:
#
#   catalog:
#     locations:
#       - type: file
#         target: ../../catalog/all.yaml

apiVersion: backstage.io/v1alpha1
kind: Location
metadata:
  name: uis-catalog-root
  description: Root location for all UIS Backstage catalog entities
spec:
  targets:
    # --- Groups ---"

    # Helper: strip subdirectory from path for flat ConfigMap mount
    # e.g., "    - ./components/nginx.yaml" → "    - ./nginx.yaml"
    _flatten() {
        local list="$1"
        while IFS= read -r t; do
            [[ -n "$t" ]] || continue
            # Replace ./subdir/file.yaml with ./file.yaml
            local flat="${t/\.\/*\//\.\/}"
            content+=$'\n'"$flat"
        done <<< "$list"
    }

    _flatten "$groups_list"

    content+=$'\n'"    # --- Users ---"
    _flatten "$users_list"

    content+=$'\n'"    # --- Domain ---"
    _flatten "$domains_list"

    content+=$'\n'"    # --- Systems ---"
    _flatten "$systems_list"

    content+=$'\n'"    # --- Resources ---"
    _flatten "$resources_list"

    content+=$'\n'"    # --- Components ---"
    _flatten "$components_list"

    content+=$'\n'"    # --- APIs ---"
    _flatten "$apis_list"

    write_file "$OUTPUT_DIR/all.yaml" "$content"
    log_success "Location: all.yaml"
}

# ============================================================
# Main
# ============================================================

main() {
    print_section "Backstage Catalog Generator"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "Dry-run mode — no files will be written"
    fi
    log_info "Output directory: $OUTPUT_DIR"

    # Track all targets for all.yaml
    ALL_TARGETS=()

    # --- Phase 1: Build kind lookup map ---
    log_info "Scanning service definitions..."
    build_kind_map

    # --- Phase 2: Static entities ---
    print_subsection "Groups"
    generate_groups
    ALL_TARGETS+=(
        "    - ./groups/app-team.yaml"
        "    - ./groups/business-owners.yaml"
        "    - ./groups/platform-team.yaml"
    )

    print_subsection "Users"
    generate_users
    ALL_TARGETS+=(
        "    - ./users/developer1.yaml"
        "    - ./users/terje.yaml"
    )

    print_subsection "Domain"
    generate_domain
    ALL_TARGETS+=("    - ./domains/uis-infrastructure.yaml")

    # --- Phase 3: Systems (one per category with services) ---
    print_subsection "Systems"

    # Scan to find which categories have services
    local script
    while IFS= read -r -d '' script; do
        [[ -f "$script" ]] || continue
        [[ "$(basename "$script")" == _* ]] && continue

        extract_all_metadata "$script"
        [[ -z "$_id" ]] && continue
        [[ -n "$_category" ]] && _cats_add "$_category"
    done < <(find "$SERVICES_DIR" -name "*.sh" -type f -print0 2>/dev/null)

    # Also mark APPLICATIONS (for Tika/OnlyOffice static entries)
    _cats_add "APPLICATIONS"

    for cat_id in $(list_categories); do
        _cats_has "$cat_id" || continue
        generate_system "$cat_id"
        ALL_TARGETS+=("    - ./systems/$(category_to_system "$cat_id").yaml")
    done

    # --- Phase 4: Components and Resources from service definitions ---
    print_subsection "Services"

    local service_count=0
    while IFS= read -r -d '' script; do
        [[ -f "$script" ]] || continue
        [[ "$(basename "$script")" == _* ]] && continue

        extract_all_metadata "$script"
        [[ -z "$_id" ]] && continue

        generate_service_entity \
            "$_id" "$_name" "$_desc" "$_category" \
            "$_namespace" "$_requires" "$_docs" \
            "$_kind" "$_type" "$_owner" "$_check_command" \
            "$_provides_apis" "$_consumes_apis"

        # Register APIs for API entity generation
        local system
        system="$(category_to_system "$_category")"
        register_service_apis "$_provides_apis" "$_desc" "${_owner:-platform-team}" "$system" "$_docs" "${_namespace:-default}" "$_check_command"

        service_count=$((service_count + 1))
    done < <(find "$SERVICES_DIR" -name "*.sh" -type f -print0 2>/dev/null | sort -z)

    # --- Phase 5: Static component entries ---
    print_subsection "Static Components"
    generate_static_components

    # Register tika API (static component)
    _api_register "tika-api" "Document text extraction service for AI pipelines" "app-team" "ai" "/docs/packages/ai/tika" "ai" "kubectl get pods -n ai -l app.kubernetes.io/instance=tika --no-headers"

    # --- Phase 6: API entities ---
    print_subsection "APIs"
    generate_api_entities

    # --- Phase 7: Generate all.yaml ---
    print_subsection "Location File"
    generate_all_yaml

    # --- Summary ---
    echo ""
    local static_count=2  # Tika + OnlyOffice
    local total_count=$((service_count + static_count))
    log_success "Generated catalog with ${total_count} service entities (${service_count} from definitions + ${static_count} static)"
    log_info "Output: $OUTPUT_DIR"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "Dry-run complete — no files were written"
    fi
}

main "$@"
