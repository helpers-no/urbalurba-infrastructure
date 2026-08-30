#!/bin/bash
# service-deployment.sh - Service deployment logic
#
# Provides functions for deploying, removing, and checking services
# based on enabled-services.conf configuration.

# Guard against multiple sourcing
[[ -n "${_UIS_SERVICE_DEPLOYMENT_LOADED:-}" ]] && return 0
_UIS_SERVICE_DEPLOYMENT_LOADED=1

# shellcheck disable=SC2034  # Variables are used by callers

# Determine script directory for sourcing siblings
_DEPLOY_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source dependencies
source "$_DEPLOY_SCRIPT_DIR/service-scanner.sh"
source "$_DEPLOY_SCRIPT_DIR/logging.sh"
source "$_DEPLOY_SCRIPT_DIR/utilities.sh"

# Default paths
CONFIG_DIR="${CONFIG_DIR:-/mnt/urbalurbadisk/.uis.extend}"
ANSIBLE_DIR="${ANSIBLE_DIR:-/mnt/urbalurbadisk/ansible/playbooks}"
MANIFESTS_DIR="${MANIFESTS_DIR:-/mnt/urbalurbadisk/manifests}"

# Read enabled services from config file
# Usage: read_enabled_services
# Output: One service ID per line (comments and blanks removed)
read_enabled_services() {
    local config_file="$CONFIG_DIR/enabled-services.conf"

    if [[ ! -f "$config_file" ]]; then
        die_config "enabled-services.conf not found at $config_file"
    fi

    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        # Trim whitespace and output
        echo "${line// /}"
    done < "$config_file"
}

# Deploy all services listed in enabled-services.conf
# Usage: deploy_enabled_services
deploy_enabled_services() {
    local services=()
    local service

    while IFS= read -r service; do
        services+=("$service")
    done < <(read_enabled_services)

    if [[ ${#services[@]} -eq 0 ]]; then
        log_warn "No services enabled in enabled-services.conf"
        return 0
    fi

    log_info "Deploying ${#services[@]} enabled service(s)..."

    local failed=0
    for service_id in "${services[@]}"; do
        if ! deploy_single_service "$service_id"; then
            ((++failed))
            log_error "Failed to deploy $service_id"
            return 1  # Stop on first failure per design
        fi
    done

    log_success "All enabled services deployed"
    return 0
}

# Deploy a single service by ID
# Check if a service is multi-instance per services.json (multiInstance: true)
_is_service_multi_instance() {
    local service_id="$1"
    local services_json="${SERVICES_JSON:-/mnt/urbalurbadisk/website/src/data/services.json}"
    [[ -f "$services_json" ]] || return 1
    local val
    val=$(jq -r --arg id "$service_id" '.services[] | select(.id == $id) | .multiInstance // false' "$services_json" 2>/dev/null)
    [[ "$val" == "true" ]]
}

# Usage: deploy_single_service <service_id> [<app_name> [<url_prefix>]]
# For multi-instance services (multiInstance: true in services.json), app_name is
# required and gets translated into Ansible extra-vars (_app_name, _url_prefix)
# per the convention in ansible/playbooks/templates/README.md. Schema lists for
# postgrest are read from the per-app secret, not from CLI flags.
deploy_single_service() {
    local service_id="$1"
    local app_name="${2:-}"
    local url_prefix="${3:-}"
    local script

    script=$(find_service_script "$service_id")

    if [[ -z "$script" ]]; then
        die_config "Service '$service_id' not found"
    fi

    # Load service metadata
    # Clear previous values
    unset SCRIPT_ID SCRIPT_NAME SCRIPT_DESCRIPTION SCRIPT_CATEGORY
    unset SCRIPT_PLAYBOOK SCRIPT_MANIFEST SCRIPT_CHECK_COMMAND
    unset SCRIPT_REMOVE SCRIPT_REQUIRES SCRIPT_PRIORITY

    # shellcheck source=/dev/null
    source "$script" 2>/dev/null

    if [[ -n "$app_name" ]]; then
        log_info "Deploying $SCRIPT_NAME ($service_id) — app: $app_name..."
    else
        log_info "Deploying $SCRIPT_NAME ($service_id)..."
    fi

    # Check dependencies first
    if [[ -n "$SCRIPT_REQUIRES" ]]; then
        if ! check_dependencies "$SCRIPT_REQUIRES"; then
            return $?
        fi
    fi

    # Determine deployment method
    if [[ -n "$SCRIPT_PLAYBOOK" ]]; then
        # Ansible deployment
        local playbook_path="$ANSIBLE_DIR/$SCRIPT_PLAYBOOK"
        if [[ ! -f "$playbook_path" ]]; then
            die_config "Playbook not found: $SCRIPT_PLAYBOOK"
        fi

        # Does this installation provide the service OUTSIDE the cluster?
        # Absent file / no entry => silence, and everything below runs unchanged.
        # A stock laptop install never reaches this branch.
        local _ext_playbook="" _ext_host="" _ext_port="" _ext_why="" _ext_tpl=""
        if is_external_service "$service_id"; then
            local _ext_fields
            # ⚠️ NO DEFAULT PORT FROM HERE. SCRIPT_EXPOSE_PORT is the host-side
            # forwarded port (35432 for postgres), not the in-cluster one, and
            # passing it made an omitted `port:` point socat at a dead port.
            # An omitted port comes back as `-` and the extra-var is omitted, so
            # the proxy template supplies the service's real default.
            if ! _ext_fields="$(external_service_get "$service_id")"; then
                die_config "external-services.yaml is invalid for '$service_id'"
            fi
            read -r _ext_host _ext_port _ext_why <<< "$_ext_fields"
            _ext_tpl="$(external_service_template "$service_id" "$SCRIPT_PLAYBOOK")"
            _ext_playbook="$ANSIBLE_DIR/900-external-service-proxy.yml"
            log_info "$service_id is provided externally by this installation"
            log_info "  -> $_ext_host:$_ext_port  ($_ext_why)"
            log_info "  deploying a transparent proxy; consumers are unaffected"
            playbook_path="$_ext_playbook"
        fi

        # Load cluster config for target_host
        #
        # NOTE: verify-target.sh::uis_target_host() does the identical thing for
        # the verify path. The duplication is deliberate for now: this path runs
        # in production, and consolidating it would be an untested change to a
        # working deploy. If you touch either, change both — the verify path
        # drifted out of step with this one and shipped a defect that reported
        # healthy services as broken on every non-Rancher-Desktop cluster.
        local cluster_config="$CONFIG_DIR/cluster-config.sh"
        local target_host="rancher-desktop"  # Default
        if [[ -f "$cluster_config" ]]; then
            # shellcheck source=/dev/null
            source "$cluster_config"
            target_host="${TARGET_HOST:-rancher-desktop}"
        fi

        # ⚠️ COMING BACK FROM EXTERNAL: the proxy must go, or both serve at once.
        #
        # Removing a service from external-services.yaml used to leave the socat
        # Deployment running. On a cluster where the Service selected it, the
        # restored workload and a relay to a host that may no longer be listening
        # both matched - traffic split between the real database and a dead
        # route. `uis deploy` owns what it created, including on the way back.
        #
        # Keyed on the marker label the proxy templates set, so this can only ever
        # remove a Deployment UIS created as a proxy. A proxy predating the marker
        # (deployed before 2026-08-30) is not matched and must be removed by hand.
        if [[ -z "$_ext_host" ]] && command -v kubectl >/dev/null 2>&1; then
            local _proxy_found
            # Selector only - kubectl refuses a name and a selector together.
            # Both labels, so this cannot match another service's proxy.
            _proxy_found="$(kubectl get deployment \
                -n "${SCRIPT_NAMESPACE:-default}" --context "$target_host" \
                -l "uis.io/external-proxy=true,app.kubernetes.io/name=$service_id" \
                -o name 2>/dev/null || true)"
            if [[ -n "$_proxy_found" ]]; then
                log_info "$service_id was provided externally and no longer is"
                log_info "  removing the proxy Deployment before deploying in-cluster"
                kubectl delete deployment \
                    -n "${SCRIPT_NAMESPACE:-default}" --context "$target_host" \
                    -l "uis.io/external-proxy=true,app.kubernetes.io/name=$service_id" \
                    --wait=true >/dev/null 2>&1 || \
                    log_warn "  could not remove the proxy Deployment; remove it by hand"

                # ⚠️ RESTORE THE SELECTOR, or the database comes back unreachable.
                #
                # Removing the proxy Deployment is only half the return trip. The
                # Service still selects uis.io/external-proxy=true, which nothing
                # carries once the proxy pod is gone - so the StatefulSet comes
                # back up, the Service matches NOTHING, and every consumer fails
                # while the database is perfectly healthy. The tester hit this and
                # had to patch it by hand.
                #
                # 900-external-service-proxy.yml stored the original selector on
                # the Service before replacing it. The annotation value is already
                # JSON, so it drops straight into a JSON patch.
                local _orig_sel
                _orig_sel="$(kubectl get service "$service_id" \
                    -n "${SCRIPT_NAMESPACE:-default}" --context "$target_host" \
                    -o jsonpath="{.metadata.annotations['uis\.io/original-selector']}" 2>/dev/null || true)"
                if [[ -n "$_orig_sel" ]]; then
                    log_info "  restoring the Service selector the proxy replaced"
                    kubectl patch service "$service_id" \
                        -n "${SCRIPT_NAMESPACE:-default}" --context "$target_host" \
                        --type=json \
                        -p "[{\"op\":\"replace\",\"path\":\"/spec/selector\",\"value\":$_orig_sel}]" \
                        >/dev/null 2>&1 \
                      && kubectl annotate service "$service_id" \
                           -n "${SCRIPT_NAMESPACE:-default}" --context "$target_host" \
                           uis.io/original-selector- >/dev/null 2>&1 \
                      || log_warn "  could not restore the Service selector; restore it by hand or the service is unreachable"
                else
                    # No annotation: either the Service was created by the proxy
                    # itself (nothing to go back to - asgard's shape), or the proxy
                    # predates this change. Dropping the marker leaves the service
                    # name label, which the in-cluster workload also carries.
                    log_warn "  no remembered selector for $service_id"
                    log_warn "  if it was proxied by an older UIS, check: kubectl get svc $service_id -o jsonpath='{.spec.selector}'"
                fi

            fi

            # ⚠️ UNCONDITIONAL, AND IT USED TO BE INSIDE THE BLOCK ABOVE.
            #
            # The scale-back was gated on having recognised a proxy by its marker.
            # So reverting a declaration whose proxy predates the marker left the
            # StatefulSet at ZERO REPLICAS, the orphaned proxy still relaying, and
            # the cluster silently still served by the external database - with no
            # output at all. The tester measured exactly that on a pre-marker
            # fixture built to reproduce production.
            #
            # Bringing the in-cluster workload back up is not conditional on
            # recognising anything. If we are deploying in-cluster and the
            # workload is scaled to zero, it must come back. Safe because the
            # stand-down never touched the PVC.
            local _sts_replicas
            _sts_replicas="$(kubectl get statefulset "$service_id" \
                -n "${SCRIPT_NAMESPACE:-default}" --context "$target_host" \
                -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
            if [[ "$_sts_replicas" == "0" ]]; then
                log_info "  in-cluster $service_id is scaled to 0; restoring it to 1 replica"
                kubectl scale statefulset "$service_id" --replicas=1 \
                    -n "${SCRIPT_NAMESPACE:-default}" --context "$target_host" \
                    >/dev/null 2>&1 || \
                    log_warn "  could not scale it back; the setup playbook may still do so"
            fi

            # An unmarked proxy cannot be removed automatically - deleting a
            # workload on a name match alone is not something a deploy should do -
            # but it must not be removed SILENTLY either. A Deployment and a
            # StatefulSet sharing the service's name is the pre-marker proxy shape.
            if [[ -z "$_proxy_found" ]] \
               && kubectl get deployment "$service_id" -n "${SCRIPT_NAMESPACE:-default}" \
                    --context "$target_host" >/dev/null 2>&1 \
               && [[ -n "$_sts_replicas" ]]; then
                log_warn "$service_id has BOTH a Deployment and a StatefulSet, and the"
                log_warn "  Deployment carries no uis.io/external-proxy marker."
                log_warn "  That is the shape of a proxy created before markers existed."
                log_warn "  It has NOT been removed - a deploy must not delete a workload on a"
                log_warn "  name match alone - so it may still be relaying, and the Service may"
                log_warn "  still select it. Check, then remove it by hand:"
                log_warn "    kubectl get endpoints $service_id -n ${SCRIPT_NAMESPACE:-default}"
                log_warn "    kubectl delete deployment $service_id -n ${SCRIPT_NAMESPACE:-default}"
            fi
        fi

        # Build extra-vars. Multi-instance services receive per-app context.
        local -a ansible_args=("-e" "target_host=$target_host")
        if [[ -n "$_ext_host" ]]; then
            ansible_args+=("-e" "_service_id=$service_id"
                           "-e" "_proxy_template=$_ext_tpl"
                           "-e" "_external_host=$_ext_host"
                           "-e" "_namespace=${SCRIPT_NAMESPACE:-default}")
            # `-` means the declaration named no port: let the template default it.
            [[ "$_ext_port" != "-" ]] && ansible_args+=("-e" "_external_port=$_ext_port")
        fi
        if [[ -n "$app_name" ]]; then
            ansible_args+=("-e" "_app_name=$app_name")
            [[ -n "$url_prefix" ]] && ansible_args+=("-e" "_url_prefix=$url_prefix")
            log_info "Running Ansible playbook: $SCRIPT_PLAYBOOK (target: $target_host, app: $app_name)"
        else
            log_info "Running Ansible playbook: $SCRIPT_PLAYBOOK (target: $target_host)"
        fi

        # Forward system-wide DEFAULT_* knobs from default-secrets.env as
        # lowercased ansible extra-vars (DEFAULT_AUTOSCALING -> default_autoscaling).
        # Setup playbooks pick them up via `vars:` mappings to per-service vars
        # (see e.g. _gravitee_autoscaling in 090-setup-gravitee.yml). Comment
        # block in default-secrets.env documents the adoption procedure for
        # new knobs.
        local defaults_file="/mnt/urbalurbadisk/provision-host/uis/templates/default-secrets.env"
        if [[ -f "$defaults_file" ]]; then
            while IFS='=' read -r key value; do
                # Skip blank lines and comments.
                [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
                # Only forward DEFAULT_* — other lines (e.g. CLOUDFLARE_*)
                # belong to the secrets pipeline, not the playbook-knob path.
                [[ "$key" == DEFAULT_* ]] || continue
                # Strip surrounding quotes if any, then forward lowercased.
                value="${value%\"}"; value="${value#\"}"
                value="${value%\'}"; value="${value#\'}"
                local lower_key="${key,,}"
                ansible_args+=("-e" "${lower_key}=${value}")
            done < "$defaults_file"
        fi

        if ! ansible-playbook "$playbook_path" "${ansible_args[@]}"; then
            die_k8s "Playbook failed: $SCRIPT_PLAYBOOK"
        fi

    elif [[ -n "$SCRIPT_MANIFEST" ]]; then
        # Direct manifest deployment
        local manifest_path="$MANIFESTS_DIR/$SCRIPT_MANIFEST"
        if [[ ! -f "$manifest_path" ]]; then
            die_config "Manifest not found: $SCRIPT_MANIFEST"
        fi
        log_info "Applying manifest: $SCRIPT_MANIFEST"
        if ! kubectl apply -f "$manifest_path"; then
            die_k8s "Manifest apply failed: $SCRIPT_MANIFEST"
        fi

    else
        log_warn "Service '$service_id' has no SCRIPT_PLAYBOOK or SCRIPT_MANIFEST - nothing to deploy"
        return 0
    fi

    # Verify deployment
    if [[ -n "$SCRIPT_CHECK_COMMAND" ]]; then
        log_info "Verifying deployment..."
        # Give it a moment to start
        sleep 2
        if check_service_deployed "$service_id"; then
            log_success "$SCRIPT_NAME deployed successfully"
        else
            log_warn "$SCRIPT_NAME deployed but health check failed (may need time to start)"
        fi
    else
        log_success "$SCRIPT_NAME deployment completed"
    fi

    return 0
}

# Remove a single service by ID
# Usage: remove_single_service <service_id> [<app_name>] [<purge>]
# For multi-instance services, app_name is required and is passed as _app_name
# extra-var to the removal playbook.
# When purge="true", _purge=true is passed as an extra-var so the removal
# playbook can drop persistent state (databases, roles, secrets, PVCs, namespace).
remove_single_service() {
    local service_id="$1"
    local app_name="${2:-}"
    local purge="${3:-false}"
    local script

    script=$(find_service_script "$service_id")

    if [[ -z "$script" ]]; then
        die_config "Service '$service_id' not found"
    fi

    # Load service metadata
    unset SCRIPT_ID SCRIPT_NAME SCRIPT_REMOVE SCRIPT_MANIFEST SCRIPT_REMOVE_PLAYBOOK
    # shellcheck source=/dev/null
    source "$script" 2>/dev/null

    if [[ -n "$app_name" ]]; then
        log_info "Removing $SCRIPT_NAME ($service_id) — app: $app_name..."
    else
        log_info "Removing $SCRIPT_NAME ($service_id)..."
    fi
    [[ "$purge" == "true" ]] && log_warn "Purge mode: persistent state will be deleted"

    # Load cluster config for target_host
    local cluster_config="$CONFIG_DIR/cluster-config.sh"
    local target_host="rancher-desktop"  # Default
    if [[ -f "$cluster_config" ]]; then
        # shellcheck source=/dev/null
        source "$cluster_config"
        target_host="${TARGET_HOST:-rancher-desktop}"
    fi

    # Option 1: Removal playbook (can include extra params like "-e operation=delete")
    if [[ -n "$SCRIPT_REMOVE_PLAYBOOK" ]]; then
        # Extract just the playbook filename (first word) to check if it exists
        local playbook_file="${SCRIPT_REMOVE_PLAYBOOK%% *}"
        local extra_params="${SCRIPT_REMOVE_PLAYBOOK#* }"
        # If no space found, extra_params equals playbook_file, so clear it
        [[ "$extra_params" == "$playbook_file" ]] && extra_params=""

        local remove_playbook="$ANSIBLE_DIR/$playbook_file"
        if [[ -f "$remove_playbook" ]]; then
            local -a ansible_args=("-e" "target_host=$target_host")
            [[ -n "$app_name" ]] && ansible_args+=("-e" "_app_name=$app_name")
            [[ "$purge" == "true" ]] && ansible_args+=("-e" "_purge=true")
            log_info "Running removal: $SCRIPT_REMOVE_PLAYBOOK"
            # shellcheck disable=SC2086
            if ! ansible-playbook "$remove_playbook" "${ansible_args[@]}" $extra_params; then
                die_k8s "Removal playbook failed"
            fi
            log_success "$SCRIPT_NAME removed"
            return 0
        fi
    fi

    # Option 2: Fall back to manifest deletion
    if [[ -n "$SCRIPT_MANIFEST" ]]; then
        local manifest_path="$MANIFESTS_DIR/$SCRIPT_MANIFEST"
        if [[ -f "$manifest_path" ]]; then
            log_info "Deleting manifest: $SCRIPT_MANIFEST"
            if ! kubectl delete -f "$manifest_path" --ignore-not-found; then
                die_k8s "Manifest deletion failed"
            fi
            log_success "$SCRIPT_NAME removed"
            return 0
        fi
    fi

    log_warn "No removal method found for $service_id - manual cleanup may be required"
    return 0
}

# Check if required dependencies are deployed
# Usage: check_dependencies "service1 service2 service3"
check_dependencies() {
    local requires="$1"
    local dep

    for dep in $requires; do
        if ! check_service_deployed "$dep"; then
            die_dependency "Required service '$dep' is not deployed"
        fi
        log_info "Dependency '$dep' is deployed"
    done

    return 0
}

# Get list of services sorted by priority
# Usage: get_services_by_priority
# Output: service IDs sorted by SCRIPT_PRIORITY (lower first)
get_services_by_priority() {
    local -a services_with_priority=()

    while IFS= read -r service_id; do
        local priority
        priority=$(get_service_value "$service_id" "SCRIPT_PRIORITY")
        priority="${priority:-50}"  # Default priority 50
        services_with_priority+=("$priority|$service_id")
    done < <(read_enabled_services)

    # Sort by priority (numeric) and output service IDs
    printf '%s\n' "${services_with_priority[@]}" | sort -t'|' -k1 -n | cut -d'|' -f2
}

# Show deployment status for all enabled services
# Usage: show_deployment_status
show_deployment_status() {
    log_info "Checking deployment status..."

    local service_id
    while IFS= read -r service_id; do
        local script
        script=$(find_service_script "$service_id")
        [[ -z "$script" ]] && continue

        unset SCRIPT_NAME SCRIPT_CHECK_COMMAND
        # shellcheck source=/dev/null
        source "$script" 2>/dev/null

        if [[ -z "$SCRIPT_CHECK_COMMAND" ]]; then
            echo "  $service_id: ${SCRIPT_NAME:-Unknown} - No health check"
        elif check_service_deployed "$service_id"; then
            echo "  $service_id: ${SCRIPT_NAME:-Unknown} - Deployed"
        else
            echo "  $service_id: ${SCRIPT_NAME:-Unknown} - Not deployed"
        fi
    done < <(read_enabled_services)
}
