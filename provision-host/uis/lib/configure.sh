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
run_configure() {
    local service_id=""
    local app_name=""
    local database_name=""
    local init_file=""
    local json_output=false
    local namespace=""
    local secret_name_prefix=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
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
            _configure_error "deploy_check" "$service_id" "Service '$service_id' is not configurable. Only data services and identity services support uis configure."
        fi
        log_error "Service '$service_id' is not configurable."
        echo "Configurable services: postgresql, mysql, mongodb, redis, elasticsearch, qdrant, authentik" >&2
        return 1
    fi

    # Check if service is deployed
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

    # Source and run handler
    source "$handler"
    configure_service "$service_id" "$app_name" "$database_name" "$init_file" "$json_output" "$namespace" "$secret_name_prefix"
}
