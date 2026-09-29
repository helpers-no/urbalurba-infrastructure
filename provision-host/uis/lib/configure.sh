#!/bin/bash
# configure.sh — Main entry point for uis configure command
#
# Creates app-specific resources (database, user) in a running service
# and returns connection details as JSON on stdout.
#
# See: helpers-no/dev-templates INVESTIGATE-unified-template-system.md (7UIS)
# See: PLAN-001-uis-configure-expose.md Phase 3

UIS_BASE="${UIS_BASE:-/mnt/urbalurbadisk}"
SERVICES_JSON="${UIS_BASE}/website/src/data/services.json"
CONFIGURE_HANDLERS_DIR="${UIS_BASE}/provision-host/uis/lib"
KUBECONF="${UIS_BASE}/.uis.secrets/generated/kubeconfig/kubeconf-all"

# Output structured JSON error on stdout, progress on stderr
_configure_error() {
    local phase="$1"
    local service="$2"
    local detail="$3"

    cat <<EOF
{"status":"error","phase":"$phase","service":"$service","detail":"$detail"}
EOF
    exit 1
}

# Check if a service is marked configurable in services.json
_is_configurable() {
    local service_id="$1"

    if [[ ! -f "$SERVICES_JSON" ]]; then
        return 1
    fi

    local val
    val=$(jq -r --arg id "$service_id" '.services[] | select(.id == $id) | .configurable // false' "$SERVICES_JSON")
    [[ "$val" == "true" ]]
}

# Get space-separated list of services that the target service requires (from services.json .requires)
_get_requires() {
    local service_id="$1"

    if [[ ! -f "$SERVICES_JSON" ]]; then
        return 1
    fi

    jq -r --arg id "$service_id" '.services[] | select(.id == $id) | .requires // [] | .[]' "$SERVICES_JSON" 2>/dev/null
}

# Get namespace for a service from services.json
_get_service_namespace() {
    local service_id="$1"
    jq -r --arg id "$service_id" '.services[] | select(.id == $id) | .namespace // "default"' "$SERVICES_JSON"
}

# Check if service pods are running
_is_service_deployed() {
    local service_id="$1"

    if [[ ! -f "$SERVICES_JSON" ]]; then
        return 1
    fi

    local check_cmd
    check_cmd=$(jq -r --arg id "$service_id" '.services[] | select(.id == $id) | .checkCommand // empty' "$SERVICES_JSON")

    if [[ -z "$check_cmd" ]]; then
        return 1
    fi

    eval "$check_cmd" 2>/dev/null
}

# Main configure command — parse args and dispatch to handler
# ⚠️ `uis configure postgresql --help` used to fail with "Unknown option:
# --help", and `uis help configure` listed none of these flags — so the only
# way to learn them was to be handed the command. imac could run #1676 solely
# because the task spelled it out (urb-agents#1700 item 3).
_configure_usage() {
    cat <<'EOF'
Usage: uis configure <service> [options]

Creates the per-application resources a service needs — for postgresql: a
database, a role, and optionally a Secret holding the connection URL.

Options:
  --app <name>                 Application this is for (required)
  --database <name>            Database name (default: derived from --app)
  --init-file <path>           SQL applied after creation, as the APP role
                               (so it cannot CREATE EXTENSION)
  --namespace <ns>             Write the credential into a Secret in <ns>.
                               Implies the consumer is in-cluster, so the
                               database is NOT exposed on the host.
  --secret-name-prefix <p>     Secret name prefix; requires --namespace
  --schemas <list>             postgrest only: schemas to expose
  --url-prefix <p>             postgrest only: first label of the hostname
  --rotate                     Mint a new password instead of reusing the
                               one already in the Secret
  --purge                      Remove the application's database and role
  --json                       Machine-readable output on stdout
  --help, -h                   This text

Examples:
  uis configure postgresql --app myapp
  uis configure postgresql --app myapp --namespace myapp --secret-name-prefix myapp
EOF
}

run_configure() {
    local service_id=""
    local app_name=""
    local database_name=""
    local init_file=""
    local json_output=false
    local namespace=""
    local secret_name_prefix=""
    local schemas=""
    local url_prefix=""
    local rotate=false
    local purge=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h) _configure_usage; return 0 ;;
        esac
        case "$1" in
            --app)
                app_name="$2"
                shift 2
                ;;
            --database)
                database_name="$2"
                shift 2
                ;;
            --init-file)
                init_file="$2"
                shift 2
                ;;
            --namespace)
                namespace="$2"
                shift 2
                ;;
            --secret-name-prefix)
                secret_name_prefix="$2"
                shift 2
                ;;
            --schemas)
                schemas="$2"
                shift 2
                ;;
            --url-prefix)
                url_prefix="$2"
                shift 2
                ;;
            --rotate)
                rotate=true
                shift
                ;;
            --purge)
                purge=true
                shift
                ;;
            --json)
                json_output=true
                shift
                ;;
            -*)
                echo "Unknown option: $1" >&2
                return 1
                ;;
            *)
                if [[ -z "$service_id" ]]; then
                    service_id="$1"
                else
                    echo "Unexpected argument: $1" >&2
                    return 1
                fi
                shift
                ;;
        esac
    done

    # Validate required args
    if [[ -z "$service_id" ]]; then
        log_error "Usage: uis configure <service> --app <name> [--database <name>] [--init-file -] --json"
        echo "" >&2
        echo "Creates app-specific resources in a running service and returns connection JSON." >&2
        echo "" >&2
        echo "Examples:" >&2
        echo "  uis configure postgresql --app volunteer-app --database volunteer_db --json" >&2
        echo "  uis configure redis --app volunteer-app --json" >&2
        return 1
    fi

    if [[ -z "$app_name" ]]; then
        if [[ "$json_output" == true ]]; then
            _configure_error "usage" "$service_id" "Missing required --app argument"
        fi
        log_error "Missing required --app argument"
        return 1
    fi

    # Validate --namespace and --secret-name-prefix go together (or neither)
    if [[ -n "$namespace" && -z "$secret_name_prefix" ]]; then
        if [[ "$json_output" == true ]]; then
            _configure_error "usage" "$service_id" "--namespace requires --secret-name-prefix to be set"
        fi
        log_error "--namespace requires --secret-name-prefix to be set"
        return 1
    fi
    if [[ -n "$secret_name_prefix" && -z "$namespace" ]]; then
        if [[ "$json_output" == true ]]; then
            _configure_error "usage" "$service_id" "--secret-name-prefix requires --namespace to be set"
        fi
        log_error "--secret-name-prefix requires --namespace to be set"
        return 1
    fi

    # Check if service is configurable
    if ! _is_configurable "$service_id"; then
        if [[ "$json_output" == true ]]; then
            _configure_error "deploy_check" "$service_id" "Service '$service_id' is not configurable (no SCRIPT_CONFIGURABLE=true in service metadata)."
        fi
        log_error "Service '$service_id' is not configurable."
        local -a configurable_services
        # shellcheck disable=SC2207
        configurable_services=($(jq -r '.services[] | select(.configurable == true) | .id' "$SERVICES_JSON" 2>/dev/null | sort))
        if [[ ${#configurable_services[@]} -gt 0 ]]; then
            echo "Configurable services: ${configurable_services[*]}" >&2
        fi
        return 1
    fi

    # Precheck: for multi-instance services, check the data-plane dependencies are deployed
    # (the service itself has no instances until configure runs); for single-instance services,
    # check the service itself is deployed. See INVESTIGATE-postgrest.md Decision #23.
    if _is_service_multi_instance "$service_id"; then
        local dep
        while IFS= read -r dep; do
            [[ -z "$dep" ]] && continue
            echo "Checking if dependency '$dep' is deployed..." >&2
            if ! _is_service_deployed "$dep"; then
                if [[ "$json_output" == true ]]; then
                    _configure_error "deploy_check" "$service_id" "Cannot configure $service_id: dependency '$dep' is not deployed. Deploy it first: uis deploy $dep"
                fi
                log_error "Cannot configure $service_id: dependency '$dep' is not deployed."
                echo "Deploy it first: uis deploy $dep" >&2
                return 1
            fi
            echo "Dependency '$dep' is running." >&2
        done < <(_get_requires "$service_id")
    else
        echo "Checking if $service_id is deployed..." >&2
        if ! _is_service_deployed "$service_id"; then
            if [[ "$json_output" == true ]]; then
                _configure_error "deploy_check" "$service_id" "Service '$service_id' is not deployed. Deploy it first: uis deploy $service_id"
            fi
            log_error "Service '$service_id' is not deployed."
            echo "Deploy it first: uis deploy $service_id" >&2
            return 1
        fi
        echo "$service_id is running." >&2
    fi

    # Dispatch to per-service handler
    local handler="$CONFIGURE_HANDLERS_DIR/configure-${service_id}.sh"
    if [[ ! -f "$handler" ]]; then
        if [[ "$json_output" == true ]]; then
            _configure_error "create_resources" "$service_id" "No configure handler for '$service_id'. Handler not yet implemented."
        fi
        log_error "No configure handler for '$service_id'."
        echo "Handler not yet implemented. See PLAN-001-uis-configure-expose.md Phase 4." >&2
        return 1
    fi

    # Source and run handler. Multi-instance handlers receive the extended argument set
    # (schemas, url_prefix, rotate, purge); single-instance handlers ignore the trailing args
    # via positional parameter rules.
    source "$handler"
    configure_service "$service_id" "$app_name" "$database_name" "$init_file" "$json_output" "$namespace" "$secret_name_prefix" "$schemas" "$url_prefix" "$rotate" "$purge"
}
