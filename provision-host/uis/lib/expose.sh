#!/bin/bash
# expose.sh — Manage port-forward exposure of K8s services to the host machine
#
# DCT containers reach exposed services via host.docker.internal:<exposePort>.
# UIS runs with --network host, so port-forwards bind directly to the host.
#
# See: helpers-no/dev-templates INVESTIGATE-unified-template-system.md (6UIS)
# See: PLAN-001-uis-configure-expose.md Phase 2

# PID tracking directory
EXPOSE_PID_DIR="/tmp/uis-expose"

# Service port-forward configuration
# Maps service_id → "k8s_svc_name namespace internal_port"
# The exposePort (external) is read from services.json
declare -A EXPOSE_CONFIG
EXPOSE_CONFIG=(
    ["postgresql"]="postgresql default 5432"
    ["mysql"]="mysql default 3306"
    ["mongodb"]="mongodb default 27017"
    ["redis"]="redis-master default 6379"
    ["elasticsearch"]="elasticsearch-master default 9200"
    ["qdrant"]="qdrant default 6333"
    ["authentik"]="authentik-server authentik 9000"
)

# Base path — inside container it's /mnt/urbalurbadisk, outside it's the repo root
UIS_BASE="${UIS_BASE:-/mnt/urbalurbadisk}"
SERVICES_JSON="${UIS_BASE}/website/src/data/services.json"

# Get exposePort from services.json for a given service ID
_get_expose_port() {
    local service_id="$1"

    if [[ ! -f "$SERVICES_JSON" ]]; then
        log_error "services.json not found at $SERVICES_JSON"
        return 1
    fi

    jq -r --arg id "$service_id" '.services[] | select(.id == $id) | .exposePort // empty' "$SERVICES_JSON"
}

# Check if a service is currently exposed (port-forward running)
_is_exposed() {
    local service_id="$1"
    local pid_file="$EXPOSE_PID_DIR/$service_id.pid"

    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        else
            # Process died — clean up stale PID file
            rm -f "$pid_file"
            return 1
        fi
    fi
    return 1
}

# Check if a service is deployed and running
_is_service_running() {
    local service_id="$1"
    local config="${EXPOSE_CONFIG[$service_id]:-}"

    if [[ -z "$config" ]]; then
        return 1
    fi

    local namespace
    namespace=$(echo "$config" | awk '{print $2}')
    local svc_name
    svc_name=$(echo "$config" | awk '{print $1}')

    kubectl get svc "$svc_name" -n "$namespace" --no-headers 2>/dev/null | grep -q .
}

# Check if a port is already in use
_is_port_in_use() {
    local port="$1"
    # Check if anything is listening on the port
    if command -v ss &>/dev/null; then
        ss -tlnp 2>/dev/null | grep -q ":${port} "
    elif command -v netstat &>/dev/null; then
        netstat -tlnp 2>/dev/null | grep -q ":${port} "
    else
        # Fallback: try to connect
        (echo >/dev/tcp/localhost/"$port") 2>/dev/null
    fi
}

# Start port-forward for a service
expose_service() {
    local service_id="$1"
    local config="${EXPOSE_CONFIG[$service_id]:-}"

    if [[ -z "$config" ]]; then
        log_error "Service '$service_id' does not support expose."
        echo "Exposable services: ${!EXPOSE_CONFIG[*]}" >&2
        return 1
    fi

    # Check if already exposed
    if _is_exposed "$service_id"; then
        local pid
        pid=$(cat "$EXPOSE_PID_DIR/$service_id.pid")
        local expose_port
        expose_port=$(_get_expose_port "$service_id")
        log_info "$service_id is already exposed on port $expose_port (PID $pid)"
        return 0
    fi

    # Check if service is deployed
    if ! _is_service_running "$service_id"; then
        log_error "Service '$service_id' is not deployed."
        echo "Deploy it first: uis deploy $service_id" >&2
        return 1
    fi

    local svc_name namespace internal_port
    svc_name=$(echo "$config" | awk '{print $1}')
    namespace=$(echo "$config" | awk '{print $2}')
    internal_port=$(echo "$config" | awk '{print $3}')

    local expose_port
    expose_port=$(_get_expose_port "$service_id")
    if [[ -z "$expose_port" ]]; then
        log_error "No exposePort defined for '$service_id' in services.json"
        return 1
    fi

    # Check if port is already in use
    if _is_port_in_use "$expose_port"; then
        log_error "Port $expose_port is already in use."
        echo "Check what's using it: ss -tlnp | grep :$expose_port" >&2
        return 1
    fi

    # Create PID directory
    mkdir -p "$EXPOSE_PID_DIR"

    # Start port-forward in background
    log_info "Exposing $service_id: svc/$svc_name ($namespace) → 0.0.0.0:$expose_port"
    kubectl port-forward "svc/$svc_name" \
        --address 0.0.0.0 \
        -n "$namespace" \
        "${expose_port}:${internal_port}" \
        >/dev/null 2>&1 &

    local pid=$!

    # Brief wait to check if port-forward started successfully
    sleep 1
    if ! kill -0 "$pid" 2>/dev/null; then
        log_error "Port-forward failed to start for $service_id"
        echo "Check if the service is running: kubectl get svc $svc_name -n $namespace" >&2
        return 1
    fi

    # Store PID
    echo "$pid" > "$EXPOSE_PID_DIR/$service_id.pid"

    log_info "$service_id exposed on port $expose_port (PID $pid)"
    echo "Connect via: host.docker.internal:$expose_port (from DCT devcontainer)" >&2
    echo "Connect via: localhost:$expose_port (from host machine)" >&2
}

# Stop port-forward for a service
unexpose_service() {
    local service_id="$1"

    if ! _is_exposed "$service_id"; then
        log_warn "$service_id is not currently exposed"
        return 0
    fi

    local pid
    pid=$(cat "$EXPOSE_PID_DIR/$service_id.pid")

    kill "$pid" 2>/dev/null
    rm -f "$EXPOSE_PID_DIR/$service_id.pid"

    log_info "$service_id unexposed (stopped PID $pid)"
}

# Show status of all exposed services
expose_status() {
    mkdir -p "$EXPOSE_PID_DIR"

    local found=0
    local service_id

    echo "Exposed services:"
    echo ""

    for service_id in "${!EXPOSE_CONFIG[@]}"; do
        local pid_file="$EXPOSE_PID_DIR/$service_id.pid"
        if [[ -f "$pid_file" ]]; then
            local pid
            pid=$(cat "$pid_file")
            if kill -0 "$pid" 2>/dev/null; then
                local expose_port
                expose_port=$(_get_expose_port "$service_id")
                echo "  $service_id → port $expose_port (PID $pid, running)"
                found=1
            else
                rm -f "$pid_file"
                echo "  $service_id → port-forward died (cleaned up)"
                found=1
            fi
        fi
    done | sort

    if [[ "$found" -eq 0 ]]; then
        echo "  (none)"
    fi

    echo ""
}
