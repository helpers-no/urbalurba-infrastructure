#!/bin/bash
# shell.sh — Interactive shells into deployed services
#
# Opens a service-native client against a running service by kubectl-execing
# into the pod. Uses the client tools that already ship with each service's
# container image, avoiding the need to install clients in uis-provision-host.
#
# See: INVESTIGATE-uis-shell-commands.md for the broader design
# See: PLAN-002-uis-template-command.md

UIS_BASE="${UIS_BASE:-/mnt/urbalurbadisk}"
SERVICES_JSON="${UIS_BASE}/website/src/data/services.json"
KUBECONF="${KUBECONF:-/mnt/urbalurbadisk/.uis.secrets/generated/kubeconfig/kubeconf-all}"

# Service → pod selector + shell command + admin env-var lookup
# Format: "label_selector|namespace|client_cmd|secret_key_for_password"
declare -A SHELL_CONFIG
SHELL_CONFIG=(
    ["postgresql"]="app.kubernetes.io/name=postgresql|default|psql -U postgres|PGPASSWORD"
    ["mysql"]="app.kubernetes.io/name=mysql|default|mysql -u root -p\$MYSQL_ROOT_PASSWORD|MYSQL_ROOT_PASSWORD"
    ["redis"]="app.kubernetes.io/name=redis|default|redis-cli -a \$REDIS_PASSWORD|REDIS_PASSWORD"
    ["mongodb"]="app=mongodb|default|mongosh -u root -p \$MONGODB_ROOT_PASSWORD|MONGODB_ROOT_PASSWORD"
)

# Get the secret value for a key from urbalurba-secrets
_get_secret() {
    local key="$1"
    local namespace="${2:-default}"
    kubectl get secret urbalurba-secrets \
        -n "$namespace" \
        --kubeconfig="$KUBECONF" \
        -o jsonpath="{.data.$key}" 2>/dev/null | base64 -d
}

# Find a pod matching a label selector in a namespace
_find_pod() {
    local selector="$1"
    local namespace="$2"
    kubectl get pods -n "$namespace" \
        --kubeconfig="$KUBECONF" \
        -l "$selector" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# Main shell command: uis connect <service> [args...]
cmd_connect() {
    local service="${1:-}"
    shift || true

    if [[ -z "$service" ]]; then
        echo "Usage: uis connect <service> [args...]"
        echo ""
        echo "Opens an interactive client shell into the service pod."
        echo ""
        echo "Available services:"
        for svc in "${!SHELL_CONFIG[@]}"; do
            echo "  $svc"
        done | sort
        echo ""
        echo "Examples:"
        echo "  uis connect postgresql              # psql as admin"
        echo "  uis connect postgresql demo_db      # psql into a specific database"
        echo "  uis connect redis                   # redis-cli"
        return 0
    fi

    local config="${SHELL_CONFIG[$service]:-}"
    if [[ -z "$config" ]]; then
        log_error "Service '$service' does not support uis connect"
        echo "Supported: ${!SHELL_CONFIG[*]}" >&2
        return 1
    fi

    local selector namespace client_cmd secret_key
    selector=$(echo "$config" | cut -d'|' -f1)
    namespace=$(echo "$config" | cut -d'|' -f2)
    client_cmd=$(echo "$config" | cut -d'|' -f3)
    secret_key=$(echo "$config" | cut -d'|' -f4)

    # Find the pod
    local pod
    pod=$(_find_pod "$selector" "$namespace")
    if [[ -z "$pod" ]]; then
        log_error "No pod found for $service (selector: $selector, namespace: $namespace)"
        echo "Is $service deployed? Run: uis deploy $service" >&2
        return 1
    fi

    # Get admin password
    local admin_pass
    admin_pass=$(_get_secret "$secret_key" "$namespace")
    if [[ -z "$admin_pass" ]]; then
        log_error "Could not read $secret_key from urbalurba-secrets"
        return 1
    fi

    # Detect TTY for kubectl exec flags
    local kflags="-i"
    [[ -t 0 ]] && kflags="-it"

    # Service-specific argument handling
    case "$service" in
        postgresql)
            # Extra args treated as database name or psql flags
            if [[ $# -gt 0 ]]; then
                # First arg is database name if it doesn't start with -
                if [[ "$1" != -* ]]; then
                    local db="$1"
                    shift
                    exec kubectl exec "$kflags" "$pod" -n "$namespace" --kubeconfig="$KUBECONF" \
                        -- env "PGPASSWORD=$admin_pass" psql -U postgres -d "$db" "$@"
                fi
                exec kubectl exec "$kflags" "$pod" -n "$namespace" --kubeconfig="$KUBECONF" \
                    -- env "PGPASSWORD=$admin_pass" psql -U postgres "$@"
            fi
            exec kubectl exec "$kflags" "$pod" -n "$namespace" --kubeconfig="$KUBECONF" \
                -- env "PGPASSWORD=$admin_pass" psql -U postgres
            ;;
        mysql)
            exec kubectl exec "$kflags" "$pod" -n "$namespace" --kubeconfig="$KUBECONF" \
                -- env "MYSQL_PWD=$admin_pass" mysql -u root "$@"
            ;;
        redis)
            exec kubectl exec "$kflags" "$pod" -n "$namespace" --kubeconfig="$KUBECONF" \
                -- redis-cli -a "$admin_pass" "$@"
            ;;
        mongodb)
            exec kubectl exec "$kflags" "$pod" -n "$namespace" --kubeconfig="$KUBECONF" \
                -- mongosh -u root -p "$admin_pass" "$@"
            ;;
    esac
}
