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
# Overridable so unit tests can point at a fixture. UIS_BASE above already
# respects an existing value; these two did not, which made every assertion
# about service metadata depend on the live generated file — so a metadata
# change elsewhere could turn a passing test red for reasons unrelated to it.
SERVICES_JSON="${SERVICES_JSON:-${UIS_BASE}/website/src/data/services.json}"
STACKS_JSON="${STACKS_JSON:-${UIS_BASE}/website/src/data/stacks.json}"

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

# The `config:` keys a provides entry may set. Anything else is a typo and is
# rejected: a silently-ignored `url-prefix` is the failure mode this whole
# investigation exists to document.
TEMPLATE_CONFIG_KEYS="database init schemas url_prefix namespace secret_name_prefix"

# Write one service's config to $plan_dir/<service_id>.conf as key=value lines.
#
# ⚠️ The plan line carries only <priority>|<service_id>; configuration lives in
# these files. Four fields fitted on a pipe-delimited line, nine do not — and
# `IFS='|' read -r` mis-binds silently the first time a value contains a pipe.
# Files also keep this bash 3.x-safe (macOS default: no associative arrays) and
# leave something greppable behind when an install goes wrong.
_write_service_conf() {
    local plan_dir="$1" info_file="$2" idx="$3" svc="$4"
    local conf="$plan_dir/${svc}.conf"
    : > "$conf"

    # Reject unknown config keys before reading any of them.
    local keys k
    keys=$(yq -r ".provides.services[$idx].config // {} | keys | .[]" "$info_file" 2>/dev/null)
    while IFS= read -r k; do
        [[ -z "$k" ]] && continue
        case " $TEMPLATE_CONFIG_KEYS " in
            *" $k "*) ;;
            *)  log_error "Unknown config key '$k' for service '$svc'."
                echo "Supported keys: $TEMPLATE_CONFIG_KEYS" >&2
                return 1 ;;
        esac
    done <<< "$keys"

    local v
    for k in $TEMPLATE_CONFIG_KEYS; do
        v=$(yq -r ".provides.services[$idx].config.$k // \"\"" "$info_file" 2>/dev/null)
        [[ -n "$v" ]] && printf '%s=%s\n' "$k" "$v" >> "$conf"
    done

    # `configure.sh` requires --namespace and --secret-name-prefix together.
    # Catch it here, where we can say which one is missing, rather than letting
    # configure reject it later with less context.
    local ns sp
    ns=$(_conf_get "$conf" namespace); sp=$(_conf_get "$conf" secret_name_prefix)
    if [[ -n "$ns" && -z "$sp" ]]; then
        log_error "Service '$svc': config.namespace requires config.secret_name_prefix."
        return 1
    fi
    if [[ -n "$sp" && -z "$ns" ]]; then
        log_error "Service '$svc': config.secret_name_prefix requires config.namespace."
        return 1
    fi
    return 0
}

# Read one key from a conf file. Empty output when absent.
_conf_get() {
    local conf="$1" key="$2"
    [[ -f "$conf" ]] || return 0
    sed -n "s/^${key}=//p" "$conf" | head -1
}

# Resolve `provides` into an ordered deployment plan.
#
# Outputs one entry per line: <priority>|<service_id>
# Per-service configuration is written to $plan_dir/<service_id>.conf.
_resolve_provides() {
    local info_file="$1"
    local template_dir="$2"
    local plan_dir="$3"

    mkdir -p "$plan_dir" || return 1

    # Collect services from provides.stacks (expand via stacks.json). These are
    # deploy-only: a stack names services, not per-app configuration.
    local stack_services=""
    local stacks
    stacks=$(yq -r '.provides.stacks[]? // empty' "$info_file" 2>/dev/null)
    while IFS= read -r stack_id; do
        [[ -z "$stack_id" ]] && continue
        local svcs
        svcs=$(jq -r --arg id "$stack_id" '.itemListElement[] | select(.identifier == $id) | .components[].service' "$STACKS_JSON" 2>/dev/null)
        stack_services+="$svcs"$'\n'
    done <<< "$stacks"

    # provides.services — plain strings (deploy only) and objects (with config).
    local direct_services=""
    local service_count
    service_count=$(yq -r '.provides.services // [] | length' "$info_file" 2>/dev/null)
    local i
    for ((i=0; i<service_count; i++)); do
        local entry_type svc
        entry_type=$(yq -r ".provides.services[$i] | type" "$info_file" 2>/dev/null)
        if [[ "$entry_type" == "!!str" ]]; then
            svc=$(yq -r ".provides.services[$i]" "$info_file" 2>/dev/null)
            : > "$plan_dir/${svc}.conf"
        else
            svc=$(yq -r ".provides.services[$i].service" "$info_file" 2>/dev/null)
            if [[ -z "$svc" || "$svc" == "null" ]]; then
                log_error "provides.services[$i] has no 'service' field"
                return 1
            fi
            _write_service_conf "$plan_dir" "$info_file" "$i" "$svc" || return 1
        fi
        direct_services+="${svc}"$'\n'
    done

    # Stack services first, direct services after, so direct entries win.
    local all_services=""
    while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        [[ -f "$plan_dir/${svc}.conf" ]] || : > "$plan_dir/${svc}.conf"
        all_services+="${svc}"$'\n'
    done <<< "$stack_services"
    all_services+="$direct_services"

    # Deduplicate by service id, keeping the LAST occurrence (direct wins),
    # by walking the list in reverse and keeping the first one seen.
    local dedup="" seen="" reversed
    reversed=$(echo "$all_services" | tac)
    while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        if [[ ",$seen," != *",$svc,"* ]]; then
            seen="$seen,$svc"
            local priority
            priority=$(jq -r --arg id "$svc" '.services[] | select(.id == $id) | .priority // 999' "$SERVICES_JSON" 2>/dev/null)
            dedup+="${priority}|${svc}"$'\n'
        fi
    done <<< "$reversed"

    echo "$dedup" | grep -v '^$' | sort -t'|' -k1,1n
}

# Is this service multi-instance? Drives whether `uis deploy` gets --app.
# Read from services.json rather than a hardcoded list, so a future
# multi-instance service needs no edit here.
_service_is_multi_instance() {
    local svc="$1"
    [[ "$(jq -r --arg id "$svc" '.services[] | select(.id == $id) | .multiInstance // false' "$SERVICES_JSON" 2>/dev/null)" == "true" ]]
}

# Resolve an `init:` value to SQL on stdout. Accepts a single file or a
# directory of *.sql applied in LC_ALL=C sort order.
#
# ⚠️ Order is part of the contract, not a convenience. Tenants number their
# migrations (001_, 050_) precisely because DDL is order-dependent, and a
# partial apply is what configure-postgresql's rollback exists to undo — so the
# ordered list is printed before anything is applied and stays in the log.
_collect_init_sql() {
    local path="$1"
    if [[ -f "$path" ]]; then
        echo "Init file: $(basename "$path")" >&2
        cat "$path"
        return 0
    fi
    if [[ -d "$path" ]]; then
        local files
        files=$(LC_ALL=C find "$path" -maxdepth 1 -type f -name '*.sql' | LC_ALL=C sort)
        if [[ -z "$files" ]]; then
            log_error "Init directory '$path' contains no .sql files."
            return 1
        fi
        local n
        n=$(printf '%s\n' "$files" | grep -c .)
        echo "Init directory: $n .sql file(s), applied in this order:" >&2
        printf '%s\n' "$files" | while IFS= read -r f; do echo "    $(basename "$f")" >&2; done
        printf '%s\n' "$files" | while IFS= read -r f; do
            printf -- '-- >>> %s\n' "$(basename "$f")"
            cat "$f"
            printf '\n'
        done
        return 0
    fi
    log_error "Init path '$path' is neither a file nor a directory."
    return 1
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

    # Resolve provides into a deployment plan. Per-service configuration lands
    # in $plan_dir/<service_id>.conf; the plan itself is <priority>|<service_id>.
    local plan_dir="$template_dir/.plan"
    local plan
    plan=$(_resolve_provides "$info_file" "$template_dir" "$plan_dir") || return 1

    if [[ -z "$plan" ]]; then
        log_error "Deployment plan is empty — no services in provides"
        return 1
    fi

    print_section "Installing Template: $template_id"
    echo "Template folder: $folder"
    echo ""
    echo "Deployment plan (in priority order):"
    echo "$plan" | while IFS='|' read -r priority svc; do
        local action="deploy"
        [[ -s "$plan_dir/${svc}.conf" ]] && action="deploy + configure"
        _service_is_multi_instance "$svc" && action="$action (per-app instance)"
        echo "  [$priority] $svc — $action"
    done
    echo ""

    # Get app name param from effective params file
    local app_name
    app_name=$(grep '^app_name=' "$params_file" 2>/dev/null | head -1 | cut -d'=' -f2-)
    [[ -z "$app_name" ]] && app_name="$template_id"

    # Execute plan
    local results=""
    while IFS='|' read -r priority svc; do
        [[ -z "$svc" ]] && continue
        local conf="$plan_dir/${svc}.conf"

        # Deploy service.
        #
        # ⚠️ --app is required for a multi-instance service and wrong for a
        # single-instance one. This used to deploy without it unconditionally
        # while the configure call below always passed it, so the two halves of
        # one loop disagreed and no multi-instance service could be installed
        # from a template at all (TPL-F3). Driven by services.json rather than a
        # list, so a future multi-instance service needs no edit here.
        local deploy_args=("$svc")
        if _service_is_multi_instance "$svc"; then
            deploy_args+=(--app "$app_name")
        fi
        log_info "Deploying ${deploy_args[*]}..."
        if ! uis deploy "${deploy_args[@]}" >&2; then
            log_error "Deploy failed for $svc"
            return 1
        fi

        # Configure if this service has any config at all.
        if [[ -s "$conf" ]]; then
            local resolved_db resolved_init resolved_schemas resolved_prefix
            local resolved_ns resolved_secret_prefix
            resolved_db=$(_substitute_params "$(_conf_get "$conf" database)" "$params_file")
            resolved_init=$(_substitute_params "$(_conf_get "$conf" init)" "$params_file")
            resolved_schemas=$(_substitute_params "$(_conf_get "$conf" schemas)" "$params_file")
            resolved_prefix=$(_substitute_params "$(_conf_get "$conf" url_prefix)" "$params_file")
            resolved_ns=$(_substitute_params "$(_conf_get "$conf" namespace)" "$params_file")
            resolved_secret_prefix=$(_substitute_params "$(_conf_get "$conf" secret_name_prefix)" "$params_file")

            # --app is unconditional here and that is deliberate: a
            # single-instance service can still hold per-app resources, which is
            # exactly what `configure postgresql --app` creates.
            local configure_args=("$svc" "--app" "$app_name" "--json")
            [[ -n "$resolved_db" ]] && configure_args+=(--database "$resolved_db")
            [[ -n "$resolved_schemas" ]] && configure_args+=(--schemas "$resolved_schemas")
            [[ -n "$resolved_prefix" ]] && configure_args+=(--url-prefix "$resolved_prefix")
            [[ -n "$resolved_ns" ]] && configure_args+=(--namespace "$resolved_ns")
            [[ -n "$resolved_secret_prefix" ]] && configure_args+=(--secret-name-prefix "$resolved_secret_prefix")

            log_info "Configuring $svc (args: ${configure_args[*]})..."
            local result configure_exit
            if [[ -n "$resolved_init" ]]; then
                # A file or a directory of ordered *.sql — see _collect_init_sql.
                local init_path="$template_dir/$resolved_init"
                local init_content
                init_content=$(_collect_init_sql "$init_path") || return 1
                init_content=$(_substitute_params "$init_content" "$params_file")
                configure_args+=(--init-file -)
                log_info "Configuring $svc with init from '$resolved_init' ($(wc -l <<< "$init_content") lines)"
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
