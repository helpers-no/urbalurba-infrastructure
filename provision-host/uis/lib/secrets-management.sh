#!/bin/bash
# secrets-management.sh - Secrets management for UIS
#
# Provides commands for initializing, generating, and applying secrets.
# Works with the .uis.secrets/ structure.

# Guard against multiple sourcing
[[ -n "${_UIS_SECRETS_MANAGEMENT_LOADED:-}" ]] && return 0
_UIS_SECRETS_MANAGEMENT_LOADED=1

# Determine script directory for sourcing siblings
_SECRETS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source dependencies
source "$_SECRETS_SCRIPT_DIR/logging.sh"
source "$_SECRETS_SCRIPT_DIR/utilities.sh"
source "$_SECRETS_SCRIPT_DIR/paths.sh"
source "$_SECRETS_SCRIPT_DIR/first-run.sh"

# ============================================================
# Secrets Directory Functions (wrappers for paths.sh)
# ============================================================

# Get the user secrets directory (.uis.secrets/)
# Usage: get_user_secrets_dir
# Output: Path to .uis.secrets/ directory
get_user_secrets_dir() {
    get_secrets_dir
}

# Get the secrets templates directory
# Usage: get_secrets_templates_dir
# Output: Path to templates/uis.secrets/
get_secrets_templates_dir() {
    get_secrets_templates_dir_from_paths
}

# Internal: wrapper to avoid name collision
get_secrets_templates_dir_from_paths() {
    echo "$(get_templates_dir)/uis.secrets"
}

# Check if user has configured secrets
# Usage: has_user_secrets
# Returns: 0 if .uis.secrets/ exists and has config, 1 otherwise
has_user_secrets() {
    local secrets_dir
    secrets_dir=$(get_user_secrets_dir)

    [[ -d "$secrets_dir/secrets-config" && \
       -f "$secrets_dir/secrets-config/00-common-values.env.template" ]]
}

# ============================================================
# Secrets Initialization
# ============================================================

# Initialize secrets directory structure
# Usage: init_secrets
# Creates: .uis.secrets/ with subdirectories and default templates
init_secrets() {
    local secrets_dir
    secrets_dir=$(get_user_secrets_dir)

    if [[ -d "$secrets_dir" ]]; then
        log_warn "Secrets directory already exists: $secrets_dir"
        log_info "To reset, remove it first: rm -rf $secrets_dir"
        return 1
    fi

    log_info "Creating secrets directory structure..."

    # Create directory structure
    mkdir -p "$secrets_dir/secrets-config"
    mkdir -p "$secrets_dir/kubernetes"

    # Copy default template from UIS templates
    local uis_root
    uis_root=$(get_uis_root)
    local template_dir="$uis_root/templates"

    if [[ -f "$template_dir/default-secrets.env" ]]; then
        cp "$template_dir/default-secrets.env" \
           "$secrets_dir/secrets-config/00-common-values.env.template"
        log_success "Created 00-common-values.env.template with working defaults"
    else
        log_warn "default-secrets.env not found in $template_dir — secrets template not created"
    fi

    # Copy README
    if [[ -f "$uis_root/templates/uis.secrets/README.md" ]]; then
        cp "$uis_root/templates/uis.secrets/README.md" "$secrets_dir/"
    fi

    # Copy .gitignore
    if [[ -f "$uis_root/templates/uis.secrets/.gitignore" ]]; then
        cp "$uis_root/templates/uis.secrets/.gitignore" "$secrets_dir/"
    else
        echo "# Never commit secrets" > "$secrets_dir/.gitignore"
        echo "*" >> "$secrets_dir/.gitignore"
        echo "!.gitignore" >> "$secrets_dir/.gitignore"
        echo "!README.md" >> "$secrets_dir/.gitignore"
    fi

    log_success "Secrets directory initialized: $secrets_dir"
    echo ""
    echo "Next steps:"
    echo "  1. Edit: $secrets_dir/secrets-config/00-common-values.env.template"
    echo "  2. Generate: uis secrets generate"
    echo "  3. Apply: uis secrets apply"

    return 0
}

# ============================================================
# Secrets Status
# ============================================================

# Show secrets configuration status
# Usage: show_secrets_status
show_secrets_status() {
    local secrets_dir
    secrets_dir=$(get_user_secrets_dir)

    print_section "Secrets Configuration Status"

    if has_user_secrets; then
        echo "Secrets Source: Custom configuration"
        echo "Location: $secrets_dir"
    elif is_using_default_secrets; then
        echo "Secrets Source: Built-in defaults (no .uis.secrets/ found)"
        echo ""
        log_info "Using built-in defaults - suitable for localhost development"
        log_info "Run 'uis secrets init' to customize"
    else
        echo "Secrets Source: Unknown"
    fi

    echo ""

    # Show default values status
    echo "Core Variables (have working defaults):"
    local vars_core="DEFAULT_ADMIN_EMAIL DEFAULT_ADMIN_PASSWORD DEFAULT_DATABASE_PASSWORD DEFAULT_REDIS_PASSWORD DEFAULT_AUTHENTIK_SECRET_KEY DEFAULT_AUTHENTIK_BOOTSTRAP_PASSWORD DEFAULT_OPENWEBUI_SECRET_KEY"
    for var in $vars_core; do
        local value
        value=$(get_default_secret "$var")
        if [[ -n "$value" ]]; then
            # Mask passwords and secret keys
            if [[ "$var" == *PASSWORD* ]] || [[ "$var" == *SECRET* ]]; then
                echo "  ✅ $var: ********"
            else
                echo "  ✅ $var: $value"
            fi
        else
            echo "  ❌ $var: not set"
        fi
    done

    echo ""
    echo "External Services (configure when needed):"
    local vars_external="TAILSCALE_SECRET CLOUDFLARE_DNS_TOKEN CLOUDFLARE_TUNNEL_TOKEN OPENAI_API_KEY ANTHROPIC_API_KEY GITHUB_ACCESS_TOKEN"
    for var in $vars_external; do
        local value
        value=$(get_default_secret "$var")
        if [[ -n "$value" && "$value" != '""' && "$value" != "''" ]]; then
            echo "  ✅ $var: configured"
        else
            echo "  ⚪ $var: not set"
        fi
    done
}

# ============================================================
# Secrets Generation
# ============================================================

# Generate Kubernetes secrets from templates
# Usage: generate_secrets
# Reads: .uis.secrets/secrets-config/
# Creates: .uis.secrets/generated/kubernetes/kubernetes-secrets.yml
generate_secrets() {
    # Sync master template from source (picks up new keys from image updates)
    copy_secrets_templates

    # Validate before generating — fail early on bad email or missing variables
    if has_user_secrets && ! validate_secrets; then
        log_error "Fix validation errors before generating secrets"
        return 1
    fi

    # Use the generate function from first-run.sh
    generate_kubernetes_secrets
}

# ============================================================
# Secrets Application
# ============================================================

# Apply generated secrets to Kubernetes
# Usage: apply_secrets
# Checks multiple locations for secrets file:
# 1. .uis.secrets/generated/kubernetes/kubernetes-secrets.yml (new location)
# 2. .uis.secrets/kubernetes/kubernetes-secrets.yml (legacy location)
apply_secrets() {
    local secrets_dir
    secrets_dir=$(get_user_secrets_dir)

    # Check for secrets file in order of preference
    local secrets_file=""
    local file_locations=(
        "$secrets_dir/generated/kubernetes/kubernetes-secrets.yml"
        "$secrets_dir/kubernetes/kubernetes-secrets.yml"
    )

    for location in "${file_locations[@]}"; do
        if [[ -f "$location" ]]; then
            secrets_file="$location"
            break
        fi
    done

    if [[ -z "$secrets_file" ]]; then
        log_error "No secrets file found"
        log_info "Expected at: ${file_locations[0]}"
        log_info ""
        log_info "Run 'uis list' to trigger initialization (creates default secrets)"
        log_info "Or run 'uis secrets generate' for custom secrets"
        return 1
    fi

    log_info "Applying secrets from: $secrets_file"

    if ! kubectl apply -f "$secrets_file"; then
        log_error "Failed to apply secrets"
        return 1
    fi

    log_success "Secrets applied successfully"
    return 0
}

# ============================================================
# Secrets Validation
# ============================================================

# Validate secrets configuration
# Usage: validate_secrets
# Returns: 0 if valid, 1 if issues found
validate_secrets() {
    local secrets_dir
    secrets_dir=$(get_user_secrets_dir)

    if ! has_user_secrets; then
        log_warn "No custom secrets configured"
        log_info "Using built-in defaults for localhost development"
        return 0
    fi

    local config_file="$secrets_dir/secrets-config/00-common-values.env.template"
    local has_issues=false

    log_info "Validating secrets configuration..."

    # Source config
    set -a
    # shellcheck source=/dev/null
    source "$config_file"
    set +a

    # Check required variables
    local required_vars="DEFAULT_ADMIN_EMAIL DEFAULT_ADMIN_PASSWORD DEFAULT_DATABASE_PASSWORD DEFAULT_REDIS_PASSWORD DEFAULT_AUTHENTIK_SECRET_KEY DEFAULT_AUTHENTIK_BOOTSTRAP_PASSWORD DEFAULT_OPENWEBUI_SECRET_KEY"
    for var in $required_vars; do
        local value
        eval "value=\${$var:-}"
        if [[ -z "$value" ]]; then
            log_error "Required variable not set: $var"
            has_issues=true
        fi
    done

    # Validate email format — pgAdmin crashes if email lacks a proper domain
    local admin_email="${DEFAULT_ADMIN_EMAIL:-}"
    if [[ -n "$admin_email" ]]; then
        local email_user="${admin_email%%@*}"
        local email_domain="${admin_email##*@}"
        if [[ "$admin_email" != *"@"* ]] || [[ -z "$email_user" ]] || [[ -z "$email_domain" ]] || [[ "$email_domain" != *.* ]]; then
            log_error "Invalid DEFAULT_ADMIN_EMAIL: '$admin_email'"
            log_error "Must be a valid email with a real domain (e.g. admin@example.com)"
            log_error "Emails like admin@localhost will cause pgAdmin to crash on startup"
            has_issues=true
        fi
    fi

    # Check for weak default passwords if using custom config
    local weak_pattern="^LocalDev"
    for var in DEFAULT_ADMIN_PASSWORD DEFAULT_DATABASE_PASSWORD DEFAULT_REDIS_PASSWORD DEFAULT_AUTHENTIK_SECRET_KEY DEFAULT_AUTHENTIK_BOOTSTRAP_PASSWORD DEFAULT_OPENWEBUI_SECRET_KEY; do
        local value
        eval "value=\${$var:-}"
        if [[ "$value" =~ $weak_pattern ]]; then
            log_warn "$var is using a development default - change for production"
        fi
    done

    if [[ "$has_issues" == "true" ]]; then
        return 1
    fi

    log_success "Secrets configuration is valid"
    return 0
}

# ============================================================
# Secrets Edit
# ============================================================

# Open secrets config in editor
# Usage: edit_secrets
edit_secrets() {
    local secrets_dir
    secrets_dir=$(get_user_secrets_dir)
    local config_file="$secrets_dir/secrets-config/00-common-values.env.template"

    if [[ ! -f "$config_file" ]]; then
        log_error "Secrets config not found: $config_file"
        log_info "Run 'uis secrets init' first"
        return 1
    fi

    local editor="${EDITOR:-${VISUAL:-nano}}"

    log_info "Opening secrets config in $editor..."
    "$editor" "$config_file"

    return $?
}
