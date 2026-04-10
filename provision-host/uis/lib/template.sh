#!/bin/bash
# template.sh — UIS template command: fetch registry, browse, install UIS stack templates
#
# Fetches template-registry.json from TMP (helpers-no/dev-templates), filters by
# context: uis, and installs stack templates by deploying services and applying
# init files.
#
# See: helpers-no/dev-templates INVESTIGATE-unified-template-system.md
# See: PLAN-002-uis-template-command.md

UIS_BASE="${UIS_BASE:-/mnt/urbalurbadisk}"
SERVICES_JSON="${UIS_BASE}/website/src/data/services.json"
STACKS_JSON="${UIS_BASE}/website/src/data/stacks.json"

# Registry fetch config
REGISTRY_URL_PRIMARY="https://raw.githubusercontent.com/helpers-no/dev-templates/main/website/src/data/template-registry.json"
REGISTRY_URL_FALLBACK="https://tmp.sovereignsky.no/data/template-registry.json"
REGISTRY_CACHE="/tmp/uis-template-registry.json"
REGISTRY_CACHE_TTL=3600  # 1 hour

# Template fetch config
TEMPLATE_REPO="https://github.com/helpers-no/dev-templates.git"
TEMPLATE_CACHE_DIR="/tmp/uis-templates"

# Check if registry cache is fresh
_registry_cache_fresh() {
    if [[ ! -f "$REGISTRY_CACHE" ]]; then
        return 1
    fi
    local age
    age=$(($(date +%s) - $(stat -c %Y "$REGISTRY_CACHE" 2>/dev/null || echo 0)))
    [[ "$age" -lt "$REGISTRY_CACHE_TTL" ]]
}

# Fetch registry from primary or fallback URL
_fetch_registry() {
    if _registry_cache_fresh; then
        return 0
    fi

    echo "Fetching template registry..." >&2

    if curl -sfL "$REGISTRY_URL_PRIMARY" -o "$REGISTRY_CACHE" 2>/dev/null; then
        return 0
    fi

    echo "Primary URL failed, trying fallback..." >&2
    if curl -sfL "$REGISTRY_URL_FALLBACK" -o "$REGISTRY_CACHE" 2>/dev/null; then
        return 0
    fi

    log_error "Could not fetch template registry from either URL"
    return 1
}

# List UIS templates (context: uis) from the registry
_list_uis_templates() {
    _fetch_registry || return 1
    jq -r '.templates[] | select((.folder // "") | startswith("uis-")) | "\(.id)|\(.name)|\(.description)"' "$REGISTRY_CACHE"
}

# Get UIS categories from the registry
_list_uis_categories() {
    _fetch_registry || return 1
    jq -r '.categories[] | select(.context == "uis") | "\(.id)|\(.name)|\(.emoji)"' "$REGISTRY_CACHE"
}

# Get template details by ID
_get_template() {
    local template_id="$1"
    _fetch_registry || return 1
    jq -r --arg id "$template_id" '.templates[] | select(.id == $id)' "$REGISTRY_CACHE"
}

# Command: uis template list
cmd_template_list() {
    _fetch_registry || return 1

    local templates
    templates=$(_list_uis_templates)

    if [[ -z "$templates" ]]; then
        log_info "No UIS templates found in the registry yet."
        echo "UIS templates will appear when they are added to helpers-no/dev-templates." >&2
        return 0
    fi

    print_section "Available UIS Templates"
    printf "%-25s %-35s %s\n" "ID" "NAME" "DESCRIPTION"
    printf "%-25s %-35s %s\n" "─────────────────────────" "───────────────────────────────────" "──────────────────────────────────"
    echo "$templates" | while IFS='|' read -r id name description; do
        printf "%-25s %-35s %s\n" "$id" "$name" "$description"
    done
    echo ""
    echo "Use 'uis template info <id>' for details"
    echo "Use 'uis template install <id>' to install"
}

# Command: uis template info <id>
cmd_template_info() {
    local template_id="${1:-}"

    if [[ -z "$template_id" ]]; then
        log_error "Usage: uis template info <id>"
        return 1
    fi

    _fetch_registry || return 1

    local template
    template=$(_get_template "$template_id")

    if [[ -z "$template" || "$template" == "null" ]]; then
        log_error "Template '$template_id' not found in registry"
        echo "Run 'uis template list' to see available templates" >&2
        return 1
    fi

    print_section "Template: $template_id"
    echo "$template" | jq -r '
        "Name:        \(.name)",
        "Version:     \(.version)",
        "Category:    \(.category)",
        "Description: \(.description)",
        "",
        "Abstract:",
        "  \(.abstract // "N/A")",
        "",
        "Summary:",
        "  \(.summary // "N/A")",
        "",
        "Tags: \(if (.tags | type) == "array" then (.tags | join(", ")) else .tags end)",
        "Docs: \(.docs // "")"
    '
}

# Sparse-checkout a template folder from the TMP repo
_fetch_template_folder() {
    local folder="$1"
    local target_dir="$TEMPLATE_CACHE_DIR/$folder"

    # Remove any stale checkout
    rm -rf "$TEMPLATE_CACHE_DIR"
    mkdir -p "$TEMPLATE_CACHE_DIR"

    echo "Fetching template folder: $folder" >&2
    (
        cd "$TEMPLATE_CACHE_DIR" || return 1
        git init -q
        git remote add origin "$TEMPLATE_REPO"
        git config core.sparseCheckout true
        echo "$folder" > .git/info/sparse-checkout
        git pull -q --depth=1 origin main
    ) 2>&1 | grep -v "^From \|^ \* " >&2

    if [[ ! -d "$target_dir" ]]; then
        log_error "Failed to fetch template folder: $folder"
        return 1
    fi

    echo "$target_dir"
}

# Parse template-info.yaml field using yq
_yaml_field() {
    local file="$1"
    local path="$2"
    yq -r "$path // \"\"" "$file" 2>/dev/null
}

# Validate template-info.yaml
_validate_template_info() {
    local info_file="$1"
    local template_dir="$2"

    if [[ ! -f "$info_file" ]]; then
        log_error "template-info.yaml not found in template folder"
        return 1
    fi

    local install_type
    install_type=$(_yaml_field "$info_file" ".install_type")
    if [[ "$install_type" != "stack" ]]; then
        log_error "Expected install_type: stack, got: $install_type"
        return 1
    fi

    # Check provides is present
    local has_provides
    has_provides=$(yq -r 'has("provides")' "$info_file" 2>/dev/null)
    if [[ "$has_provides" != "true" ]]; then
        log_error "template-info.yaml missing 'provides' field"
        return 1
    fi

    return 0
}

# Resolve `provides` into an ordered deployment plan
# Outputs one entry per line: <priority>|<service_id>|<database>|<init_file>
_resolve_provides() {
    local info_file="$1"
    local template_dir="$2"

    # Collect services from provides.stacks (expand via stacks.json)
    local stack_services=""
    local stacks
    stacks=$(yq -r '.provides.stacks[]? // empty' "$info_file" 2>/dev/null)
    while IFS= read -r stack_id; do
        [[ -z "$stack_id" ]] && continue
        local svcs
        svcs=$(jq -r --arg id "$stack_id" '.itemListElement[] | select(.identifier == $id) | .components[].service' "$STACKS_JSON" 2>/dev/null)
        stack_services+="$svcs"$'\n'
    done <<< "$stacks"

    # Collect services from provides.services — both plain strings and objects
    # Format each as: <service_id>|<database>|<init_file>
    local direct_services=""
    local service_count
    service_count=$(yq -r '.provides.services // [] | length' "$info_file" 2>/dev/null)
    for ((i=0; i<service_count; i++)); do
        local entry_type
        entry_type=$(yq -r ".provides.services[$i] | type" "$info_file" 2>/dev/null)
        if [[ "$entry_type" == "!!str" ]]; then
            # Plain string — deploy only
            local svc
            svc=$(yq -r ".provides.services[$i]" "$info_file" 2>/dev/null)
            direct_services+="${svc}||"$'\n'
        else
            # Object with service + config
            local svc db init
            svc=$(yq -r ".provides.services[$i].service" "$info_file" 2>/dev/null)
            db=$(yq -r ".provides.services[$i].config.database // \"\"" "$info_file" 2>/dev/null)
            init=$(yq -r ".provides.services[$i].config.init // \"\"" "$info_file" 2>/dev/null)
            direct_services+="${svc}|${db}|${init}"$'\n'
        fi
    done

    # Combine stack services (deploy only) and direct services
    # Deduplicate by service ID (keep direct services if duplicated — they have config)
    local all_services=""
    # First add stack services (deploy-only)
    while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        all_services+="${svc}||"$'\n'
    done <<< "$stack_services"
    # Then append direct services (may override stack entries)
    all_services+="$direct_services"

    # Deduplicate: keep the last entry for each service (direct services win)
    local dedup=""
    local seen=""
    # Process in reverse to keep first (direct) occurrence
    local reversed
    reversed=$(echo "$all_services" | tac)
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local svc="${line%%|*}"
        if [[ -z "$svc" ]]; then continue; fi
        if [[ ",$seen," != *",$svc,"* ]]; then
            seen="$seen,$svc"
            # Add priority prefix for sorting
            local priority
            priority=$(jq -r --arg id "$svc" '.services[] | select(.id == $id) | .priority // 999' "$SERVICES_JSON" 2>/dev/null)
            dedup+="${priority}|${line}"$'\n'
        fi
    done <<< "$reversed"

    # Sort by priority (numeric)
    echo "$dedup" | grep -v '^$' | sort -t'|' -k1,1n
}

# Substitute {{ params.* }} references using a params file (key=value lines)
_substitute_params() {
    local text="$1"
    local params_file="$2"

    [[ ! -f "$params_file" ]] && { echo "$text"; return 0; }

    while IFS='=' read -r key value; do
        [[ -z "$key" ]] && continue
        # Substitute both {{ params.key }} and {{params.key}}
        text="${text//\{\{ params.$key \}\}/$value}"
        text="${text//\{\{params.$key\}\}/$value}"
    done < "$params_file"

    echo "$text"
}

# Build effective params from YAML defaults + CLI overrides
# Outputs key=value lines to stdout
_build_effective_params() {
    local info_file="$1"
    # yq to emit params as key=value lines
    yq -r '.params // {} | to_entries | .[] | "\(.key)=\(.value)"' "$info_file" 2>/dev/null
}

# Command: uis template install <id>
cmd_template_install() {
    local template_id="${1:-}"
    shift || true

    if [[ -z "$template_id" ]]; then
        log_error "Usage: uis template install <id> [--param key=value]..."
        return 1
    fi

    # Parse --param flags
    declare -A cli_params
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --param)
                local kv="$2"
                local k="${kv%%=*}"
                local v="${kv#*=}"
                cli_params["$k"]="$v"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    _fetch_registry || return 1

    local template
    template=$(_get_template "$template_id")
    if [[ -z "$template" || "$template" == "null" ]]; then
        log_error "Template '$template_id' not found in registry"
        echo "Run 'uis template list' to see available templates" >&2
        return 1
    fi

    local folder
    folder=$(echo "$template" | jq -r '.folder // empty')
    if [[ -z "$folder" ]]; then
        log_error "Template '$template_id' has no folder field in registry"
        return 1
    fi

    # Fetch the template folder
    local template_dir
    template_dir=$(_fetch_template_folder "$folder")
    if [[ -z "$template_dir" || ! -d "$template_dir" ]]; then
        log_error "Failed to fetch template folder"
        return 1
    fi

    local info_file="$template_dir/template-info.yaml"

    # Validate
    if ! _validate_template_info "$info_file" "$template_dir"; then
        return 1
    fi

    # Build effective params file (YAML defaults + CLI overrides)
    local params_file="$template_dir/.effective-params"
    _build_effective_params "$info_file" > "$params_file"
    # Apply CLI overrides — remove existing entry, add new
    if [[ ${#cli_params[@]} -gt 0 ]]; then
        for key in "${!cli_params[@]}"; do
            # Remove old entry
            sed -i "/^${key}=/d" "$params_file"
            # Add new entry
            echo "${key}=${cli_params[$key]}" >> "$params_file"
        done
    fi

    log_info "Effective params:"
    sed 's/^/  /' "$params_file" >&2

    # Resolve provides into deployment plan
    local plan
    plan=$(_resolve_provides "$info_file" "$template_dir")

    if [[ -z "$plan" ]]; then
        log_error "Deployment plan is empty — no services in provides"
        return 1
    fi

    print_section "Installing Template: $template_id"
    echo "Template folder: $folder"
    echo ""
    echo "Deployment plan (in priority order):"
    echo "$plan" | while IFS='|' read -r priority svc db init; do
        local action="deploy"
        [[ -n "$db" || -n "$init" ]] && action="deploy + configure"
        echo "  [$priority] $svc — $action"
    done
    echo ""

    # Get app name param from effective params file
    local app_name
    app_name=$(grep '^app_name=' "$params_file" 2>/dev/null | head -1 | cut -d'=' -f2-)
    [[ -z "$app_name" ]] && app_name="$template_id"

    # Execute plan
    local results=""
    while IFS='|' read -r priority svc db init; do
        [[ -z "$svc" ]] && continue

        # Deploy service
        log_info "Deploying $svc..."
        if ! uis deploy "$svc" >&2; then
            log_error "Deploy failed for $svc"
            return 1
        fi

        # Configure if config is present
        if [[ -n "$db" || -n "$init" ]]; then
            # Substitute params in db and init file path
            local resolved_db resolved_init
            resolved_db=$(_substitute_params "$db" "$params_file")
            resolved_init=$(_substitute_params "$init" "$params_file")

            local configure_args=("$svc" "--app" "$app_name" "--json")
            [[ -n "$resolved_db" ]] && configure_args+=(--database "$resolved_db")

            log_info "Configuring $svc (args: ${configure_args[*]})..."
            local result configure_exit
            if [[ -n "$resolved_init" ]]; then
                # Substitute params in init file content, pipe via stdin
                local init_path="$template_dir/$resolved_init"
                if [[ ! -f "$init_path" ]]; then
                    log_error "Init file not found: $init_path"
                    return 1
                fi
                local init_content
                init_content=$(cat "$init_path")
                init_content=$(_substitute_params "$init_content" "$params_file")
                configure_args+=(--init-file -)
                log_info "Configuring $svc with init file: $resolved_init ($(wc -l <<< "$init_content") lines)"
                result=$(echo "$init_content" | uis configure "${configure_args[@]}")
                configure_exit=$?
            else
                result=$(uis configure "${configure_args[@]}")
                configure_exit=$?
            fi

            # Show the raw result for debugging
            if [[ -z "$result" ]]; then
                log_error "Configure returned empty output (exit code: $configure_exit)"
                return 1
            fi

            # Check result status
            local status
            status=$(echo "$result" | jq -r '.status' 2>/dev/null)
            case "$status" in
                ok|already_configured)
                    results+="$svc: $status"$'\n'
                    if [[ "$status" == "ok" ]]; then
                        echo "$result" | jq '.' >&2
                    else
                        log_info "$svc: already configured"
                    fi
                    ;;
                *)
                    log_error "Configure failed for $svc (exit: $configure_exit)"
                    echo "Raw output: $result" >&2
                    return 1
                    ;;
            esac
        else
            results+="$svc: deployed"$'\n'
        fi
    done <<< "$plan"

    print_section "Template Installation Complete"
    echo "$results"

    # Print README if available
    local readme_file
    readme_file=$(_yaml_field "$info_file" ".readme")
    if [[ -n "$readme_file" && -f "$template_dir/$readme_file" ]]; then
        echo ""
        echo "For usage details, see: $template_dir/$readme_file"
    fi
}

# Main template command dispatcher
run_template() {
    local subcmd="${1:-}"
    shift || true

    case "$subcmd" in
        list)
            cmd_template_list
            ;;
        info)
            cmd_template_info "$@"
            ;;
        install)
            cmd_template_install "$@"
            ;;
        ""|help|--help|-h)
            echo "Usage: uis template <command> [args]"
            echo ""
            echo "Commands:"
            echo "  list              List available UIS templates"
            echo "  info <id>         Show template details"
            echo "  install <id>      Install a template (deploy + configure services)"
            echo ""
            echo "Examples:"
            echo "  uis template list"
            echo "  uis template info postgresql-demo"
            echo "  uis template install postgresql-demo"
            return 0
            ;;
        *)
            log_error "Unknown template command: $subcmd"
            echo "Run 'uis template' for usage" >&2
            return 1
            ;;
    esac
}
