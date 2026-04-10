#!/bin/bash
# uis-hosts.sh - Host management library for UIS
#
# Provides functions for managing host configurations:
# - List available host templates
# - Copy templates to user's config
# - List user's configured hosts
# - Determine host requirements (SSH, Tailscale, etc.)

# Guard against multiple sourcing
[[ -n "${_UIS_HOSTS_LOADED:-}" ]] && return 0
_UIS_HOSTS_LOADED=1

# Determine script directory for sourcing siblings
if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "$0" ]]; then
    _HOSTS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    _HOSTS_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
fi

# Source dependencies (skip if already loaded)
[[ -z "${_UIS_LOGGING_LOADED:-}" ]] && source "$_HOSTS_SCRIPT_DIR/logging.sh"
[[ -z "${_UIS_UTILITIES_LOADED:-}" ]] && source "$_HOSTS_SCRIPT_DIR/utilities.sh"
[[ -z "${_UIS_PATHS_LOADED:-}" ]] && source "$_HOSTS_SCRIPT_DIR/paths.sh"

# ============================================================
# Path Functions (wrappers for paths.sh)
# ============================================================

# Get hosts templates directory
# Returns: Path to uis.extend/hosts templates
_get_hosts_templates_dir() {
    get_hosts_templates_dir
}

# Get user's extend directory
# Returns: Path to .uis.extend directory
_get_user_extend_dir() {
    get_extend_dir
}

# Get user's secrets directory
# Returns: Path to .uis.secrets directory
_get_user_secrets_dir() {
    get_secrets_dir
}

# ============================================================
# Host Type Definitions
# ============================================================
# Note: Using functions instead of associative arrays for bash 3.x compatibility

# Get description for a host type
# Usage: _get_host_type_info <host_type>
_get_host_type_info() {
    case "$1" in
        managed)   echo "Cloud-managed Kubernetes (AKS, GKE, EKS)" ;;
        cloud-vm)  echo "VM in cloud running MicroK8s" ;;
        physical)  echo "Physical device running MicroK8s" ;;
        local)     echo "Local development environment" ;;
        *)         echo "$1" ;;
    esac
}

# Get cloud-init template filename for a host template
# Usage: _get_cloud_init_template <template_name>
_get_cloud_init_template() {
    case "$1" in
        azure-microk8s) echo "azure-cloud-init-template.yml" ;;
        gcp-microk8s)   echo "gcp-cloud-init-template.yml" ;;
        raspberry-pi)   echo "raspberry-cloud-init-template.yml" ;;
        multipass)      echo "multipass-cloud-init-template.yml" ;;
        *)              echo "" ;;
    esac
}

# ============================================================
# Template Discovery
# ============================================================

# List available host templates
# Usage: hosts_list_templates
# Output: Prints formatted list of available templates
hosts_list_templates() {
    local templates_dir
    templates_dir=$(_get_hosts_templates_dir)

    echo "Available host templates:"
    echo ""

    for host_type in managed cloud-vm physical local; do
        local type_dir="$templates_dir/$host_type"
        local type_desc
        type_desc=$(_get_host_type_info "$host_type")

        if [[ -d "$type_dir" ]]; then
            echo "$host_type/     ($type_desc)"

            for template in "$type_dir"/*.conf.template; do
                [[ -f "$template" ]] || continue
                local name
                name=$(basename "$template" .conf.template)
                echo "  $name"
            done
            echo ""
        fi
    done

    echo "Usage: uis host add <template>"
}

# Get all template names
# Usage: hosts_get_all_templates
# Output: Space-separated list of template names
hosts_get_all_templates() {
    local templates_dir
    templates_dir=$(_get_hosts_templates_dir)
    local templates=""

    for host_type in managed cloud-vm physical local; do
        local type_dir="$templates_dir/$host_type"
        if [[ -d "$type_dir" ]]; then
            for template in "$type_dir"/*.conf.template; do
                [[ -f "$template" ]] || continue
                local name
                name=$(basename "$template" .conf.template)
                templates="$templates $name"
            done
        fi
    done

    echo "$templates"
}

# Check if a template exists
# Usage: hosts_template_exists <template_name>
# Returns: 0 if exists, 1 if not
hosts_template_exists() {
    local template_name="$1"
    local templates_dir
    templates_dir=$(_get_hosts_templates_dir)

    for host_type in managed cloud-vm physical local; do
        if [[ -f "$templates_dir/$host_type/$template_name.conf.template" ]]; then
            return 0
        fi
    done

    return 1
}

# Get host type for a template
# Usage: hosts_get_type <template_name>
# Output: managed, cloud-vm, physical, or local
hosts_get_type() {
    local template_name="$1"
    local templates_dir
    templates_dir=$(_get_hosts_templates_dir)

    for host_type in managed cloud-vm physical local; do
        if [[ -f "$templates_dir/$host_type/$template_name.conf.template" ]]; then
            echo "$host_type"
            return 0
        fi
    done

    return 1
}

# Get full path to template file
# Usage: hosts_get_template_path <template_name>
# Output: Full path to template file
hosts_get_template_path() {
    local template_name="$1"
    local templates_dir
    templates_dir=$(_get_hosts_templates_dir)

    for host_type in managed cloud-vm physical local; do
        local path="$templates_dir/$host_type/$template_name.conf.template"
        if [[ -f "$path" ]]; then
            echo "$path"
            return 0
        fi
    done

    return 1
}

# ============================================================
# Host Requirements
# ============================================================

# Check if host type requires SSH keys
# Usage: hosts_requires_ssh <host_type>
# Returns: 0 if requires SSH, 1 if not
hosts_requires_ssh() {
    case "$1" in
        cloud-vm|physical) return 0 ;;
        *) return 1 ;;
    esac
}

# Check if host type requires Tailscale
# Usage: hosts_requires_tailscale <host_type>
# Returns: 0 if requires Tailscale, 1 if not
hosts_requires_tailscale() {
    case "$1" in
        cloud-vm|physical) return 0 ;;
        *) return 1 ;;
    esac
}

# Check if host type requires cloud credentials
# Usage: hosts_requires_cloud_credentials <host_type>
# Returns: 0 if requires cloud credentials, 1 if not
hosts_requires_cloud_credentials() {
    case "$1" in
        managed|cloud-vm) return 0 ;;
        *) return 1 ;;
    esac
}

# Get cloud-init template for a host template
# Usage: hosts_get_cloud_init_template <template_name>
# Output: Cloud-init template filename or empty
hosts_get_cloud_init_template() {
    _get_cloud_init_template "$1"
}

# ============================================================
# User Host Management
# ============================================================

# List user's configured hosts
# Usage: hosts_list_configured
# Output: Formatted list of user's hosts with status
hosts_list_configured() {
    local extend_dir
    extend_dir=$(_get_user_extend_dir)
    local hosts_dir="$extend_dir/hosts"

    if [[ ! -d "$hosts_dir" ]]; then
        echo "No hosts configured yet."
        echo ""
        echo "Use 'uis host add <template>' to add a host."
        return 0
    fi

    echo "Configured hosts:"
    echo ""

    local found_any=false

    for host_type in managed cloud-vm physical local; do
        local type_dir="$hosts_dir/$host_type"
        [[ -d "$type_dir" ]] || continue

        local has_configs=false
        for config in "$type_dir"/*.conf; do
            [[ -f "$config" ]] || continue
            has_configs=true
            break
        done

        [[ "$has_configs" == "true" ]] || continue

        echo "$host_type/"
        found_any=true

        for config in "$type_dir"/*.conf; do
            [[ -f "$config" ]] || continue
            local name
            name=$(basename "$config" .conf)
            local status
            status=$(_get_host_status "$config" "$host_type")
            echo "  $name    $status"
        done
        echo ""
    done

    if [[ "$found_any" == "false" ]]; then
        echo "No hosts configured yet."
        echo ""
        echo "Use 'uis host add <template>' to add a host."
    fi
}

# Get status of a host configuration
# Usage: _get_host_status <config_file> <host_type>
# Output: Status string (ready/missing requirements)
_get_host_status() {
    local config_file="$1"
    local host_type="$2"
    local secrets_dir
    secrets_dir=$(_get_user_secrets_dir)

    local missing=""

    # Check SSH keys if required
    if hosts_requires_ssh "$host_type"; then
        if [[ ! -f "$secrets_dir/ssh/id_rsa_ansible" ]]; then
            missing="$missing ssh-keys"
        fi
    fi

    # Check Tailscale if required
    if hosts_requires_tailscale "$host_type"; then
        if [[ ! -f "$secrets_dir/service-keys/tailscale.env" ]]; then
            missing="$missing tailscale.env"
        fi
    fi

    # Check cloud credentials if required
    if hosts_requires_cloud_credentials "$host_type"; then
        # Source config to get CREDENTIALS variable
        local cred_name=""
        if [[ -f "$config_file" ]]; then
            cred_name=$(grep "^CREDENTIALS=" "$config_file" 2>/dev/null | cut -d= -f2 | tr -d '"')
        fi
        cred_name="${cred_name:-azure-default}"

        if [[ ! -f "$secrets_dir/cloud-accounts/$cred_name.env" ]]; then
            missing="$missing $cred_name.env"
        fi
    fi

    if [[ -z "$missing" ]]; then
        echo "✓ ready"
    else
        echo "✗ missing:$missing"
    fi
}

# Copy host template to user's config
# Usage: hosts_add_template <template_name> [config_name]
# Returns: 0 on success, 1 on failure
hosts_add_template() {
    local template_name="$1"
    local config_name="${2:-$template_name}"

    # Validate template exists
    if ! hosts_template_exists "$template_name"; then
        log_error "Template not found: $template_name"
        log_info "Run 'uis host add' to see available templates"
        return 1
    fi

    local host_type
    host_type=$(hosts_get_type "$template_name")

    local template_path
    template_path=$(hosts_get_template_path "$template_name")

    local extend_dir
    extend_dir=$(_get_user_extend_dir)
    local dest_dir="$extend_dir/hosts/$host_type"
    local dest_file="$dest_dir/$config_name.conf"

    # Create directory if needed
    mkdir -p "$dest_dir"

    # Check if config already exists
    if [[ -f "$dest_file" ]]; then
        log_warn "Configuration already exists: $dest_file"
        log_info "Edit the existing file or remove it first"
        return 1
    fi

    # Copy template
    cp "$template_path" "$dest_file"
    log_success "Created: $dest_file"

    # Handle requirements
    _handle_host_requirements "$host_type" "$template_name"

    # Print next steps
    echo ""
    echo "Next steps:"
    echo "  1. Edit: $dest_file"
    _print_required_secrets "$host_type" "$template_name"

    return 0
}

# Handle requirements for a host type
# Usage: _handle_host_requirements <host_type> <template_name>
_handle_host_requirements() {
    local host_type="$1"
    local template_name="$2"
    local secrets_dir
    secrets_dir=$(_get_user_secrets_dir)

    # Generate SSH keys if needed
    if hosts_requires_ssh "$host_type"; then
        if [[ ! -f "$secrets_dir/ssh/id_rsa_ansible" ]]; then
            log_info "Generating SSH keys..."
            # Source first-run.sh for generate_ssh_keys function
            source "$_HOSTS_SCRIPT_DIR/first-run.sh"
            if type generate_ssh_keys &>/dev/null; then
                generate_ssh_keys
            else
                log_warn "Could not generate SSH keys automatically"
            fi
        fi
    fi

    # Copy secret templates if they don't exist
    local templates_base
    templates_base="${TEMPLATES_DIR:-/mnt/urbalurbadisk/provision-host/uis/templates}"

    if hosts_requires_tailscale "$host_type"; then
        if [[ ! -f "$secrets_dir/service-keys/tailscale.env" ]]; then
            mkdir -p "$secrets_dir/service-keys"
            if [[ -f "$templates_base/uis.secrets/service-keys/tailscale.env.template" ]]; then
                cp "$templates_base/uis.secrets/service-keys/tailscale.env.template" \
                   "$secrets_dir/service-keys/tailscale.env"
                log_info "Created: service-keys/tailscale.env (edit with your key)"
            fi
        fi
    fi

    if hosts_requires_cloud_credentials "$host_type"; then
        # Determine cloud provider from template name
        local provider=""
        case "$template_name" in
            azure-*) provider="azure" ;;
            gcp-*) provider="gcp" ;;
            aws-*) provider="aws" ;;
        esac

        if [[ -n "$provider" && ! -f "$secrets_dir/cloud-accounts/$provider-default.env" ]]; then
            mkdir -p "$secrets_dir/cloud-accounts"
            if [[ -f "$templates_base/uis.secrets/cloud-accounts/$provider.env.template" ]]; then
                cp "$templates_base/uis.secrets/cloud-accounts/$provider.env.template" \
                   "$secrets_dir/cloud-accounts/$provider-default.env"
                log_info "Created: cloud-accounts/$provider-default.env (edit with your credentials)"
            fi
        fi
    fi
}

# Print required secrets for a host type
# Usage: _print_required_secrets <host_type> <template_name>
_print_required_secrets() {
    local host_type="$1"
    local template_name="$2"
    local step=2

    if hosts_requires_cloud_credentials "$host_type"; then
        local provider=""
        case "$template_name" in
            azure-*) provider="azure" ;;
            gcp-*) provider="gcp" ;;
            aws-*) provider="aws" ;;
        esac
        if [[ -n "$provider" ]]; then
            echo "  $step. Configure: .uis.secrets/cloud-accounts/$provider-default.env"
            ((step++))
        fi
    fi

    if hosts_requires_tailscale "$host_type"; then
        echo "  $step. Configure: .uis.secrets/service-keys/tailscale.env"
        ((step++))
    fi

    if hosts_requires_ssh "$host_type"; then
        echo "  $step. SSH keys auto-generated in .uis.secrets/ssh/"
        ((step++))
    fi

    echo "  $step. Run: uis host list (to verify status)"
}
