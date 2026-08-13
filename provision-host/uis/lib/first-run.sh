#!/bin/bash
# first-run.sh - First-run helpers (runs INSIDE container)
#
# NOTE: Folder creation (.uis.extend/, .uis.secrets/) normally happens on HOST in wrapper script.
# However, copy_defaults_if_missing() also creates them with mkdir -p as a fallback,
# so the CLI works from a fresh git checkout without Docker (e.g., CI, direct host usage).

# Guard against multiple sourcing
[[ -n "${_UIS_FIRST_RUN_LOADED:-}" ]] && return 0
_UIS_FIRST_RUN_LOADED=1

# shellcheck disable=SC2034  # Variables are used by callers

# Determine script directory for sourcing siblings
_FIRSTRUN_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source dependencies
source "$_FIRSTRUN_SCRIPT_DIR/logging.sh"
source "$_FIRSTRUN_SCRIPT_DIR/utilities.sh"
source "$_FIRSTRUN_SCRIPT_DIR/paths.sh"

# Note: TEMPLATES_DIR, EXTEND_DIR, SECRETS_DIR are set by paths.sh

# Check if first-run setup has been completed
# Returns: 0 if configured, 1 if needs setup
check_first_run() {
    [[ -f "$EXTEND_DIR/enabled-services.conf" ]]
}

# Copy default config files if they don't exist
# Called when container starts with empty mounted volumes, or on first CLI run.
# In Docker: wrapper script creates .uis.extend/ and .uis.secrets/ before mounting.
# Outside Docker (CI, fresh checkout): directories don't exist yet, so we create them.
copy_defaults_if_missing() {
    local templates_extend="$TEMPLATES_DIR/uis.extend"
    local templates_secrets="$TEMPLATES_DIR/uis.secrets"

    # Create target directories if missing. Normally the Docker wrapper does this,
    # but outside Docker (CI, direct host usage) they won't exist yet.
    # mkdir -p is idempotent — safe to call even if directories already exist.
    mkdir -p "$EXTEND_DIR"
    mkdir -p "$SECRETS_DIR"

    # Copy enabled-services.conf
    if [[ ! -f "$EXTEND_DIR/enabled-services.conf" ]]; then
        if [[ -f "$templates_extend/enabled-services.conf.default" ]]; then
            cp "$templates_extend/enabled-services.conf.default" "$EXTEND_DIR/enabled-services.conf"
            log_info "Created enabled-services.conf with defaults"
        else
            log_warn "Template enabled-services.conf.default not found"
        fi
    fi

    # Copy cluster-config.sh
    if [[ ! -f "$EXTEND_DIR/cluster-config.sh" ]]; then
        if [[ -f "$templates_extend/cluster-config.sh.default" ]]; then
            cp "$templates_extend/cluster-config.sh.default" "$EXTEND_DIR/cluster-config.sh"
            log_info "Created cluster-config.sh with defaults"
        else
            log_warn "Template cluster-config.sh.default not found"
        fi
    fi

    # Copy enabled-tools.conf
    if [[ ! -f "$EXTEND_DIR/enabled-tools.conf" ]]; then
        if [[ -f "$templates_extend/enabled-tools.conf.default" ]]; then
            cp "$templates_extend/enabled-tools.conf.default" "$EXTEND_DIR/enabled-tools.conf"
            log_info "Created enabled-tools.conf with defaults"
        else
            log_warn "Template enabled-tools.conf.default not found"
        fi
    fi

    # Declares nothing. Present so the capability is discoverable by reading your
    # own extend dir, rather than only by reading the docs.
    if [[ ! -f "$EXTEND_DIR/external-services.yaml" ]]; then
        if [[ -f "$templates_extend/external-services.yaml.default" ]]; then
            cp "$templates_extend/external-services.yaml.default" "$EXTEND_DIR/external-services.yaml"
        fi
    fi

    # Copy secrets README if missing
    if [[ ! -f "$SECRETS_DIR/README.md" ]]; then
        if [[ -f "$templates_secrets/README.md" ]]; then
            cp "$templates_secrets/README.md" "$SECRETS_DIR/README.md"
            log_info "Created secrets README.md"
        fi
    fi

    # Create secrets subdirectories if missing (original structure)
    local subdirs=("secrets-config" "kubernetes" "api-keys")
    for subdir in "${subdirs[@]}"; do
        if [[ ! -d "$SECRETS_DIR/$subdir" ]]; then
            mkdir -p "$SECRETS_DIR/$subdir"
            log_info "Created $SECRETS_DIR/$subdir/"
        fi
    done

    # Create new secrets subdirectories (for secrets consolidation)
    local new_subdirs=("ssh" "cloud-accounts" "service-keys" "network" "generated/kubernetes" "generated/ubuntu-cloud-init" "generated/kubeconfig")
    for subdir in "${new_subdirs[@]}"; do
        if [[ ! -d "$SECRETS_DIR/$subdir" ]]; then
            mkdir -p "$SECRETS_DIR/$subdir"
            log_info "Created $SECRETS_DIR/$subdir/"
        fi
    done

    # Create hosts subdirectories in .uis.extend/
    local host_subdirs=("hosts/managed" "hosts/cloud-vm" "hosts/physical" "hosts/local")
    for subdir in "${host_subdirs[@]}"; do
        if [[ ! -d "$EXTEND_DIR/$subdir" ]]; then
            mkdir -p "$EXTEND_DIR/$subdir"
            log_info "Created $EXTEND_DIR/$subdir/"
        fi
    done

    # Copy secrets templates, generate, and apply Kubernetes secrets.
    # Non-fatal (|| true) because these depend on external tools (envsubst, kubectl)
    # and a running cluster, which won't be available in CI or on a fresh checkout.
    # Each function logs its own warnings when it can't complete.
    copy_secrets_templates || true
    generate_kubernetes_secrets || true
    apply_kubernetes_secrets || true
}

# Validate that config structure is correct
# Returns: 0 if valid, dies with error if invalid
validate_config_structure() {
    if [[ ! -d "$EXTEND_DIR" ]]; then
        die_config ".uis.extend/ not mounted at $EXTEND_DIR"
    fi

    if [[ ! -d "$SECRETS_DIR" ]]; then
        die_config ".uis.secrets/ not mounted at $SECRETS_DIR"
    fi

    if [[ ! -f "$EXTEND_DIR/enabled-services.conf" ]]; then
        die_config "enabled-services.conf missing from $EXTEND_DIR"
    fi

    return 0
}

# Initialize UIS configuration (copy defaults and validate)
# This should be called once at startup
initialize_uis_config() {
    log_info "Initializing UIS configuration..."

    # Copy defaults if missing
    copy_defaults_if_missing

    # Validate structure
    validate_config_structure

    log_success "UIS configuration initialized"
}

# Load cluster configuration
# Exports: CLUSTER_TYPE, PROJECT_NAME, BASE_DOMAIN, TARGET_HOST
load_cluster_config() {
    local config_file="$EXTEND_DIR/cluster-config.sh"

    if [[ -f "$config_file" ]]; then
        # shellcheck source=/dev/null
        source "$config_file"
        log_info "Loaded cluster config: $CLUSTER_TYPE"
    else
        # Use defaults
        CLUSTER_TYPE="${CLUSTER_TYPE:-rancher-desktop}"
        PROJECT_NAME="${PROJECT_NAME:-uis}"
        BASE_DOMAIN="${BASE_DOMAIN:-localhost}"
        TARGET_HOST="${TARGET_HOST:-rancher-desktop}"
        log_warn "No cluster-config.sh found, using defaults"
    fi

    export CLUSTER_TYPE PROJECT_NAME BASE_DOMAIN TARGET_HOST
}

# Get default secrets value (for development)
# Usage: get_default_secret <key>
# Returns: the default value or empty string
get_default_secret() {
    local key="$1"
    local defaults_file="$TEMPLATES_DIR/default-secrets.env"

    if [[ ! -f "$defaults_file" ]]; then
        return 1
    fi

    # Source the file and get the value
    (
        # shellcheck source=/dev/null
        source "$defaults_file" 2>/dev/null
        echo "${!key}"
    )
}

# Check if using default secrets (development mode)
# Returns: 0 if using defaults, 1 if custom secrets configured
is_using_default_secrets() {
    # If any custom secret files exist, not using defaults
    if [[ -n "$(ls -A "$SECRETS_DIR/secrets-config" 2>/dev/null)" ]]; then
        return 1
    fi
    if [[ -n "$(ls -A "$SECRETS_DIR/api-keys" 2>/dev/null)" ]]; then
        return 1
    fi
    return 0
}

# Generate SSH keys for ansible user (used for VM provisioning)
# Keys are created in .uis.secrets/ssh/
# Returns: 0 if keys exist or created successfully, 1 on error
generate_ssh_keys() {
    local ssh_dir="$SECRETS_DIR/ssh"
    local private_key="$ssh_dir/id_rsa_ansible"
    local public_key="$ssh_dir/id_rsa_ansible.pub"

    # Ensure directory exists
    mkdir -p "$ssh_dir"

    # Check if keys already exist
    if [[ -f "$private_key" && -f "$public_key" ]]; then
        log_info "SSH keys already exist"
        return 0
    fi

    # Generate new key pair
    log_info "Generating SSH keys for ansible user..."
    if ssh-keygen -t rsa -b 4096 -f "$private_key" -N "" -C "ansible@uis" >/dev/null 2>&1; then
        chmod 600 "$private_key"
        chmod 644 "$public_key"
        log_success "SSH keys generated: $ssh_dir/"
        return 0
    else
        log_error "Failed to generate SSH keys"
        return 1
    fi
}

# Check if SSH keys exist
# Returns: 0 if keys exist, 1 if not
ssh_keys_exist() {
    local ssh_dir="$SECRETS_DIR/ssh"
    [[ -f "$ssh_dir/id_rsa_ansible" && -f "$ssh_dir/id_rsa_ansible.pub" ]]
}

# Copy secrets templates to .uis.secrets/secrets-config/ on first run
# Also syncs the master template on every run (structural, not user-edited)
# Workflow: edit secrets-config/, then generate kubernetes secrets
# Returns: 0 if copied or already exists
copy_secrets_templates() {
    local templates_src="$TEMPLATES_DIR/secrets-templates"
    local secrets_config="$SECRETS_DIR/secrets-config"

    # If common-values already exists, just sync the master template
    # (master template is structural — new image versions may add keys)
    if [[ -f "$secrets_config/00-common-values.env.template" ]]; then
        local src_master="$templates_src/00-master-secrets.yml.template"
        local dst_master="$secrets_config/00-master-secrets.yml.template"
        if [[ -f "$src_master" ]] && ! diff -q "$src_master" "$dst_master" >/dev/null 2>&1; then
            cp "$src_master" "$dst_master"
            log_info "Updated master secrets template (new keys available)"
        fi
        return 0
    fi

    # Check if templates exist in container
    if [[ ! -d "$templates_src" ]]; then
        log_warn "Secrets templates not found at: $templates_src"
        return 1
    fi

    log_info "Copying secrets templates to $secrets_config/"

    # Ensure target directory exists
    mkdir -p "$secrets_config"

    # Copy all template files
    cp -r "$templates_src"/* "$secrets_config/" 2>/dev/null || true

    # Update the common values with development defaults from default-secrets.env
    local common_values="$secrets_config/00-common-values.env.template"
    local defaults_file="$TEMPLATES_DIR/default-secrets.env"
    if [[ -f "$common_values" ]] && [[ -f "$defaults_file" ]]; then
        # Read defaults from the single source of truth
        # shellcheck source=/dev/null
        source "$defaults_file"
        # Apply defaults to template (uses variables from default-secrets.env)
        sed -i.bak \
            -e "s/DEFAULT_ADMIN_EMAIL=.*/DEFAULT_ADMIN_EMAIL=${DEFAULT_ADMIN_EMAIL}/" \
            -e "s/DEFAULT_ADMIN_PASSWORD=.*/DEFAULT_ADMIN_PASSWORD=${DEFAULT_ADMIN_PASSWORD}/" \
            -e "s/DEFAULT_DATABASE_PASSWORD=.*/DEFAULT_DATABASE_PASSWORD=${DEFAULT_DATABASE_PASSWORD}/" \
            -e "s/ADMIN_PASSWORD=.*/ADMIN_PASSWORD=${DEFAULT_ADMIN_PASSWORD}/" \
            -e "s/DEFAULT_REDIS_PASSWORD=.*/DEFAULT_REDIS_PASSWORD=${DEFAULT_REDIS_PASSWORD}/" \
            -e "s/DEFAULT_AUTHENTIK_SECRET_KEY=.*/DEFAULT_AUTHENTIK_SECRET_KEY=${DEFAULT_AUTHENTIK_SECRET_KEY}/" \
            -e "s/DEFAULT_AUTHENTIK_BOOTSTRAP_PASSWORD=.*/DEFAULT_AUTHENTIK_BOOTSTRAP_PASSWORD=${DEFAULT_AUTHENTIK_BOOTSTRAP_PASSWORD}/" \
            -e "s/DEFAULT_OPENWEBUI_SECRET_KEY=.*/DEFAULT_OPENWEBUI_SECRET_KEY=${DEFAULT_OPENWEBUI_SECRET_KEY}/" \
            -e "s|DEFAULT_ORGANIZATION_NAME=.*|DEFAULT_ORGANIZATION_NAME=\"${DEFAULT_ORGANIZATION_NAME}\"|" \
            "$common_values"
        rm -f "$common_values.bak"
        log_success "Set development defaults in 00-common-values.env.template"
    fi

    log_success "Secrets templates copied to: $secrets_config/"
    return 0
}

# Generate Kubernetes secrets using envsubst (same approach as create-kubernetes-secrets.sh)
# Reads: .uis.secrets/secrets-config/
# Writes: .uis.secrets/generated/kubernetes/kubernetes-secrets.yml
# Returns: 0 on success, 1 on error
generate_kubernetes_secrets() {
    local secrets_config="$SECRETS_DIR/secrets-config"
    local output_dir="$SECRETS_DIR/generated/kubernetes"
    local output_file="$output_dir/kubernetes-secrets.yml"
    local common_values="$secrets_config/00-common-values.env.template"
    local master_template="$secrets_config/00-master-secrets.yml.template"

    # Ensure output directory exists
    mkdir -p "$output_dir"

    # Check required files
    if [[ ! -f "$common_values" ]]; then
        log_error "Common values not found: $common_values"
        log_info "Run 'uis list' to initialize, or copy templates manually"
        return 1
    fi

    if [[ ! -f "$master_template" ]]; then
        log_error "Master template not found: $master_template"
        return 1
    fi

    log_info "Generating Kubernetes secrets..."

    # Load common values as environment variables
    set -a
    # shellcheck source=/dev/null
    source "$common_values" || {
        log_error "Failed to load common values"
        return 1
    }
    set +a

    # Derive TAILSCALE_OWNER_ID from GITHUB_USERNAME if blank.
    # GNU envsubst doesn't evaluate ${VAR:-default} syntax — it only
    # does plain ${VAR} substitution — so the fallback has to be
    # resolved in shell before envsubst runs. Mirrors the resolved-
    # value check in secrets-management.sh::validate_secrets.
    if [[ -z "${TAILSCALE_OWNER_ID:-}" ]]; then
        local _gh_lc
        _gh_lc="$(printf '%s' "${GITHUB_USERNAME:-}" | tr '[:upper:]' '[:lower:]')"
        export TAILSCALE_OWNER_ID="k8s-${_gh_lc}"
    fi

    # Generate using envsubst
    if ! command -v envsubst &>/dev/null; then
        log_error "envsubst not found - cannot generate secrets"
        log_info "Install gettext package: apt-get install gettext-base"
        return 1
    fi

    envsubst < "$master_template" > "$output_file" || {
        log_error "Failed to generate secrets file"
        return 1
    }

    local lines
    lines=$(wc -l < "$output_file")
    log_success "Generated: $output_file ($lines lines)"

    return 0
}

# Ensure Kubernetes secrets are generated and applied to the cluster
# This is idempotent - safe to call on every deploy
# Handles the case where host files exist but cluster was reset (e.g. factory reset)
# Returns: 0 on success, 1 on error
ensure_secrets_applied() {
    local secrets_file="$SECRETS_DIR/generated/kubernetes/kubernetes-secrets.yml"

    # Generate secrets if the file doesn't exist yet
    if [[ ! -f "$secrets_file" ]]; then
        log_info "Secrets file not found, generating..."
        copy_secrets_templates
        generate_kubernetes_secrets || return 1
    fi

    # Always apply to cluster (idempotent)
    apply_kubernetes_secrets
}

# Apply generated Kubernetes secrets to the cluster
# Reads: .uis.secrets/generated/kubernetes/kubernetes-secrets.yml
# Returns: 0 on success, 1 on error
apply_kubernetes_secrets() {
    local secrets_file="$SECRETS_DIR/generated/kubernetes/kubernetes-secrets.yml"

    # Check if secrets file exists
    if [[ ! -f "$secrets_file" ]]; then
        log_warn "Secrets file not found: $secrets_file"
        log_info "Run 'uis secrets generate' first"
        return 1
    fi

    # Check if kubectl is available
    if ! command -v kubectl &>/dev/null; then
        log_warn "kubectl not found - skipping secrets apply"
        log_info "Apply manually: kubectl apply -f $secrets_file"
        return 1
    fi

    # Check if cluster is reachable
    if ! kubectl cluster-info &>/dev/null 2>&1; then
        log_warn "Kubernetes cluster not reachable - skipping secrets apply"
        log_info "Start your cluster, then run: uis secrets apply"
        return 1
    fi

    log_info "Applying secrets to Kubernetes cluster..."

    if kubectl apply -f "$secrets_file" 2>&1; then
        log_success "Secrets applied to cluster"
        return 0
    else
        log_error "Failed to apply secrets"
        log_info "Try manually: kubectl apply -f $secrets_file"
        return 1
    fi
}
