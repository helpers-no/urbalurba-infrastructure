#!/bin/bash
# uis-cli.sh - UIS Command Line Interface
#
# This is the main CLI entry point called from inside the container.
# The ./uis wrapper script on the host routes commands here.
#
# Usage: uis-cli.sh <command> [args...]

set -e

# Get script directory and UIS root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UIS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$UIS_DIR/lib"

# Source libraries
source "$LIB_DIR/logging.sh"
source "$LIB_DIR/utilities.sh"
source "$LIB_DIR/categories.sh"
source "$LIB_DIR/stacks.sh"
source "$LIB_DIR/service-scanner.sh"
source "$LIB_DIR/first-run.sh"
source "$LIB_DIR/external-services.sh"
source "$LIB_DIR/service-deployment.sh"
source "$LIB_DIR/service-auto-enable.sh" 2>/dev/null || true
source "$LIB_DIR/menu-helpers.sh" 2>/dev/null || true
source "$LIB_DIR/tool-installation.sh" 2>/dev/null || true
source "$LIB_DIR/secrets-management.sh" 2>/dev/null || true
source "$LIB_DIR/uis-hosts.sh" 2>/dev/null || true
source "$LIB_DIR/integration-testing.sh" 2>/dev/null || true
source "$LIB_DIR/expose.sh" 2>/dev/null || true
source "$LIB_DIR/configure.sh" 2>/dev/null || true
source "$LIB_DIR/platform-switching.sh" 2>/dev/null || true
source "$LIB_DIR/template.sh" 2>/dev/null || true
source "$LIB_DIR/connect.sh" 2>/dev/null || true

# Version — read from version.txt at repo root (baked into container at /mnt/urbalurbadisk/version.txt)
_version_file="$(cd "$SCRIPT_DIR/../../.." && pwd)/version.txt"
UIS_VERSION="$(cat "$_version_file" 2>/dev/null | tr -d '[:space:]')"
UIS_VERSION="${UIS_VERSION:-0.1.0}"
unset _version_file

# ============================================================
# Command Functions
# ============================================================

cmd_version() {
    echo "UIS (Urbalurba Infrastructure Stack) v$UIS_VERSION"
}

cmd_help() {
    cat <<EOF
UIS (Urbalurba Infrastructure Stack) v$UIS_VERSION

Usage: uis <command> [options]

Interactive:
  setup                   Interactive TUI menu for service management
  init                    Initialize configuration (first-time setup wizard)

Service Discovery:
  list                    List available services with status
  status                  Show deployed services health
  categories              List service categories
  stacks                  List service stacks
  cluster types           List available cluster types

Service Deployment:
  deploy [service]                    Deploy all autostart services, or a specific service
  deploy <service> --app <name>       Deploy a multi-instance service for one app
  undeploy <service>                  Remove service from cluster
  undeploy <service> --app <name>     Remove one instance of a multi-instance service

Service Configuration (for DCT template integration):
  configure <service>     Create app-specific resources (database, user) and return connection JSON
  expose <service>        Expose service port to host machine for local development
  expose <service> --stop Stop exposing a service
  expose --status         Show currently exposed services

Stack Deployment:
  stack list              List available service stacks
  stack info <stack>      Show stack details and components
  stack install <stack>   Install all services in a stack
  stack remove <stack>    Remove all services in a stack

Template Deployment (from helpers-no/dev-templates):
  template list           List available UIS templates
  template info <id>      Show template details
  template install <id>   Install a UIS stack template (deploy + configure services)

Service Connections (interactive admin access):
  connect <service> [args]  Open an interactive client (psql, redis-cli, mysql, mongosh)

Configuration:
  enable <service>        Add service to autostart (deployed with 'uis deploy')
  disable <service>       Remove service from autostart (does not undeploy)
  list-enabled            Show services in autostart
  sync                    Update autostart list to match what's running in cluster

Host Management:
  host add                List available host templates
  host add <template>     Add a host configuration from template
  host list               List configured hosts with status
  host generate <name>    Generate cloud-init for physical devices
  host create <name>      Create cloud resources for a host

Secrets Management:
  secrets init            Create .uis.secrets/ structure with templates
  secrets status          Show secrets configuration status
  secrets edit            Open secrets config in editor
  secrets generate        Generate Kubernetes secrets from templates
  secrets apply           Apply generated secrets to cluster
  secrets validate        Validate secrets configuration

Tools:
  tools list              List all available tools with status
  tools install <tool>    Install an optional tool

Platform:
  platform init   <provider>  Interactive setup wizard for a cloud platform (e.g. azure-aks)
  platform list               Show all potential platforms and their current state
  platform up     <provider>  Provision the cluster end-to-end (bootstrap + apply + post-apply)
  platform status <provider>  Show cluster state, external IP, and cost estimate
  platform use    [<provider>]   Switch the active platform (interactive picker if no arg)
  platform down   <provider>  Tear down the cluster (delegates to 03-destroy.sh)

Network:
  network init     <provider>             Interactive setup wizard for a networking provider (cloudflare, tailscale)
  network list                            Show networking providers and their state
  network up       <provider>             Deploy the provider into the active cluster
  network status   <provider>             Show provider state, tunnel/route status, pod health
  network down     <provider>             Remove the provider's cluster footprint (config preserved)
  network verify   <provider>             Diagnostics for the provider's tunnel/route + pod
  network expose   <provider> <service>   Expose a service via Funnel (Tailscale only)
  network unexpose <provider> <service>   Remove a per-service Funnel exposure (Tailscale only)

PostgreSQL:
  postgresql verify              Verify the database answers (either topology)

Alloy:
  alloy verify                   Run E2E health checks on Alloy log collection

ArgoCD:
  argocd register <name> <url>  Register a GitHub repo as ArgoCD application
  argocd remove <name>          Remove an ArgoCD-managed application
  argocd list                   List registered ArgoCD applications
  argocd verify                 Run E2E health checks on ArgoCD server

Enonic XP:
  enonic verify                  Run E2E health checks on Enonic XP

MinIO:
  minio verify                   Run E2E health checks on MinIO object storage

OpenMetadata:
  openmetadata verify            Run E2E health checks on OpenMetadata

Temporal:
  temporal verify                Run E2E health checks on Temporal

Backstage:
  backstage verify               Run E2E health checks on Backstage (RHDH)

Nextcloud:
  nextcloud verify               Run E2E health checks on Nextcloud + OnlyOffice

Uptime Kuma:
  uptime-kuma verify             Run E2E health checks on Uptime Kuma

Testing:
  test-all                       Run full integration test (deploy+undeploy all services)
  test-all --dry-run             Show test plan without executing
  test-all --clean               Undeploy all services first, then run tests
  test-all --only <svc> [svc...] Test only specified services (+ their dependencies)

Documentation:
  docs generate           Generate JSON files for website
  docs plans              Generate plan index pages for website

Information:
  version                 Show UIS version
  help                    Show this help message

Examples:
  uis setup               # Open interactive menu
  uis init                # Run first-time setup wizard
  uis list                # Show all available services
  uis enable prometheus   # Enable prometheus
  uis deploy              # Deploy all autostart services
  uis stack list          # Show available stacks
  uis stack install observability  # Install full observability stack
  uis host add            # List available host templates
  uis host add azure-aks  # Add Azure AKS host configuration
  uis host list           # Show configured hosts with status
  uis secrets init        # Initialize secrets configuration
  uis secrets status      # Show what's configured
  uis tools list          # Show available tools
  uis tools install azure-cli  # Install Azure CLI
  uis network init cloudflare         # Set the Cloudflare tunnel token
  uis network up cloudflare           # Deploy the Cloudflare tunnel in-cluster
  uis network verify cloudflare       # Check Cloudflare tunnel configuration
  uis network init tailscale          # Set Tailscale OAuth + owner-id
  uis network up tailscale            # Install the Tailscale operator
  uis network expose tailscale whoami # Expose whoami via Tailscale Funnel
  uis network verify tailscale        # Check Tailscale configuration
  uis argocd register my-app https://github.com/owner/repo  # Register repo
  uis argocd remove my-app     # Remove ArgoCD application
  uis argocd list              # List registered ArgoCD applications
  uis test-all                                  # Run full integration test
  uis test-all --dry-run                        # Preview test plan
  uis test-all --clean                          # Clean cluster first, then test
  uis test-all --only nginx --clean             # Test only specific services

EOF
}

cmd_list() {
    _uis_cluster_banner
    local show_all=false
    local filter_category=""

    # Parse args
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all|-a) show_all=true; shift ;;
            --category|-c) filter_category="$2"; shift 2 ;;
            *) break ;;
        esac
    done

    print_section "Available Services"

    # Print header
    printf "%-18s %-20s %-12s %s\n" "ID" "NAME" "CATEGORY" "STATUS"
    echo "─────────────────────────────────────────────────────────────────────"

    # Get services grouped by category
    local current_category=""
    local service_id script

    # First, collect all services
    for cat_id in "${CATEGORY_ORDER[@]}"; do
        [[ -n "$filter_category" && "$filter_category" != "$cat_id" ]] && continue

        while IFS= read -r service_id; do
            [[ -z "$service_id" ]] && continue
            script=$(find_service_script "$service_id")
            [[ -z "$script" ]] && continue

            # Load metadata
            unset SCRIPT_ID SCRIPT_NAME SCRIPT_DESCRIPTION SCRIPT_CATEGORY SCRIPT_CHECK_COMMAND
            # shellcheck source=/dev/null
            source "$script" 2>/dev/null

            # Multi-instance services: emit one row per actual deployment,
            # with explicit Deployed / Degraded / Not deployed states.
            #
            # Note: this whole branch runs under `set -e` (uis-cli.sh:9).
            # _classify_ready_count returns 1 for degraded and 2 for unknown;
            # both calls must sit inside `if` conditions so a non-zero return
            # doesn't trip errexit and abort the surrounding loop.
            if _is_service_multi_instance "$service_id" 2>/dev/null; then
                local _mi_lines _dep_name _dep_ready
                _mi_lines=$(get_multi_instance_deployments "$service_id" 2>/dev/null)
                if [[ -z "$_mi_lines" ]]; then
                    # Zero deployments — keep the service-type visible in the
                    # registry so the user knows it exists and is deployable.
                    printf "%-18s %-20s %-12s %s %s\n" \
                        "$SCRIPT_ID" \
                        "${SCRIPT_NAME:0:20}" \
                        "${SCRIPT_CATEGORY:0:12}" \
                        "❌" \
                        "Not deployed"
                else
                    while IFS=$'\t' read -r _dep_name _dep_ready; do
                        [[ -z "$_dep_name" ]] && continue
                        if _classify_ready_count "$_dep_ready"; then
                            printf "%-18s %-20s %-12s %s %s\n" \
                                "$_dep_name" \
                                "${SCRIPT_NAME:0:20}" \
                                "${SCRIPT_CATEGORY:0:12}" \
                                "✅" \
                                "Deployed"
                        else
                            # Degraded or unknown — surface the ready count
                            # so the user can debug.
                            printf "%-18s %-20s %-12s %s %s\n" \
                                "$_dep_name" \
                                "${SCRIPT_NAME:0:20}" \
                                "${SCRIPT_CATEGORY:0:12}" \
                                "⚠" \
                                "Degraded ($_dep_ready)"
                        fi
                    done <<< "$_mi_lines"
                fi
                continue
            fi

            # Single-instance: existing path, unchanged behaviour.
            local status_icon status_text
            if [[ -z "$SCRIPT_CHECK_COMMAND" ]]; then
                status_icon="○"
                status_text="No check"
            elif check_service_deployed "$service_id" 2>/dev/null; then
                status_icon="✅"
                status_text="Deployed"
                # ⚠️ A proxy pod passing its check does NOT mean the data is here.
                # Reporting plain "Deployed" for an externally-provided service is
                # true of the pod and misleading about everything that matters -
                # the same defect as reporting a service Deployed when nothing
                # verified it. Say where the data actually lives.
                if is_external_service "$service_id" 2>/dev/null; then
                    local _x_host _x_port _x_why
                    if read -r _x_host _x_port _x_why < <(external_service_get "$service_id" "${SCRIPT_EXPOSE_PORT:-}" 2>/dev/null); then
                        status_icon="🔗"
                        status_text="External → ${_x_host}:${_x_port}"
                    fi
                fi
            else
                status_icon="❌"
                status_text="Not deployed"
            fi

            # Print row
            printf "%-18s %-20s %-12s %s %s\n" \
                "$SCRIPT_ID" \
                "${SCRIPT_NAME:0:20}" \
                "${SCRIPT_CATEGORY:0:12}" \
                "$status_icon" \
                "$status_text"

        done < <(get_services_by_category "$cat_id")
    done

    echo ""
    echo "Use 'uis deploy <service>' to deploy a service"
    echo "Use 'uis undeploy <service>' to remove a service"
}

cmd_status() {
    _uis_cluster_banner
    print_section "Deployed Services Status"

    # Show current kubectl context (target cluster)
    local current_context
    current_context=$(kubectl config current-context 2>/dev/null) || current_context="unknown"
    echo "Target cluster: $current_context"
    echo ""

    local has_deployed=false
    local service_id script

    printf "%-18s %-20s %-12s %s\n" "ID" "NAME" "CATEGORY" "HEALTH"
    echo "─────────────────────────────────────────────────────────────────────"

    for service_id in $(get_all_service_ids); do
        script=$(find_service_script "$service_id")
        [[ -z "$script" ]] && continue

        # Load metadata
        unset SCRIPT_ID SCRIPT_NAME SCRIPT_CATEGORY SCRIPT_CHECK_COMMAND
        # shellcheck source=/dev/null
        source "$script" 2>/dev/null

        # Multi-instance services: enumerate each deployment as its own row,
        # using the Kubernetes deployment name (<app>-<service>) as the row
        # ID. Only healthy instances are printed — matches single-instance
        # behaviour of "check failed → skip row."
        if _is_service_multi_instance "$service_id" 2>/dev/null; then
            local dep_line dep_name dep_ready
            while IFS=$'\t' read -r dep_name dep_ready; do
                [[ -z "$dep_name" ]] && continue
                if _classify_ready_count "$dep_ready"; then
                    has_deployed=true
                    printf "%-18s %-20s %-12s %s\n" \
                        "$dep_name" \
                        "${SCRIPT_NAME:0:20}" \
                        "${SCRIPT_CATEGORY:0:12}" \
                        "✅ Healthy"
                fi
            done < <(get_multi_instance_deployments "$service_id" 2>/dev/null)
            continue
        fi

        # Single-instance: only show if has check command and is deployed
        if [[ -n "$SCRIPT_CHECK_COMMAND" ]]; then
            if check_service_deployed "$service_id" 2>/dev/null; then
                has_deployed=true
                printf "%-18s %-20s %-12s %s\n" \
                    "$SCRIPT_ID" \
                    "${SCRIPT_NAME:0:20}" \
                    "${SCRIPT_CATEGORY:0:12}" \
                    "✅ Healthy"
            fi
        fi
    done

    if [[ "$has_deployed" != "true" ]]; then
        echo "No deployed services found."
        echo ""
        echo "Use 'uis deploy' to deploy autostart services."
    fi
}

cmd_categories() {
    print_section "Service Categories"
    print_categories_table
}

cmd_deploy() {
    _uis_cluster_banner
    local service_id=""
    local app_name=""
    local url_prefix=""

    # Parse positional + flag args. First positional is service_id.
    # Note: deploy does not accept --schema/--schemas. The schema list lives
    # on the per-app secret (written by configure) and is read by the
    # Deployment template via valueFrom.secretKeyRef.
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --app)         app_name="$2"; shift 2 ;;
            --url-prefix)  url_prefix="$2"; shift 2 ;;
            -*)            log_error "Unknown option: $1"; exit "$EXIT_GENERAL_ERROR" ;;
            *)             [[ -z "$service_id" ]] && service_id="$1"; shift ;;
        esac
    done

    # Initialize if needed
    if ! check_first_run; then
        log_info "First run detected, initializing configuration..."
        initialize_uis_config
    fi

    # Ensure secrets are applied to cluster (idempotent, handles cluster reset)
    ensure_secrets_applied

    if [[ -n "$service_id" ]]; then
        # Check if service exists first
        local script
        script=$(find_service_script "$service_id" 2>/dev/null) || true
        if [[ -z "$script" ]]; then
            log_error "Service '$service_id' not found"
            log_info "Run 'uis list' to see available services"
            exit 1
        fi

        # Multi-instance vs single-instance validation
        if _is_service_multi_instance "$service_id"; then
            if [[ -z "$app_name" ]]; then
                log_error "Service '$service_id' is multi-instance — --app <name> is required"
                log_info "Example: uis deploy $service_id --app atlas" >&2
                exit "$EXIT_GENERAL_ERROR"
            fi
            # Apply per-app defaults (Decision #16/#19 in INVESTIGATE-postgrest.md)
            url_prefix="${url_prefix:-api-$app_name}"
            log_info "Deploying service: $service_id (app: $app_name)"
        else
            if [[ -n "$app_name" || -n "$url_prefix" ]]; then
                log_error "Service '$service_id' is single-instance — --app/--url-prefix not allowed"
                exit "$EXIT_GENERAL_ERROR"
            fi
            log_info "Deploying service: $service_id"
        fi

        # Deploy
        deploy_single_service "$service_id" "$app_name" "$url_prefix"

        # Auto-enable if successful and service-auto-enable is available
        # (Skip for multi-instance: enabled-services.conf is for single-instance autostart only)
        if [[ -z "$app_name" ]] && type enable_service &>/dev/null; then
            if ! is_service_enabled "$service_id"; then
                enable_service "$service_id"
                log_info "Service '$service_id' added to autostart"
            fi
        fi
    else
        # Deploy all enabled services
        if is_using_default_secrets; then
            log_warn "Using built-in defaults for localhost development"
        fi

        deploy_enabled_services
    fi
}

cmd_undeploy() {
    _uis_cluster_banner
    local service_id=""
    local app_name=""
    local purge="false"
    local yes="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --app)   app_name="$2"; shift 2 ;;
            --purge) purge="true"; shift ;;
            --yes|-y) yes="true"; shift ;;
            -*)      log_error "Unknown option: $1"; exit "$EXIT_GENERAL_ERROR" ;;
            *)       [[ -z "$service_id" ]] && service_id="$1"; shift ;;
        esac
    done

    if [[ -z "$service_id" ]]; then
        log_error "Usage: uis undeploy <service> [--app <name>] [--purge] [--yes]"
        exit 1
    fi

    # Check if service exists
    local script
    script=$(find_service_script "$service_id" 2>/dev/null) || true
    if [[ -z "$script" ]]; then
        log_error "Service '$service_id' not found"
        log_info "Run 'uis list' to see available services"
        exit 1
    fi

    # Multi-instance vs single-instance validation
    if _is_service_multi_instance "$service_id"; then
        if [[ -z "$app_name" ]]; then
            log_error "Service '$service_id' is multi-instance — --app <name> is required"
            log_info "Example: uis undeploy $service_id --app atlas" >&2
            exit "$EXIT_GENERAL_ERROR"
        fi
    else
        if [[ -n "$app_name" ]]; then
            log_error "Service '$service_id' is single-instance — --app not allowed"
            exit "$EXIT_GENERAL_ERROR"
        fi
    fi

    # Confirmation prompt for --purge (skipped with --yes or non-TTY stdin)
    if [[ "$purge" == "true" && "$yes" != "true" ]]; then
        if [[ -t 0 ]]; then
            log_warn "--purge will delete persistent state for '$service_id' (databases, roles, secrets, PVCs, namespace)."
            log_warn "This is irreversible. Run with --yes to skip this prompt."
            printf "Type 'yes' to continue: "
            local reply
            read -r reply
            if [[ "$reply" != "yes" ]]; then
                log_info "Aborted."
                exit 0
            fi
        else
            log_error "--purge requires interactive confirmation or --yes; stdin is not a TTY"
            exit "$EXIT_GENERAL_ERROR"
        fi
    fi

    # Remove from kubernetes
    remove_single_service "$service_id" "$app_name" "$purge"
}

cmd_enable() {
    local service_id="${1:-}"

    if [[ -z "$service_id" ]]; then
        log_error "Usage: uis enable <service>"
        exit "$EXIT_GENERAL_ERROR"
    fi

    # Check if service exists
    local script
    script=$(find_service_script "$service_id")
    if [[ -z "$script" ]]; then
        log_error "Service '$service_id' not found"
        log_info "Run 'uis list' to see available services"
        exit "$EXIT_CONFIG_ERROR"
    fi

    if ! type enable_service &>/dev/null; then
        log_error "service-auto-enable.sh not loaded"
        exit "$EXIT_GENERAL_ERROR"
    fi

    enable_service "$service_id"
}

cmd_disable() {
    local service_id="${1:-}"

    if [[ -z "$service_id" ]]; then
        log_error "Usage: uis disable <service>"
        exit "$EXIT_GENERAL_ERROR"
    fi

    if ! type disable_service &>/dev/null; then
        log_error "service-auto-enable.sh not loaded"
        exit "$EXIT_GENERAL_ERROR"
    fi

    disable_service "$service_id"
}

cmd_list_enabled() {
    print_section "Enabled Services"

    local count=0
    local service_id script

    printf "%-15s %-25s %s\n" "ID" "NAME" "DEPLOYED"
    echo "──────────────────────────────────────────────────────"

    while IFS= read -r service_id; do
        [[ -z "$service_id" ]] && continue
        ((++count))

        script=$(find_service_script "$service_id")
        local name="$service_id"
        local deployed="?"

        if [[ -n "$script" ]]; then
            unset SCRIPT_NAME SCRIPT_CHECK_COMMAND
            # shellcheck source=/dev/null
            source "$script" 2>/dev/null
            name="${SCRIPT_NAME:-$service_id}"

            if [[ -n "$SCRIPT_CHECK_COMMAND" ]]; then
                if check_service_deployed "$service_id" 2>/dev/null; then
                    deployed="✅ Yes"
                else
                    deployed="❌ No"
                fi
            else
                deployed="○ No check"
            fi
        else
            deployed="⚠️  Not found"
        fi

        printf "%-15s %-25s %s\n" "$service_id" "${name:0:25}" "$deployed"
    done < <(list_enabled_services)

    echo ""
    if [[ $count -eq 0 ]]; then
        echo "No services in autostart."
        echo "Use 'uis enable <service>' to enable a service."
    else
        echo "$count service(s) in autostart"
        echo "Use 'uis deploy' to deploy all autostart services"
    fi
}

cmd_sync() {
    print_section "Syncing Enabled Services"

    # Initialize if needed
    if ! check_first_run; then
        log_info "First run detected, initializing configuration..."
        initialize_uis_config
    fi

    local synced=0
    local already_enabled=0
    local service_id script

    echo "Checking deployed services..."
    echo ""

    for service_id in $(get_all_service_ids); do
        script=$(find_service_script "$service_id")
        [[ -z "$script" ]] && continue

        # Load metadata
        unset SCRIPT_ID SCRIPT_NAME SCRIPT_CHECK_COMMAND
        # shellcheck source=/dev/null
        source "$script" 2>/dev/null

        # Skip if no check command
        [[ -z "$SCRIPT_CHECK_COMMAND" ]] && continue

        # Check if deployed
        if check_service_deployed "$service_id" 2>/dev/null; then
            # Check if already enabled
            if is_service_enabled "$service_id" 2>/dev/null; then
                ((++already_enabled))
            else
                # Enable it
                enable_service "$service_id"
                log_success "Synced: $service_id (${SCRIPT_NAME:-$service_id})"
                ((++synced))
            fi
        fi
    done

    echo ""
    if [[ $synced -eq 0 ]]; then
        log_info "No new services to sync"
        log_info "$already_enabled service(s) already in autostart"
    else
        log_success "Added $synced service(s) to autostart"
        log_info "$already_enabled service(s) were already in autostart"
    fi
}

# ============================================================
# Tools Commands
# ============================================================

cmd_tools() {
    local subcmd="${1:-list}"
    shift || true

    case "$subcmd" in
        list|ls)
            cmd_tools_list
            ;;
        install)
            cmd_tools_install "$@"
            ;;
        *)
            log_error "Unknown tools subcommand: $subcmd"
            echo "Usage: uis tools [list|install <tool>]"
            exit "$EXIT_GENERAL_ERROR"
            ;;
    esac
}

cmd_tools_list() {
    print_section "Available Tools"

    if ! type list_tools &>/dev/null; then
        log_error "tool-installation.sh not loaded"
        exit "$EXIT_GENERAL_ERROR"
    fi

    list_tools
}

cmd_tools_install() {
    local tool_id="${1:-}"

    if [[ -z "$tool_id" ]]; then
        log_error "Usage: uis tools install <tool>"
        exit "$EXIT_GENERAL_ERROR"
    fi

    if ! type install_tool &>/dev/null; then
        log_error "tool-installation.sh not loaded"
        exit "$EXIT_GENERAL_ERROR"
    fi

    install_tool "$tool_id"
}

# ============================================================
# Stack Commands
# ============================================================

cmd_stack() {
    local subcmd="${1:-list}"
    shift || true

    case "$subcmd" in
        list|ls)
            cmd_stack_list
            ;;
        info)
            cmd_stack_info "$@"
            ;;
        install)
            cmd_stack_install "$@"
            ;;
        remove|rm)
            cmd_stack_remove "$@"
            ;;
        *)
            log_error "Unknown stack subcommand: $subcmd"
            echo "Usage: uis stack [list|info|install|remove] <stack>"
            exit "$EXIT_GENERAL_ERROR"
            ;;
    esac
}

cmd_stack_list() {
    print_section "Available Service Stacks"
    print_stacks_table
    echo ""
    echo "Use 'uis stack info <stack>' for details"
    echo "Use 'uis stack install <stack>' to install all services in a stack"
}

cmd_stack_info() {
    local stack_id="${1:-}"

    if [[ -z "$stack_id" ]]; then
        log_error "Usage: uis stack info <stack>"
        exit "$EXIT_GENERAL_ERROR"
    fi

    print_stack_info "$stack_id"
}

cmd_stack_install() {
    _uis_cluster_banner
    # C-4 — children (./uis deploy <service> fired by the stack walker) MUST
    # NOT re-print the banner. Set the env var the helper reads.
    export UIS_BANNER_PRINTED=1
    local stack_id="${1:-}"
    local skip_optional=false

    # Parse args
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --skip-optional) skip_optional=true; shift ;;
            -*) log_error "Unknown option: $1"; exit "$EXIT_GENERAL_ERROR" ;;
            *) stack_id="$1"; shift ;;
        esac
    done

    if [[ -z "$stack_id" ]]; then
        log_error "Usage: uis stack install <stack> [--skip-optional]"
        exit "$EXIT_GENERAL_ERROR"
    fi

    if ! is_valid_stack "$stack_id"; then
        log_error "Unknown stack: $stack_id"
        log_info "Run 'uis stack list' to see available stacks"
        exit "$EXIT_CONFIG_ERROR"
    fi

    local stack_name
    stack_name=$(get_stack_name "$stack_id")
    print_section "Installing Stack: $stack_name"

    # Get services list
    local services optional
    services=$(get_stack_services_list "$stack_id")
    optional=$(get_stack_optional_services "$stack_id")

    log_info "Services to install:"
    local pos=1
    for service in $services; do
        local marker=""
        if is_optional_service "$stack_id" "$service"; then
            if [[ "$skip_optional" == "true" ]]; then
                marker=" (optional - SKIPPING)"
            else
                marker=" (optional)"
            fi
        fi
        echo "  $pos. $service$marker"
        ((++pos))
    done
    echo ""

    # Install each service in order
    local failed_services=""
    for service in $services; do
        # Skip optional services if requested
        if [[ "$skip_optional" == "true" ]] && is_optional_service "$stack_id" "$service"; then
            log_info "Skipping optional service: $service"
            continue
        fi

        log_info "Installing service: $service"

        # Check if service exists
        local script
        script=$(find_service_script "$service")
        if [[ -z "$script" ]]; then
            log_warn "Service '$service' not found, skipping"
            failed_services="$failed_services $service"
            continue
        fi

        # Deploy the service
        if deploy_single_service "$service"; then
            # Auto-enable
            if type enable_service &>/dev/null && ! is_service_enabled "$service" 2>/dev/null; then
                enable_service "$service" 2>/dev/null || true
            fi
        else
            log_warn "Failed to deploy $service"
            failed_services="$failed_services $service"
        fi
    done

    echo ""
    if [[ -z "$failed_services" ]]; then
        log_success "Stack '$stack_name' installed successfully"
    else
        log_warn "Stack '$stack_name' installed with warnings"
        log_warn "Failed services:$failed_services"
    fi
}

cmd_stack_remove() {
    local stack_id="${1:-}"

    if [[ -z "$stack_id" ]]; then
        log_error "Usage: uis stack remove <stack>"
        exit "$EXIT_GENERAL_ERROR"
    fi

    if ! is_valid_stack "$stack_id"; then
        log_error "Unknown stack: $stack_id"
        log_info "Run 'uis stack list' to see available stacks"
        exit "$EXIT_CONFIG_ERROR"
    fi

    local stack_name
    stack_name=$(get_stack_name "$stack_id")
    print_section "Removing Stack: $stack_name"

    # Get services list (reverse order for removal)
    local services
    services=$(get_stack_services_list "$stack_id")

    # Reverse the list for removal (last installed = first removed)
    local reversed=""
    for service in $services; do
        reversed="$service $reversed"
    done

    log_info "Services to remove (reverse order):"
    for service in $reversed; do
        echo "  - $service"
    done
    echo ""

    # Remove each service
    local failed_services=""
    for service in $reversed; do
        log_info "Removing service: $service"

        local script
        script=$(find_service_script "$service")
        if [[ -z "$script" ]]; then
            log_warn "Service '$service' not found, skipping"
            continue
        fi

        if remove_single_service "$service"; then
            # Auto-disable
            if type disable_service &>/dev/null && is_service_enabled "$service" 2>/dev/null; then
                disable_service "$service" 2>/dev/null || true
            fi
        else
            log_warn "Failed to remove $service"
            failed_services="$failed_services $service"
        fi
    done

    echo ""
    if [[ -z "$failed_services" ]]; then
        log_success "Stack '$stack_name' removed successfully"
    else
        log_warn "Stack '$stack_name' removed with warnings"
        log_warn "Failed to remove:$failed_services"
    fi
}

cmd_stacks() {
    cmd_stack_list
}

# ============================================================
# Platform Commands
# ============================================================
# `uis platform <subcmd> <provider>` — per-cloud lifecycle wrappers.
# Q8 of INVESTIGATE-platform-aks-novice-onboarding.md: thin dispatcher here delegates
# to platforms/<provider>/scripts/<verb>.sh; the per-platform script in turn
# sources shared helpers from provision-host/uis/lib/<cloud>-discovery.sh.
# init is implemented (PLAN #2); up + down land in PLANs #3 + #4.

cmd_platform() {
    local subcmd="${1:-}"
    shift || true

    case "$subcmd" in
        init)
            cmd_platform_init "$@"
            ;;
        list)
            cmd_platform_list "$@"
            ;;
        up)
            cmd_platform_up "$@"
            ;;
        status)
            cmd_platform_status "$@"
            ;;
        use)
            cmd_platform_use "$@"
            ;;
        down)
            cmd_platform_down "$@"
            ;;
        "")
            log_error "Usage: uis platform <subcmd> [<provider>]"
            echo "Subcommands: init | list | up | status | use | down" >&2
            exit "$EXIT_GENERAL_ERROR"
            ;;
        *)
            log_error "Unknown platform subcommand: $subcmd"
            echo "Usage: uis platform [init|list|up|status|use|down] [<provider>]" >&2
            exit "$EXIT_GENERAL_ERROR"
            ;;
    esac
}

# Internal helper: emit the Layer 1 platform banner to stderr and abort on
# unreachable / unset-context cases (per C-9 of INVESTIGATE-active-cluster-
# visibility-ux.md). Called at the top of every cluster-touching cmd_<verb>
# function. Honors UIS_BANNER_PRINTED=1 (set by parent invocations like
# cmd_stack_install before fanning out to child deploys, per C-4).
#
# Defensive against pf_banner being unavailable (platform-switching.sh failed
# to source, e.g. during early-init harness runs) — silently no-ops in that
# case so cluster-touching commands still work.
#
# Also no-ops when there's no kubectl or no kubeconf-all file at all — that's
# the host-side test harness running uis-cli.sh on ubuntu-latest CI, not a
# real cluster-touching context. In the container these always exist.
_uis_cluster_banner() {
    type pf_banner >/dev/null 2>&1 || return 0
    command -v kubectl >/dev/null 2>&1 || return 0
    # F15 — seed kubeconf-all from /home/ansible/.kube/config on first run so
    # the existence guard below doesn't no-op on a fresh container that DOES
    # have rancher-desktop reachable.
    type pf_ensure_kubeconf_seeded >/dev/null 2>&1 && pf_ensure_kubeconf_seeded
    [[ -f "${PF_KUBECONFIG:-/mnt/urbalurbadisk/kubeconfig/kubeconf-all}" ]] || return 0
    pf_banner --silent-if-set --check-reachable || exit "$EXIT_GENERAL_ERROR"
}

# Internal helper: list platforms that have a given script name under
# platforms/*/scripts/. Used by cmd_platform_init (looks for init.sh) and
# cmd_platform_up (looks for up.sh). Writes to stdout; callers redirect to
# stderr if pairing with log_error to avoid stream-interleave ordering.
_list_available_platforms_with_script() {
    local target_script="$1"
    local repo_root="$2"
    echo "Available platforms:"
    local p script_path
    for script_path in "$repo_root"/platforms/*/scripts/"$target_script"; do
        [[ -f "$script_path" ]] || continue
        p=$(basename "$(dirname "$(dirname "$script_path")")")
        echo "  - $p"
    done
}

cmd_platform_init() {
    local provider="${1:-}"
    local repo_root
    repo_root="$(cd "$SCRIPT_DIR/../../.." && pwd)"

    if [[ -z "$provider" ]]; then
        log_error "Usage: uis platform init <provider>"
        { _list_available_platforms_with_script init.sh "$repo_root"; } >&2
        exit "$EXIT_GENERAL_ERROR"
    fi

    local script="$repo_root/platforms/$provider/scripts/init.sh"
    if [[ ! -f "$script" ]]; then
        log_error "Unknown platform '$provider' (no init.sh found at $script)"
        { _list_available_platforms_with_script init.sh "$repo_root"; } >&2
        exit "$EXIT_GENERAL_ERROR"
    fi

    # Pass the repo root explicitly so the per-platform init.sh doesn't have
    # to re-derive it. Then exec — replaces the current process so signals
    # (Ctrl-C during interactive prompts) flow directly to the wizard.
    export UIS_REPO_ROOT="$repo_root"
    exec "$script"
}

# cmd_platform_up — same shape as cmd_platform_init but dispatches to up.sh.
# The per-platform up.sh handles env-file presence (Q11 refuse-with-pointer)
# and chains the lifecycle scripts.
cmd_platform_up() {
    # No banner — `up` takes an explicit <provider>, doesn't act on the current
    # kubectl context. Showing the active platform before a `up azure-aks`
    # invocation would be misleading (the active might be rancher-desktop;
    # `up` is going to change it).
    local provider="${1:-}"
    local repo_root
    repo_root="$(cd "$SCRIPT_DIR/../../.." && pwd)"

    if [[ -z "$provider" ]]; then
        log_error "Usage: uis platform up <provider>"
        { _list_available_platforms_with_script up.sh "$repo_root"; } >&2
        exit "$EXIT_GENERAL_ERROR"
    fi

    local script="$repo_root/platforms/$provider/scripts/up.sh"
    if [[ ! -f "$script" ]]; then
        log_error "Platform '$provider' has no up.sh (looked at $script)"
        { _list_available_platforms_with_script up.sh "$repo_root"; } >&2
        exit "$EXIT_GENERAL_ERROR"
    fi

    export UIS_REPO_ROOT="$repo_root"
    exec "$script"
}

# cmd_platform_down — same shape as cmd_platform_up but dispatches to down.sh.
# The per-platform down.sh delegates to 03-destroy.sh (which owns the typed-name
# confirmation prompt + UIS_DESTROY_CONFIRM env-var escape hatch), then prints
# the config-preservation pointer per Q12.
cmd_platform_down() {
    # No banner — explicit <provider>, doesn't act on current kubectl context.
    local provider="${1:-}"
    local repo_root
    repo_root="$(cd "$SCRIPT_DIR/../../.." && pwd)"

    if [[ -z "$provider" ]]; then
        log_error "Usage: uis platform down <provider>"
        { _list_available_platforms_with_script down.sh "$repo_root"; } >&2
        exit "$EXIT_GENERAL_ERROR"
    fi

    local script="$repo_root/platforms/$provider/scripts/down.sh"
    if [[ ! -f "$script" ]]; then
        log_error "Platform '$provider' has no down.sh (looked at $script)"
        { _list_available_platforms_with_script down.sh "$repo_root"; } >&2
        exit "$EXIT_GENERAL_ERROR"
    fi

    export UIS_REPO_ROOT="$repo_root"
    exec "$script"
}

# cmd_platform_status — same shape as cmd_platform_up/down. The per-platform
# status.sh answers "is the cluster running and how much is it costing me?"
# in a single command (F8 from talk45).
cmd_platform_status() {
    # No banner — explicit <provider>, this command reports on the named
    # platform regardless of which is currently active.
    local provider="${1:-}"
    local repo_root
    repo_root="$(cd "$SCRIPT_DIR/../../.." && pwd)"

    if [[ -z "$provider" ]]; then
        log_error "Usage: uis platform status <provider>"
        { _list_available_platforms_with_script status.sh "$repo_root"; } >&2
        exit "$EXIT_GENERAL_ERROR"
    fi

    local script="$repo_root/platforms/$provider/scripts/status.sh"
    if [[ ! -f "$script" ]]; then
        log_error "Platform '$provider' has no status.sh (looked at $script)"
        { _list_available_platforms_with_script status.sh "$repo_root"; } >&2
        exit "$EXIT_GENERAL_ERROR"
    fi

    export UIS_REPO_ROOT="$repo_root"
    exec "$script"
}

# cmd_platform_list — enumerate potential platforms + their states.
# Implements Layer 4 of INVESTIGATE-active-cluster-visibility-ux.md.
# Inventory: pf_list_platforms (platforms/*/scripts/init.sh dirs + rancher-desktop).
# Per-row status: each platform's status.sh --summary (C-1 contract) called in
# parallel for the under-500ms budget (C-6).
cmd_platform_list() {
    # No banner — `list` IS the discovery command, expected to work even when
    # no active context is set (helps the user find a platform to switch to).
    # shellcheck source=/dev/null
    source "/mnt/urbalurbadisk/provision-host/uis/lib/platform-switching.sh"

    # Flag parsing — --offline / --deep mirror status.sh --summary's modes.
    local offline=0 deep=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --offline) offline=1; shift ;;
            --deep)    deep=1;    shift ;;
            *) shift ;;
        esac
    done
    local summary_args=()
    (( offline )) && summary_args+=("--offline")
    (( deep ))    && summary_args+=("--deep")

    # Header — `Active: <name>` per C-2 (three cases for kubectl current-context).
    local active is_uis_platform=0
    active="$(pf_active_platform)"
    if [[ -z "$active" ]]; then
        echo "Active: (none — run './uis platform use <name>' to pick one)"
    else
        if [[ "$active" == "rancher-desktop" ]] || \
           [[ -f "/mnt/urbalurbadisk/platforms/$active/scripts/init.sh" ]]; then
            is_uis_platform=1
            echo "Active: $active"
        else
            echo "Active: $active (not a UIS platform — use './uis platform use <name>' to switch to one)"
        fi
    fi
    echo

    # Gather summaries in parallel — one background process per platform,
    # output collected into a tmpdir then read in inventory order. Keeps the
    # default `list` under 500ms with up to ~8 platforms (C-6).
    local tmpdir
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' RETURN
    local platforms=() pf
    while IFS= read -r pf; do
        platforms+=("$pf")
    done < <(pf_list_platforms)
    local pid
    for pf in "${platforms[@]}"; do
        ( pf_platform_summary "$pf" "${summary_args[@]}" 2>/dev/null > "$tmpdir/$pf" ) &
    done
    wait

    # Compute max platform-name width for table alignment.
    local maxw=0 w
    for pf in "${platforms[@]}"; do
        w=${#pf}
        (( w > maxw )) && maxw=$w
    done
    (( maxw < 16 )) && maxw=16

    printf "%-${maxw}s  %s\n" "PLATFORM" "STATUS"
    local row_state row_hint icon state_label
    for pf in "${platforms[@]}"; do
        if [[ ! -s "$tmpdir/$pf" ]]; then
            printf "%-${maxw}s  ? error                       (status.sh --summary failed; run './uis platform status %s' for details)\n" "$pf" "$pf"
            continue
        fi
        # tab-separated <state>\t<hint>
        IFS=$'\t' read -r row_state row_hint < "$tmpdir/$pf"
        case "$row_state" in
            running)
                icon="✓"
                state_label="running"
                ;;
            configured-not-running)
                icon="·"
                state_label="configured, not running"
                ;;
            not-initialized)
                icon="·"
                state_label="not initialized"
                ;;
            unreachable)
                icon="✗"
                state_label="unreachable"
                ;;
            *)
                icon="?"
                state_label="$row_state"
                ;;
        esac
        # Active annotation if this row matches the kubectl current-context (only
        # when active is a UIS platform; per C-2 external/unset contexts don't
        # decorate any row).
        local active_tag=""
        if (( is_uis_platform )) && [[ "$pf" == "$active" ]]; then
            active_tag="  (active)"
        fi
        # Display hint: for running rows, the hint is descriptive; for non-running
        # rows, prefix with "run '...' " — but the status.sh already emits the
        # right text in field 2 per C-1, so we just print it.
        if [[ "$row_state" == "running" ]]; then
            printf "%-${maxw}s  %s %s%s    %s\n" \
                "$pf" "$icon" "$state_label" "$active_tag" "$row_hint"
        else
            printf "%-${maxw}s  %s %-23s  (%s)\n" \
                "$pf" "$icon" "$state_label" "$row_hint"
        fi
    done
}

# cmd_platform_use — switch the active platform with lockstep flip.
# Implements Q4 (lockstep) + Q5 (refuse-unless-initialized-and-reachable).
# State decision via pf_platform_summary (the C-1 contract); flip via
# pf_lockstep_flip (the shared writer 02-post-apply.sh + 03-destroy.sh
# converge on after Phase 6).
cmd_platform_use() {
    # No banner — `use` is the *fix* for the "no active context" abort path
    # that fires on cluster-touching commands. Banner-then-abort here would
    # be catch-22.
    # shellcheck source=/dev/null
    source "/mnt/urbalurbadisk/provision-host/uis/lib/platform-switching.sh"

    local force_offline=0 target=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --offline) force_offline=1; shift ;;
            -*)        shift ;;  # ignore unknown flags
            *)         target="$1"; shift ;;
        esac
    done

    # No arg → interactive picker over the running rows.
    if [[ -z "$target" ]]; then
        _cmd_platform_use_picker
        return
    fi

    # Validate that the platform exists (special-case rancher-desktop).
    if [[ "$target" != "rancher-desktop" ]] && \
       [[ ! -f "/mnt/urbalurbadisk/platforms/$target/scripts/init.sh" ]]; then
        log_error "Unknown platform '$target' (no init.sh found at /mnt/urbalurbadisk/platforms/$target/scripts/init.sh)"
        { _list_available_platforms_with_script init.sh "/mnt/urbalurbadisk"; } >&2
        echo "  - rancher-desktop" >&2  # not in the init.sh enumeration; mention explicitly
        exit "$EXIT_GENERAL_ERROR"
    fi

    # Ask status.sh --summary what state the target is in.
    local summary state hint
    if ! summary="$(pf_platform_summary "$target")"; then
        log_error "Could not query status for '$target' (status.sh --summary errored or emitted invalid output)"
        echo "  Try: ./uis platform status $target" >&2
        exit "$EXIT_GENERAL_ERROR"
    fi
    state="${summary%%	*}"
    hint="${summary#*	}"

    # Capture current active for the success-line "from → to" wording.
    local previous
    previous="$(pf_active_platform)"

    case "$state" in
        not-initialized)
            # Use the hint from status.sh --summary verbatim — the per-platform
            # script knows what action is needed. Rancher-desktop's hint says
            # "install Rancher Desktop and start it" (no `platform init` exists
            # for it), while azure-aks's would say "run './uis platform init …'".
            echo "✗ $target is not initialized." >&2
            echo "  $hint" >&2
            exit "$EXIT_GENERAL_ERROR"
            ;;
        configured-not-running)
            echo "✗ $target is configured but not running." >&2
            echo "  $hint" >&2
            exit "$EXIT_GENERAL_ERROR"
            ;;
        running)
            # Already active? No-op + re-probe (per C-8 / Q5 no-op semantics).
            if [[ "$previous" == "$target" ]]; then
                if pf_probe_reachable "$target"; then
                    echo "ℹ  Already active: $target. Re-probing... ✓ still reachable."
                    exit 0
                else
                    echo "✗ $target is no longer reachable (API server timeout after 3s)." >&2
                    echo "  Check the cluster state with './uis platform status $target'." >&2
                    exit "$EXIT_GENERAL_ERROR"
                fi
            fi
            pf_lockstep_flip "$target"
            if [[ -n "$previous" ]]; then
                echo "✓ Switched: $previous → $target"
            else
                echo "✓ Switched to: $target"
            fi
            exit 0
            ;;
        unreachable)
            if (( force_offline )); then
                # User explicitly opted in to switching despite unreachable.
                pf_lockstep_flip "$target"
                if [[ -n "$previous" ]]; then
                    echo "✓ Switched: $previous → $target  (forced; cluster not reachable)"
                else
                    echo "✓ Switched to: $target  (forced; cluster not reachable)"
                fi
                exit 0
            fi
            echo "✗ $target is unreachable (API server timeout after 3s)." >&2
            echo "  Check the cluster state with './uis platform status $target'." >&2
            echo "  To switch anyway (e.g. to clean up stale kubectl state), use --offline." >&2
            exit "$EXIT_GENERAL_ERROR"
            ;;
        *)
            log_error "Unexpected state '$state' from $target's status.sh --summary"
            exit "$EXIT_GENERAL_ERROR"
            ;;
    esac
}

# Interactive picker for `./uis platform use` with no argument.
# Per C-8: only running rows get [N] selectors; non-selectable rows appear
# without selectors with their inline pointer. Plain read -p; no fzf dep.
_cmd_platform_use_picker() {
    # shellcheck source=/dev/null
    source "/mnt/urbalurbadisk/provision-host/uis/lib/platform-switching.sh"

    local platforms=() pf
    while IFS= read -r pf; do
        platforms+=("$pf")
    done < <(pf_list_platforms)

    # Gather summaries (sequential is fine for the picker; the user is going
    # to type a number anyway, the parallel optimization isn't load-bearing).
    local active selectable=() pf_state pf_hint summary
    active="$(pf_active_platform)"

    local maxw=0 w
    for pf in "${platforms[@]}"; do
        w=${#pf}; (( w > maxw )) && maxw=$w
    done
    (( maxw < 16 )) && maxw=16

    echo
    printf "%-4s %-${maxw}s  %s\n" " " "PLATFORM" "STATUS"
    local idx=1
    for pf in "${platforms[@]}"; do
        if summary="$(pf_platform_summary "$pf" 2>/dev/null)"; then
            pf_state="${summary%%	*}"
            pf_hint="${summary#*	}"
        else
            pf_state="error"
            pf_hint="status.sh --summary failed"
        fi
        local active_tag=""
        [[ "$pf" == "$active" ]] && active_tag="  (currently active)"
        if [[ "$pf_state" == "running" ]]; then
            printf "[%d] %-${maxw}s  ✓ running%s    %s\n" "$idx" "$pf" "$active_tag" "$pf_hint"
            selectable+=("$pf")
            ((++idx))
        else
            local icon state_label
            case "$pf_state" in
                configured-not-running) icon="·"; state_label="configured, not running" ;;
                not-initialized)        icon="·"; state_label="not initialized" ;;
                unreachable)            icon="✗"; state_label="unreachable" ;;
                *)                      icon="?"; state_label="$pf_state" ;;
            esac
            printf "    %-${maxw}s  %s %-23s  (%s)\n" "$pf" "$icon" "$state_label" "$pf_hint"
        fi
    done
    echo

    if [[ "${#selectable[@]}" -eq 0 ]]; then
        echo "✗ No platforms are currently in 'running' state." >&2
        echo "  Bring one up with './uis platform up <name>' (see hints above)." >&2
        exit "$EXIT_GENERAL_ERROR"
    fi

    local choice
    read -rp "Pick a platform [1-${#selectable[@]}]: " choice
    # Validate
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 )) || (( choice > ${#selectable[@]} )); then
        log_error "Invalid selection: '$choice'"
        exit "$EXIT_GENERAL_ERROR"
    fi
    local picked="${selectable[$((choice-1))]}"
    # Re-dispatch through the named path so the no-op/lockstep logic runs there.
    cmd_platform_use "$picked"
}

# ============================================================
# Network Commands  —  uis network <verb> <provider>
# ============================================================
#
# Mirror of cmd_platform_* shape. Each verb dispatches to a per-provider script
# under networking/<provider>/scripts/<verb>.sh. Only cloudflare is registered
# this round; tailscale port is deferred to INVESTIGATE-tailscale-architecture-
# cleanup.md.

cmd_network() {
    local subcmd="${1:-}"
    shift || true

    case "$subcmd" in
        init)      cmd_network_init "$@" ;;
        list)      cmd_network_list "$@" ;;
        up)        cmd_network_up "$@" ;;
        status)    cmd_network_status "$@" ;;
        down)      cmd_network_down "$@" ;;
        verify)    cmd_network_verify "$@" ;;
        expose)    cmd_network_expose "$@" ;;
        unexpose)  cmd_network_unexpose "$@" ;;
        "")
            log_error "Usage: uis network <subcmd> [<provider>]"
            echo "Subcommands: init | list | up | status | down | verify | expose | unexpose" >&2
            exit "$EXIT_GENERAL_ERROR"
            ;;
        *)
            log_error "Unknown network subcommand: $subcmd"
            echo "Usage: uis network [init|list|up|status|down|verify|expose|unexpose] [<provider>]" >&2
            exit "$EXIT_GENERAL_ERROR"
            ;;
    esac
}

# Internal helper: list networking providers that have a given script name
# under networking/*/scripts/. Mirrors _list_available_platforms_with_script.
_list_available_network_providers_with_script() {
    local target_script="$1"
    local repo_root="$2"
    echo "Available providers:"
    local p script_path
    for script_path in "$repo_root"/networking/*/scripts/"$target_script"; do
        [[ -f "$script_path" ]] || continue
        p=$(basename "$(dirname "$(dirname "$script_path")")")
        # Skip the legacy/ directory if it ever grows a scripts/ subdir.
        case "$p" in
            legacy|_*|.*) continue ;;
        esac
        echo "  - $p"
    done
}

# cmd_network_init — interactive wizard for a networking provider.
# No banner — `init` writes a local env file; doesn't touch the cluster.
cmd_network_init() {
    local provider="${1:-}"
    shift || true
    local repo_root
    repo_root="$(cd "$SCRIPT_DIR/../../.." && pwd)"

    if [[ -z "$provider" ]]; then
        log_error "Usage: uis network init <provider>"
        { _list_available_network_providers_with_script init.sh "$repo_root"; } >&2
        exit "$EXIT_GENERAL_ERROR"
    fi

    local script="$repo_root/networking/$provider/scripts/init.sh"
    if [[ ! -f "$script" ]]; then
        log_error "Unknown network provider '$provider' (no init.sh found at $script)"
        { _list_available_network_providers_with_script init.sh "$repo_root"; } >&2
        exit "$EXIT_GENERAL_ERROR"
    fi

    export UIS_REPO_ROOT="$repo_root"
    exec "$script" "$@"
}

# cmd_network_up — provision the provider into the active cluster.
# Banner fires — `up` deploys to whatever the active platform is, so the user
# should see which cluster the cloudflared pod (or future tailscale operator)
# is landing on.
cmd_network_up() {
    _uis_cluster_banner
    local provider="${1:-}"
    shift || true
    local repo_root
    repo_root="$(cd "$SCRIPT_DIR/../../.." && pwd)"

    if [[ -z "$provider" ]]; then
        log_error "Usage: uis network up <provider>"
        { _list_available_network_providers_with_script up.sh "$repo_root"; } >&2
        exit "$EXIT_GENERAL_ERROR"
    fi

    local script="$repo_root/networking/$provider/scripts/up.sh"
    if [[ ! -f "$script" ]]; then
        log_error "Network provider '$provider' has no up.sh (looked at $script)"
        { _list_available_network_providers_with_script up.sh "$repo_root"; } >&2
        exit "$EXIT_GENERAL_ERROR"
    fi

    export UIS_REPO_ROOT="$repo_root"
    exec "$script" "$@"
}

# cmd_network_down — remove the provider's cluster footprint.
# Banner fires — `down` operates on whatever cluster the deployment is on.
cmd_network_down() {
    _uis_cluster_banner
    local provider="${1:-}"
    shift || true
    local repo_root
    repo_root="$(cd "$SCRIPT_DIR/../../.." && pwd)"

    if [[ -z "$provider" ]]; then
        log_error "Usage: uis network down <provider>"
        { _list_available_network_providers_with_script down.sh "$repo_root"; } >&2
        exit "$EXIT_GENERAL_ERROR"
    fi

    local script="$repo_root/networking/$provider/scripts/down.sh"
    if [[ ! -f "$script" ]]; then
        log_error "Network provider '$provider' has no down.sh (looked at $script)"
        { _list_available_network_providers_with_script down.sh "$repo_root"; } >&2
        exit "$EXIT_GENERAL_ERROR"
    fi

    export UIS_REPO_ROOT="$repo_root"
    exec "$script" "$@"
}

# cmd_network_status — show provider state, tunnel/route state, pod health.
# No banner — status reports on the named provider regardless of which platform
# is active (same reasoning as cmd_platform_status: explicit <provider> arg).
cmd_network_status() {
    local provider="${1:-}"
    local repo_root
    repo_root="$(cd "$SCRIPT_DIR/../../.." && pwd)"

    if [[ -z "$provider" ]]; then
        log_error "Usage: uis network status <provider>"
        { _list_available_network_providers_with_script status.sh "$repo_root"; } >&2
        exit "$EXIT_GENERAL_ERROR"
    fi

    local script="$repo_root/networking/$provider/scripts/status.sh"
    if [[ ! -f "$script" ]]; then
        log_error "Network provider '$provider' has no status.sh (looked at $script)"
        { _list_available_network_providers_with_script status.sh "$repo_root"; } >&2
        exit "$EXIT_GENERAL_ERROR"
    fi

    export UIS_REPO_ROOT="$repo_root"
    exec "$script" "$@"
}

# cmd_network_verify — diagnostics. Banner fires — verify runs against a real
# cluster and a real Cloudflare/Tailscale account; users should see which one.
cmd_network_verify() {
    _uis_cluster_banner
    local provider="${1:-}"
    shift || true
    local repo_root
    repo_root="$(cd "$SCRIPT_DIR/../../.." && pwd)"

    if [[ -z "$provider" ]]; then
        log_error "Usage: uis network verify <provider>"
        { _list_available_network_providers_with_script verify.sh "$repo_root"; } >&2
        exit "$EXIT_GENERAL_ERROR"
    fi

    local script="$repo_root/networking/$provider/scripts/verify.sh"
    if [[ ! -f "$script" ]]; then
        log_error "Network provider '$provider' has no verify.sh (looked at $script)"
        { _list_available_network_providers_with_script verify.sh "$repo_root"; } >&2
        exit "$EXIT_GENERAL_ERROR"
    fi

    export UIS_REPO_ROOT="$repo_root"
    exec "$script" "$@"
}

# cmd_network_expose — per-service Funnel exposure. Tailscale-specific; the
# Cloudflare path uses cluster-wide HostRegexp routing so per-service expose
# isn't a meaningful concept there.
cmd_network_expose() {
    _uis_cluster_banner
    local provider="${1:-}"
    shift || true
    local repo_root
    repo_root="$(cd "$SCRIPT_DIR/../../.." && pwd)"

    if [[ -z "$provider" ]]; then
        log_error "Usage: uis network expose <provider> <service>"
        { _list_available_network_providers_with_script expose.sh "$repo_root"; } >&2
        exit "$EXIT_GENERAL_ERROR"
    fi

    local script="$repo_root/networking/$provider/scripts/expose.sh"
    if [[ ! -f "$script" ]]; then
        log_error "Network provider '$provider' has no expose.sh (looked at $script)"
        if [[ "$provider" == "cloudflare" ]]; then
            echo "  Cloudflare exposes services via cluster-wide HostRegexp routing —" >&2
            echo "  every IngressRoute matching *.<your-domain> is automatically reachable" >&2
            echo "  once 'uis network up cloudflare' is running. No per-service step needed." >&2
        else
            { _list_available_network_providers_with_script expose.sh "$repo_root"; } >&2
        fi
        exit "$EXIT_GENERAL_ERROR"
    fi

    export UIS_REPO_ROOT="$repo_root"
    exec "$script" "$@"
}

# cmd_network_unexpose — undo per-service Funnel exposure. Tailscale-specific.
cmd_network_unexpose() {
    _uis_cluster_banner
    local provider="${1:-}"
    shift || true
    local repo_root
    repo_root="$(cd "$SCRIPT_DIR/../../.." && pwd)"

    if [[ -z "$provider" ]]; then
        log_error "Usage: uis network unexpose <provider> <service>"
        { _list_available_network_providers_with_script unexpose.sh "$repo_root"; } >&2
        exit "$EXIT_GENERAL_ERROR"
    fi

    local script="$repo_root/networking/$provider/scripts/unexpose.sh"
    if [[ ! -f "$script" ]]; then
        log_error "Network provider '$provider' has no unexpose.sh (looked at $script)"
        if [[ "$provider" == "cloudflare" ]]; then
            echo "  Cloudflare doesn't have per-service unexpose — remove the IngressRoute" >&2
            echo "  or take the cluster tunnel down entirely with 'uis network down cloudflare'." >&2
        else
            { _list_available_network_providers_with_script unexpose.sh "$repo_root"; } >&2
        fi
        exit "$EXIT_GENERAL_ERROR"
    fi

    export UIS_REPO_ROOT="$repo_root"
    exec "$script" "$@"
}

# cmd_network_list — enumerate networking providers + their state.
# Reads each provider's status.sh --summary and renders a row.
# No banner — discovery command.
_print_network_provider_row() {
    local provider="$1"
    local repo_root="$2"
    local status_script="$repo_root/networking/$provider/scripts/status.sh"
    if [[ ! -f "$status_script" ]]; then
        printf "%-12s · not initialized            (no networking/%s/scripts/status.sh)\n" "$provider" "$provider"
        return
    fi
    local line state hint icon state_label
    # status.sh --summary emits one tab-separated line: <state>\t<hint>
    line="$(UIS_REPO_ROOT="$repo_root" "$status_script" --summary 2>/dev/null || echo "")"
    if [[ -z "$line" ]]; then
        printf "%-12s ? error                       (status.sh --summary failed)\n" "$provider"
        return
    fi
    state="${line%%	*}"
    hint="${line#*	}"
    case "$state" in
        running)                icon="✓"; state_label="running" ;;
        configured-not-running) icon="·"; state_label="configured, not running" ;;
        not-initialized)        icon="·"; state_label="not initialized" ;;
        unreachable)            icon="✗"; state_label="unreachable" ;;
        *)                      icon="?"; state_label="$state" ;;
    esac
    printf "%-12s %s %-25s (%s)\n" "$provider" "$icon" "$state_label" "$hint"
}

cmd_network_list() {
    local repo_root
    repo_root="$(cd "$SCRIPT_DIR/../../.." && pwd)"

    echo "PROVIDER     STATUS"
    _print_network_provider_row "cloudflare" "$repo_root"
    _print_network_provider_row "tailscale" "$repo_root"
}

# ============================================================
# Interactive Setup Menu
# ============================================================

cmd_setup() {
    if ! type show_menu &>/dev/null; then
        log_error "menu-helpers.sh not loaded"
        exit "$EXIT_GENERAL_ERROR"
    fi

    while true; do
        local choice
        choice=$(show_menu "UIS Setup Menu v$UIS_VERSION" "Select an option:" \
            "services" "Browse & Deploy Services" \
            "tools" "Install Optional Tools" \
            "status" "System Status" \
            "exit" "Exit")

        case "$choice" in
            services)
                setup_services_menu
                ;;
            tools)
                setup_tools_menu
                ;;
            status)
                clear_screen
                cmd_status
                echo ""
                read -p "Press Enter to continue..."
                ;;
            exit|"")
                break
                ;;
        esac
    done
}

setup_services_menu() {
    while true; do
        # Build category menu
        local -a menu_args=()
        for cat_id in "${CATEGORY_ORDER[@]}"; do
            local cat_name
            cat_name=$(get_category_name "$cat_id")
            menu_args+=("$cat_id" "$cat_name")
        done
        menu_args+=("back" "Back to Main Menu")

        local choice
        choice=$(show_menu "Service Categories" "Select a category:" "${menu_args[@]}")

        if [[ "$choice" == "back" || -z "$choice" ]]; then
            break
        fi

        setup_category_services "$choice"
    done
}

setup_category_services() {
    local category="$1"
    local cat_name
    cat_name=$(get_category_name "$category")

    while true; do
        # Build service checklist
        local -a checklist_args=()
        local service_id script

        while IFS= read -r service_id; do
            [[ -z "$service_id" ]] && continue
            script=$(find_service_script "$service_id")
            [[ -z "$script" ]] && continue

            unset SCRIPT_NAME SCRIPT_DESCRIPTION SCRIPT_CHECK_COMMAND
            source "$script" 2>/dev/null

            local state="off"
            if is_service_enabled "$service_id" 2>/dev/null; then
                state="on"
            fi

            local status_marker=""
            if [[ -n "$SCRIPT_CHECK_COMMAND" ]]; then
                if check_service_deployed "$service_id" 2>/dev/null; then
                    status_marker="✅ "
                fi
            fi

            checklist_args+=("$service_id" "$status_marker${SCRIPT_NAME:-$service_id}" "$state")
        done < <(get_services_by_category "$category")

        if [[ ${#checklist_args[@]} -eq 0 ]]; then
            show_msgbox "No Services" "No services found in category $cat_name"
            break
        fi

        local selected
        selected=$(show_checklist "Services: $cat_name" "Toggle services to enable/disable:" "${checklist_args[@]}")

        if [[ -z "$selected" ]]; then
            break
        fi

        # Update enabled services based on selection
        for service_id in $(get_services_by_category "$category"); do
            if [[ " $selected " == *" $service_id "* ]]; then
                # Should be enabled
                if ! is_service_enabled "$service_id" 2>/dev/null; then
                    enable_service "$service_id" 2>/dev/null
                fi
            else
                # Should be disabled
                if is_service_enabled "$service_id" 2>/dev/null; then
                    disable_service "$service_id" 2>/dev/null
                fi
            fi
        done

        # Offer to deploy
        if show_yesno "Deploy Services" "Deploy the selected services now?"; then
            clear_screen
            deploy_enabled_services
            echo ""
            read -p "Press Enter to continue..."
        fi

        break
    done
}

setup_tools_menu() {
    while true; do
        # Build tool checklist
        local -a checklist_args=()
        local tool_id

        for tool_id in $(get_all_tool_ids | sort -u); do
            local name desc state
            name=$(get_tool_value "$tool_id" "TOOL_NAME")
            name="${name:-$tool_id}"
            desc=$(get_tool_value "$tool_id" "TOOL_DESCRIPTION")

            if is_tool_installed "$tool_id"; then
                state="on"
                name="✅ $name"
            else
                state="off"
            fi

            checklist_args+=("$tool_id" "$name" "$state")
        done

        local selected
        selected=$(show_checklist "Install Optional Tools" "Select tools to install:" "${checklist_args[@]}")

        if [[ -z "$selected" ]]; then
            break
        fi

        # Install selected tools that aren't already installed
        for tool_id in $selected; do
            if ! is_tool_installed "$tool_id"; then
                clear_screen
                install_tool "$tool_id"
                echo ""
                read -p "Press Enter to continue..."
            fi
        done

        break
    done
}

# ============================================================
# Init Command
# ============================================================

cmd_init() {
    print_section "UIS First-Time Setup"

    echo "Welcome to UIS (Urbalurba Infrastructure Stack)!"
    echo ""

    # Check if already initialized
    if check_first_run; then
        log_info "UIS is already initialized"
        echo ""
        echo "Current configuration:"
        load_cluster_config
        echo "  CLUSTER_TYPE: ${CLUSTER_TYPE:-rancher-desktop}"
        echo "  BASE_DOMAIN: ${BASE_DOMAIN:-localhost}"
        echo ""
        echo "To reconfigure, remove .uis.extend/ and run 'uis init' again"

        # Self-healing: ensure secrets templates exist even if .uis.secrets/ was recreated
        copy_secrets_templates || true

        return 0
    fi

    echo "This wizard will help you configure UIS for your environment."
    echo ""

    # Project name (optional)
    local project_name
    read -p "Project name [uis]: " project_name
    project_name="${project_name:-uis}"

    # Cluster type selection
    echo ""
    echo "Select cluster type:"
    echo "  1. rancher-desktop (Local laptop - default)"
    echo "  2. azure-aks (Azure Kubernetes Service)"
    echo "  3. azure-microk8s (MicroK8s on Azure VM)"
    echo "  4. multipass-microk8s (MicroK8s on local VM)"
    echo "  5. raspberry-microk8s (MicroK8s on Raspberry Pi)"
    read -p "Choice [1]: " cluster_choice
    cluster_choice="${cluster_choice:-1}"

    local cluster_type
    case "$cluster_choice" in
        1) cluster_type="rancher-desktop" ;;
        2) cluster_type="azure-aks" ;;
        3) cluster_type="azure-microk8s" ;;
        4) cluster_type="multipass-microk8s" ;;
        5) cluster_type="raspberry-microk8s" ;;
        *) cluster_type="rancher-desktop" ;;
    esac

    # Base domain
    echo ""
    read -p "Base domain [localhost]: " base_domain
    base_domain="${base_domain:-localhost}"

    # Initialize configuration
    initialize_uis_config

    # Update cluster-config.sh with user choices
    local config_file
    config_file=$(get_base_path)/.uis.extend/cluster-config.sh

    cat > "$config_file" << EOF
#!/bin/bash
# UIS Cluster Configuration
# Generated by 'uis init' on $(date)

# Project identifier
PROJECT_NAME="$project_name"

# Cluster type - determines deployment strategy
CLUSTER_TYPE="$cluster_type"

# Base domain for service URLs
BASE_DOMAIN="$base_domain"

# Additional configuration can be added here
EOF

    echo ""
    log_success "Configuration saved to .uis.extend/cluster-config.sh"
    echo ""
    echo "Next steps:"
    echo "  uis list              # See available services"
    echo "  uis enable <service>  # Enable services you want"
    echo "  uis deploy            # Deploy enabled services"
    echo ""
    echo "For custom secrets (optional):"
    echo "  uis secrets init      # Create secrets configuration"
}

cmd_cluster() {
    local subcmd="${1:-types}"
    shift || true

    case "$subcmd" in
        types)
            print_section "Available Cluster Types"
            echo ""
            printf "%-20s %s\n" "TYPE" "DESCRIPTION"
            echo "────────────────────────────────────────────────────────────"
            printf "%-20s %s\n" "rancher-desktop" "Local laptop (default)"
            printf "%-20s %s\n" "azure-aks" "Azure Kubernetes Service"
            printf "%-20s %s\n" "azure-microk8s" "MicroK8s on Azure VM"
            printf "%-20s %s\n" "multipass-microk8s" "MicroK8s on local VM"
            printf "%-20s %s\n" "raspberry-microk8s" "MicroK8s on Raspberry Pi"
            ;;
        *)
            log_error "Unknown cluster subcommand: $subcmd"
            echo "Usage: uis cluster [types]"
            exit "$EXIT_GENERAL_ERROR"
            ;;
    esac
}

# ============================================================
# Verify Commands (backwards compatibility - redirects to service commands)
# ============================================================

cmd_verify() {
    local target="${1:-}"

    if [[ -z "$target" ]]; then
        log_error "Usage: uis verify <service>"
        echo ""
        echo "Available verifications:"
        echo "  tailscale       Check Tailscale secrets, API, devices, and operator"
        echo "  cloudflare      Check Cloudflare secrets, network, and pod status"
        echo "  alloy           Run E2E health checks on Alloy log collection"
        echo "  argocd          Run E2E health checks on ArgoCD server"
        echo "  backstage       Run E2E health checks on Backstage (RHDH)"
        echo "  dagster         Verify Dagster orchestrates (webserver, metadata, daemon)"
        echo "  enonic          Run E2E health checks on Enonic XP"
        echo "  postgrest --app <name>  Verify one PostgREST instance serves its schema"
        echo "  minio           Run E2E health checks on MinIO object storage"
        echo "  nextcloud       Run E2E health checks on Nextcloud + OnlyOffice"
        echo "  openmetadata    Run E2E health checks on OpenMetadata"
        echo "  postgresql      Verify the database answers (either topology)"
        echo "  temporal        Run E2E health checks on Temporal"
        echo "  uptime-kuma     Run E2E health checks on Uptime Kuma"
        exit "$EXIT_GENERAL_ERROR"
    fi

    case "$target" in
        tailscale|tailscale-tunnel)
            cmd_network_verify tailscale
            ;;
        cloudflare|cloudflare-tunnel)
            cmd_network_verify cloudflare
            ;;
        alloy)
            cmd_alloy_verify
            ;;
        postgresql|postgres)
            cmd_postgresql_verify
            ;;
        argocd)
            cmd_argocd_verify
            ;;
        backstage)
            cmd_backstage_verify
            ;;
        dagster)
            cmd_dagster_verify
            ;;
        enonic)
            cmd_enonic_verify
            ;;
        postgrest)
            shift
            cmd_postgrest_verify "$@"
            ;;
        minio)
            cmd_minio_verify
            ;;
        nextcloud)
            cmd_nextcloud_verify
            ;;
        openmetadata)
            cmd_openmetadata_verify
            ;;
        temporal)
            cmd_temporal_verify
            ;;
        uptime-kuma)
            cmd_uptime_kuma_verify
            ;;
        *)
            log_error "Unknown verify target: $target"
            echo ""
            echo "Available verifications:"
            echo "  tailscale       Check Tailscale secrets, API, devices, and operator"
            echo "  cloudflare      Check Cloudflare secrets, network, and pod status"
            echo "  alloy           Run E2E health checks on Alloy log collection"
            echo "  argocd          Run E2E health checks on ArgoCD server"
            echo "  backstage       Run E2E health checks on Backstage (RHDH)"
            echo "  dagster         Verify Dagster orchestrates (webserver, metadata, daemon)"
        echo "  enonic          Run E2E health checks on Enonic XP"
        echo "  postgrest --app <name>  Verify one PostgREST instance serves its schema"
            echo "  minio           Run E2E health checks on MinIO object storage"
            echo "  nextcloud       Run E2E health checks on Nextcloud + OnlyOffice"
            echo "  openmetadata    Run E2E health checks on OpenMetadata"
            echo "  postgresql      Verify the database answers (either topology)"
            echo "  temporal        Run E2E health checks on Temporal"
            echo "  uptime-kuma     Run E2E health checks on Uptime Kuma"
            exit "$EXIT_GENERAL_ERROR"
            ;;
    esac
}

# ============================================================
# Tailscale Commands
# ============================================================

# cmd_tailscale — redirect stub. The whole 'uis tailscale ...' family was
# replaced by 'uis network ... tailscale' in PLAN-002. This stub catches
# users with muscle memory and points them at the new commands.
cmd_tailscale() {
    local subcmd="${1:-}"
    log_error "'uis tailscale' moved to 'uis network ... tailscale'."
    case "$subcmd" in
        expose)
            shift || true
            echo "  Use: ./uis network expose tailscale ${1:-<service>}" >&2
            ;;
        unexpose)
            shift || true
            echo "  Use: ./uis network unexpose tailscale ${1:-<service>}" >&2
            ;;
        verify)
            echo "  Use: ./uis network verify tailscale" >&2
            ;;
        "")
            echo "  See: ./uis help (Network: section)" >&2
            ;;
        *)
            echo "  See: ./uis help (Network: section)" >&2
            ;;
    esac
    exit "$EXIT_GENERAL_ERROR"
}

# ============================================================
# Cloudflare Commands — ported to `uis network <verb> cloudflare`
# ============================================================
#
# Old top-level `uis cloudflare verify/teardown` commands are replaced by the
# unified `uis network <verb> cloudflare` family. This stub catches users with
# muscle memory and points them at the new commands.

cmd_cloudflare() {
    local subcmd="${1:-}"
    log_error "'uis cloudflare' moved to 'uis network ... cloudflare'."
    case "$subcmd" in
        verify)
            echo "  Use: ./uis network verify cloudflare" >&2
            ;;
        teardown)
            echo "  Use: ./uis network down cloudflare" >&2
            ;;
        "")
            echo "  See: ./uis help (Network: section)" >&2
            ;;
        *)
            echo "  See: ./uis help (Network: section)" >&2
            ;;
    esac
    exit "$EXIT_GENERAL_ERROR"
}

# ============================================================
# Configure Command — create per-app resources in running services
# See: PLAN-001-uis-configure-expose.md Phase 3
# ============================================================

cmd_configure() {
    _uis_cluster_banner
    run_configure "$@"
}

# ============================================================
# Expose Command — port-forward management for DCT integration
# See: PLAN-001-uis-configure-expose.md Phase 2
# ============================================================

cmd_expose() {
    _uis_cluster_banner
    local service_or_flag="${1:-}"
    local flag="${2:-}"

    if [[ -z "$service_or_flag" ]]; then
        log_error "Usage: uis expose <service> | uis expose <service> --stop | uis expose --status"
        echo "" >&2
        echo "Exposes K8s service ports to the host machine for local development." >&2
        echo "DCT containers can then reach services via host.docker.internal:<port>." >&2
        echo "" >&2
        echo "Examples:" >&2
        echo "  uis expose postgresql          # Start port-forward on port 35432" >&2
        echo "  uis expose postgresql --stop   # Stop port-forward" >&2
        echo "  uis expose --status            # Show currently exposed services" >&2
        exit "$EXIT_GENERAL_ERROR"
    fi

    case "$service_or_flag" in
        --status)
            expose_status
            ;;
        *)
            if [[ "$flag" == "--stop" ]]; then
                unexpose_service "$service_or_flag"
            else
                expose_service "$service_or_flag"
            fi
            ;;
    esac
}

# ============================================================
# ArgoCD Commands
# ============================================================

cmd_argocd() {
    local subcmd="${1:-}"
    shift || true

    if [[ -z "$subcmd" ]]; then
        log_error "Usage: uis argocd <command> [options]"
        echo ""
        echo "Commands:"
        echo "  register <name> <url> Register a GitHub repo as ArgoCD application"
        echo "  remove <name>         Remove an ArgoCD-managed application"
        echo "  list                  List registered ArgoCD applications"
        echo "  verify                Run E2E health checks on ArgoCD server"
        echo ""
        echo "Examples:"
        echo "  uis argocd register hello-world https://github.com/owner/repo"
        echo "  uis argocd remove hello-world"
        exit "$EXIT_GENERAL_ERROR"
    fi

    case "$subcmd" in
        register)
            cmd_argocd_register "$@"
            ;;
        remove)
            cmd_argocd_remove "$@"
            ;;
        list)
            cmd_argocd_list
            ;;
        verify)
            cmd_argocd_verify
            ;;
        *)
            log_error "Unknown argocd command: $subcmd"
            echo ""
            echo "Commands:"
            echo "  register <name> <url> Register a GitHub repo as ArgoCD application"
            echo "  remove <name>         Remove an ArgoCD-managed application"
            echo "  list                  List registered ArgoCD applications"
            echo "  verify                Run E2E health checks on ArgoCD server"
            echo ""
            echo "Examples:"
            echo "  uis argocd register hello-world https://github.com/owner/repo"
            echo "  uis argocd remove hello-world"
            exit "$EXIT_GENERAL_ERROR"
            ;;
    esac
}

cmd_argocd_register() {
    local app_name="${1:-}"
    local repo_url="${2:-}"

    if [[ -z "$app_name" || -z "$repo_url" ]]; then
        log_error "Usage: uis argocd register <name> <repo-url>"
        echo "" >&2
        echo "Arguments:" >&2
        echo "  <name>      Application name (used as namespace, must be unique)" >&2
        echo "  <repo-url>  Full GitHub repository URL (https://...)" >&2
        echo "" >&2
        echo "Examples:" >&2
        echo "  uis argocd register hello-world https://github.com/helpers-no/urb-dev-typescript-hello-world" >&2
        echo "  uis argocd register my-app https://github.com/myorg/my-k8s-app" >&2
        exit "$EXIT_GENERAL_ERROR"
    fi

    # Validate name is DNS-compatible (lowercase alphanumeric and hyphens, max 63 chars)
    if ! echo "$app_name" | grep -qE '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'; then
        log_error "Invalid name: '$app_name'"
        echo "Name must be lowercase, alphanumeric, and hyphens only (max 63 chars)." >&2
        echo "Must start and end with a letter or number." >&2
        echo "" >&2
        echo "Examples: hello-world, my-app, staging-api" >&2
        exit "$EXIT_GENERAL_ERROR"
    fi

    # Validate repo_url starts with https://
    if [[ "$repo_url" != https://* ]]; then
        log_error "Invalid repository URL: '$repo_url'"
        echo "Repository URL must be a full HTTPS URL." >&2
        echo "" >&2
        echo "Example: https://github.com/owner/repo-name" >&2
        exit "$EXIT_GENERAL_ERROR"
    fi

    # Check if name is already in use as a namespace
    local kubeconf="/mnt/urbalurbadisk/.uis.secrets/generated/kubeconfig/kubeconf-all"
    if kubectl get namespace "$app_name" --kubeconfig="$kubeconf" &>/dev/null; then
        log_error "Name '$app_name' is already in use as a Kubernetes namespace."
        echo "Choose a different name or remove it first: uis argocd remove $app_name" >&2
        exit "$EXIT_GENERAL_ERROR"
    fi

    print_section "Registering $app_name with ArgoCD"

    # Try to get GitHub PAT from secrets (optional — for private repos)
    local github_pat
    github_pat=$(kubectl get secret urbalurba-secrets -n default \
        -o jsonpath='{.data.GITHUB_ACCESS_TOKEN}' \
        --kubeconfig="$kubeconf" 2>/dev/null | base64 -d 2>/dev/null) || true

    # Clear placeholder values
    if [[ -z "$github_pat" || "$github_pat" == "your-github-token-here" ]]; then
        github_pat=""
        echo "Note: No GitHub token configured. Only public repos can be registered."
        echo ""
    fi

    echo "App name:    $app_name"
    echo "Repository:  $repo_url"
    echo ""

    ansible-playbook "$ANSIBLE_DIR/argocd-register-app.yml" \
        -e "app_name=$app_name" \
        -e "repo_url=$repo_url" \
        -e "github_pat=$github_pat"
}

cmd_argocd_remove() {
    local app_name="${1:-}"
    if [[ -z "$app_name" ]]; then
        log_error "Usage: uis argocd remove <name>"
        echo "Example: uis argocd remove hello-world" >&2
        exit "$EXIT_GENERAL_ERROR"
    fi

    print_section "Removing $app_name from ArgoCD"
    ansible-playbook "$ANSIBLE_DIR/argocd-remove-app.yml" \
        -e "app_name=$app_name"
}

cmd_argocd_list() {
    print_section "ArgoCD Applications"
    ansible-playbook "$ANSIBLE_DIR/argocd-list-apps.yml"
}

cmd_argocd_verify() {
    print_section "Verifying ArgoCD Deployment"
    ansible-playbook "$ANSIBLE_DIR/220-test-argocd.yml"
}

# ============================================================
# Enonic XP Commands
# ============================================================

cmd_enonic_verify() {
    print_section "Verifying Enonic XP Deployment"
    ansible-playbook "$ANSIBLE_DIR/085-test-enonic.yml"
}

# PostgREST is multi-instance: one Deployment per consuming app, so there is no
# single instance to verify. --app is required, exactly as it is for deploy.
cmd_dagster_verify() {
    print_section "Verifying Dagster Data Orchestrator"
    ansible-playbook "$ANSIBLE_DIR/360-test-dagster.yml"
}

cmd_postgrest_verify() {
    local app_name=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --app) app_name="${2:-}"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [[ -z "$app_name" ]]; then
        log_error "Service 'postgrest' is multi-instance \u2014 --app <name> is required"
        log_info "Example: uis verify postgrest --app atlas"
        log_info "Instances: kubectl get deploy -n postgrest"
        return "$EXIT_GENERAL_ERROR"
    fi

    print_section "Verifying PostgREST instance '$app_name'"
    ansible-playbook "$ANSIBLE_DIR/088-test-postgrest.yml" -e "_app_name=$app_name"
}

# ============================================================
# Nextcloud Commands
# ============================================================

cmd_nextcloud_verify() {
    print_section "Verifying Nextcloud + OnlyOffice Deployment"
    ansible-playbook "$ANSIBLE_DIR/620-test-nextcloud.yml"
}

# ============================================================
# Backstage Commands
# ============================================================

cmd_backstage_verify() {
    print_section "Verifying Backstage (RHDH) Deployment"
    ansible-playbook "$ANSIBLE_DIR/650-test-backstage.yml"
}

# ============================================================
# OpenMetadata Commands
# ============================================================

cmd_openmetadata_verify() {
    print_section "Verifying OpenMetadata Deployment"
    ansible-playbook "$ANSIBLE_DIR/340-test-openmetadata.yml"
}

# ============================================================
# MinIO Commands
# ============================================================

cmd_minio_verify() {
    print_section "Verifying MinIO Deployment"
    ansible-playbook "$ANSIBLE_DIR/045-test-minio.yml"
}

# ============================================================
# Temporal Commands
# ============================================================

cmd_temporal_verify() {
    print_section "Verifying Temporal Deployment"
    ansible-playbook "$ANSIBLE_DIR/086-test-temporal.yml"
}

# ============================================================
# Alloy Commands
# ============================================================

cmd_postgresql_verify() {
    print_section "Verifying PostgreSQL"

    # Same target resolution deploy uses; the alloy verify learned this the hard way.
    local cluster_config="$CONFIG_DIR/cluster-config.sh"
    local target_host="rancher-desktop"
    if [[ -f "$cluster_config" ]]; then
        # shellcheck source=/dev/null
        source "$cluster_config"
        target_host="${TARGET_HOST:-rancher-desktop}"
    fi

    ansible-playbook "$ANSIBLE_DIR/040-test-postgresql.yml" -e "target_host=$target_host"
}

cmd_alloy_verify() {
    print_section "Verifying Alloy Deployment"

    # The alloy playbooks pin `context: {{ _target }}`, so verify must resolve the
    # target the same way service-deployment.sh does for deploy. Without it the
    # playbook falls back to 'rancher-desktop' and fails on every other cluster -
    # which is the whole dev/prod parity the platform is supposed to have.
    local cluster_config="$CONFIG_DIR/cluster-config.sh"
    local target_host="rancher-desktop"
    if [[ -f "$cluster_config" ]]; then
        # shellcheck source=/dev/null
        source "$cluster_config"
        target_host="${TARGET_HOST:-rancher-desktop}"
    fi

    ansible-playbook "$ANSIBLE_DIR/031-test-alloy.yml" -e "target_host=$target_host"
}

cmd_uptime_kuma_verify() {
    print_section "Verifying Uptime Kuma Deployment"
    ansible-playbook "$ANSIBLE_DIR/230-test-uptime-kuma.yml"
}

# ============================================================
# Docs Commands
# ============================================================

cmd_docs() {
    local subcmd="${1:-generate}"
    shift || true

    case "$subcmd" in
        generate|gen)
            local output_dir="${1:-}"
            local docs_script="$SCRIPT_DIR/uis-docs.sh"

            if [[ ! -f "$docs_script" ]]; then
                log_error "uis-docs.sh not found"
                exit "$EXIT_GENERAL_ERROR"
            fi

            "$docs_script" "$output_dir"
            ;;
        plans)
            local plans_script="$SCRIPT_DIR/uis-docs-plan-indexes.sh"

            if [[ ! -f "$plans_script" ]]; then
                log_error "uis-docs-plan-indexes.sh not found"
                exit "$EXIT_GENERAL_ERROR"
            fi

            "$plans_script" "$@"
            ;;
        *)
            log_error "Unknown docs subcommand: $subcmd"
            echo "Usage: uis docs [generate [output-dir] | plans [plans-dir]]"
            exit "$EXIT_GENERAL_ERROR"
            ;;
    esac
}

cmd_catalog() {
    local subcmd="${1:-generate}"
    shift || true

    case "$subcmd" in
        generate|gen)
            local catalog_script="$SCRIPT_DIR/uis-backstage-catalog.sh"

            if [[ ! -f "$catalog_script" ]]; then
                log_error "uis-backstage-catalog.sh not found"
                exit "$EXIT_GENERAL_ERROR"
            fi

            "$catalog_script" "$@"
            ;;
        *)
            log_error "Unknown catalog subcommand: $subcmd"
            echo "Usage: uis catalog [generate [--output-dir DIR] [--dry-run]]"
            exit "$EXIT_GENERAL_ERROR"
            ;;
    esac
}

# ============================================================
# Host Commands
# ============================================================

cmd_host() {
    local subcmd="${1:-}"
    shift || true

    if ! type hosts_list_templates &>/dev/null; then
        log_error "uis-hosts.sh not loaded"
        exit "$EXIT_GENERAL_ERROR"
    fi

    case "$subcmd" in
        ""|add)
            if [[ -z "${1:-}" ]]; then
                # No template specified - list available
                hosts_list_templates
            else
                # Template specified - add it
                hosts_add_template "$@"
            fi
            ;;
        list|ls)
            hosts_list_configured
            ;;
        generate)
            cmd_host_generate "$@"
            ;;
        create)
            cmd_host_create "$@"
            ;;
        *)
            log_error "Unknown host subcommand: $subcmd"
            echo "Usage: uis host [add|list|generate|create] [args]"
            exit "$EXIT_GENERAL_ERROR"
            ;;
    esac
}

cmd_host_generate() {
    local host_name="${1:-}"

    if [[ -z "$host_name" ]]; then
        log_error "Usage: uis host generate <host-name>"
        exit "$EXIT_GENERAL_ERROR"
    fi

    log_info "Generating cloud-init for: $host_name"
    log_warn "Cloud-init generation not yet implemented"
    log_info "This will be completed in a future update"

    # TODO: Implementation will:
    # 1. Find host config in .uis.extend/hosts/
    # 2. Validate required secrets exist
    # 3. Load cloud-init template
    # 4. Substitute variables
    # 5. Write to .uis.secrets/generated/ubuntu-cloud-init/
}

cmd_host_create() {
    local host_name="${1:-}"

    if [[ -z "$host_name" ]]; then
        log_error "Usage: uis host create <host-name>"
        exit "$EXIT_GENERAL_ERROR"
    fi

    log_info "Creating cloud resources for: $host_name"
    log_warn "Cloud resource creation not yet implemented"
    log_info "This will be completed in a future update"

    # TODO: Implementation will:
    # 1. Find host config in .uis.extend/hosts/
    # 2. Determine provider (Azure, GCP, AWS)
    # 3. Validate credentials exist
    # 4. For cloud-vm: generate cloud-init first
    # 5. Call provider CLI to create resources
    # 6. Store kubeconfig in .uis.secrets/generated/kubeconfig/
}

# ============================================================
# Secrets Commands
# ============================================================

# uis monitors - availability monitors for the services UIS deployed
#
# Reads probe artifacts shipped with each service, discovers where those
# services actually are, and writes the result into the uptime-kuma-monitors
# Secret. AutoKuma reconciles it into Uptime Kuma.
#
# The user supplies nothing: they deployed the services, so UIS already knows
# the hostnames, and the probe details ship with the service.
cmd_monitors() {
    local subcmd="${1:-check}"
    shift || true

    local lib="${UIS_ROOT:-/mnt/urbalurbadisk/provision-host/uis}/lib/monitors.py"
    if [[ ! -f "$lib" ]]; then
        log_error "monitors library not found at $lib"
        exit "$EXIT_GENERAL_ERROR"
    fi

    # The salt that derives heartbeat URLs is read by the library from the
    # WATCHDOG's cluster. Reading it here would use whatever context happens to
    # be current, which is the wrong cluster whenever --from and --to differ.

    # Where the services are, and where the watchdog is. Persisted so they are
    # not retyped every time: getting them wrong makes `check` report confident,
    # entirely spurious drift, which is worse than an outright error.
    local cfg
    cfg="$(get_base_path)/.uis.extend/cluster-config.sh"
    if [[ -f "$cfg" ]]; then
        # shellcheck source=/dev/null
        source "$cfg" 2>/dev/null || true
    fi

    local ctx_args=()
    if [[ "$*" != *--from* && -n "${MONITORS_FROM_CONTEXT:-}" ]]; then
        ctx_args+=(--from "$MONITORS_FROM_CONTEXT")
        [[ -n "${MONITORS_TO_CONTEXT:-}" ]] && ctx_args+=(--to "$MONITORS_TO_CONTEXT")
        log_info "contexts from cluster-config.sh: ${MONITORS_FROM_CONTEXT} -> ${MONITORS_TO_CONTEXT:-$MONITORS_FROM_CONTEXT}"
    fi

    case "$subcmd" in
        render|apply|check)
            python3 "$lib" "$subcmd" "${ctx_args[@]}" "$@"
            ;;
        *)
            log_error "Unknown monitors subcommand: $subcmd"
            echo "Usage: uis monitors [render|apply|check] [--from CTX] [--to CTX]"
            echo "  render  show what would be monitored, change nothing"
            echo "  apply   write the definitions and restart AutoKuma"
            echo "  check   compare intent against what Uptime Kuma is running"
            echo ""
            echo "  --from  cluster to discover services in (read-only)"
            echo "  --to    cluster where Uptime Kuma runs. Defaults to --from."
            echo ""
            echo "  Set MONITORS_FROM_CONTEXT / MONITORS_TO_CONTEXT in"
            echo "  .uis.extend/cluster-config.sh to avoid retyping them."
            echo "          Use both when the watchdog is outside the platform"
            echo "          it watches, which is the production arrangement."
            exit "$EXIT_GENERAL_ERROR"
            ;;
    esac
}

cmd_secrets() {
    local subcmd="${1:-status}"
    shift || true

    if ! type init_secrets &>/dev/null; then
        log_error "secrets-management.sh not loaded"
        exit "$EXIT_GENERAL_ERROR"
    fi

    case "$subcmd" in
        init)
            init_secrets
            ;;
        status)
            show_secrets_status
            ;;
        edit)
            edit_secrets
            ;;
        generate)
            generate_secrets
            ;;
        apply)
            apply_secrets
            ;;
        validate)
            validate_secrets
            ;;
        *)
            log_error "Unknown secrets subcommand: $subcmd"
            echo "Usage: uis secrets [init|status|edit|generate|apply|validate]"
            exit "$EXIT_GENERAL_ERROR"
            ;;
    esac
}

# ============================================================
# Test Commands
# ============================================================

cmd_test_all() {
    _uis_cluster_banner
    # C-4 — children spawned by run_integration_tests should not re-banner.
    export UIS_BANNER_PRINTED=1
    if ! type run_integration_tests &>/dev/null; then
        log_error "integration-testing.sh not loaded"
        exit "$EXIT_GENERAL_ERROR"
    fi

    run_integration_tests "$@"
}

# ============================================================
# Main Command Router
# ============================================================

main() {
    local command="${1:-help}"
    shift || true

    # Initialize on first run for most commands (skip for version, help, setup)
    case "$command" in
        version|--version|-v|help|--help|-h|setup)
            # These commands don't need initialization
            ;;
        *)
            # Initialize if first run (creates enabled-services.conf, secrets, etc.)
            if ! check_first_run; then
                initialize_uis_config
            fi
            ;;
    esac

    case "$command" in
        version|--version|-v)
            cmd_version
            ;;
        help|--help|-h)
            cmd_help
            ;;
        setup)
            cmd_setup
            ;;
        init)
            cmd_init
            ;;
        cluster)
            cmd_cluster "$@"
            ;;
        host)
            cmd_host "$@"
            ;;
        secrets)
            cmd_secrets "$@"
            ;;
        monitors)
            cmd_monitors "$@"
            ;;
        docs)
            cmd_docs "$@"
            ;;
        catalog)
            cmd_catalog "$@"
            ;;
        list|ls)
            cmd_list "$@"
            ;;
        status)
            cmd_status "$@"
            ;;
        categories|cats)
            cmd_categories
            ;;
        stacks)
            cmd_stacks
            ;;
        stack)
            cmd_stack "$@"
            ;;
        platform)
            cmd_platform "$@"
            ;;
        network)
            cmd_network "$@"
            ;;
        deploy)
            cmd_deploy "$@"
            ;;
        undeploy)
            cmd_undeploy "$@"
            ;;
        configure)
            cmd_configure "$@"
            ;;
        expose)
            cmd_expose "$@"
            ;;
        template)
            run_template "$@"
            ;;
        connect)
            cmd_connect "$@"
            ;;
        enable)
            cmd_enable "$@"
            ;;
        disable)
            cmd_disable "$@"
            ;;
        list-enabled|enabled)
            cmd_list_enabled
            ;;
        sync)
            cmd_sync
            ;;
        tools)
            cmd_tools "$@"
            ;;
        verify)
            cmd_verify "$@"
            ;;
        tailscale)
            cmd_tailscale "$@"
            ;;
        cloudflare)
            cmd_cloudflare "$@"
            ;;
        argocd)
            cmd_argocd "$@"
            ;;
        # `uis alloy verify` is the form VERIFY_SERVICES stores, so test-all
        # reaches the E2E tests through here - not through `uis verify alloy`.
        # Both are registered; a service with only one of them is unreachable
        # from whichever path it is missing.
        postgresql)
            local subcmd="${1:-}"
            shift 2>/dev/null || true
            case "$subcmd" in
                verify)
                    cmd_postgresql_verify
                    ;;
                *)
                    log_error "Unknown postgresql command: $subcmd"
                    echo ""
                    echo "Commands:"
                    echo "  postgresql verify    Verify the database answers (either topology)"
                    exit "$EXIT_GENERAL_ERROR"
                    ;;
            esac
            ;;
        alloy)
            local subcmd="${1:-}"
            shift 2>/dev/null || true
            case "$subcmd" in
                verify)
                    cmd_alloy_verify
                    ;;
                *)
                    log_error "Unknown alloy command: $subcmd"
                    echo ""
                    echo "Commands:"
                    echo "  alloy verify     Run E2E health checks on Alloy log collection"
                    exit "$EXIT_GENERAL_ERROR"
                    ;;
            esac
            ;;
        dagster)
            local subcmd="${1:-}"
            shift 2>/dev/null || true
            case "$subcmd" in
                verify)
                    cmd_dagster_verify
                    ;;
                *)
                    echo "  Use: ./uis dagster verify" >&2
                    ;;
            esac
            ;;
        postgrest)
            local subcmd="${1:-}"
            shift 2>/dev/null || true
            case "$subcmd" in
                verify)
                    cmd_postgrest_verify "$@"
                    ;;
                *)
                    echo "  Use: ./uis postgrest verify --app <name>" >&2
                    ;;
            esac
            ;;
        enonic)
            local subcmd="${1:-}"
            shift 2>/dev/null || true
            case "$subcmd" in
                verify)
                    cmd_enonic_verify
                    ;;
                *)
                    log_error "Unknown enonic command: $subcmd"
                    echo ""
                    echo "Commands:"
                    echo "  enonic verify    Run E2E health checks on Enonic XP"
                    exit "$EXIT_GENERAL_ERROR"
                    ;;
            esac
            ;;
        minio)
            local subcmd="${1:-}"
            shift 2>/dev/null || true
            case "$subcmd" in
                verify)
                    cmd_minio_verify
                    ;;
                *)
                    log_error "Unknown minio command: $subcmd"
                    echo ""
                    echo "Commands:"
                    echo "  minio verify    Run E2E health checks on MinIO object storage"
                    exit "$EXIT_GENERAL_ERROR"
                    ;;
            esac
            ;;
        uptime-kuma)
            local subcmd="${1:-}"
            shift 2>/dev/null || true
            case "$subcmd" in
                verify)
                    cmd_uptime_kuma_verify
                    ;;
                *)
                    log_error "Unknown uptime-kuma command: $subcmd"
                    echo ""
                    echo "Commands:"
                    echo "  uptime-kuma verify    Run E2E health checks on Uptime Kuma"
                    exit "$EXIT_GENERAL_ERROR"
                    ;;
            esac
            ;;
        temporal)
            local subcmd="${1:-}"
            shift 2>/dev/null || true
            case "$subcmd" in
                verify)
                    cmd_temporal_verify
                    ;;
                *)
                    log_error "Unknown temporal command: $subcmd"
                    echo ""
                    echo "Commands:"
                    echo "  temporal verify    Run E2E health checks on Temporal"
                    exit "$EXIT_GENERAL_ERROR"
                    ;;
            esac
            ;;
        nextcloud)
            local subcmd="${1:-}"
            shift 2>/dev/null || true
            case "$subcmd" in
                verify)
                    cmd_nextcloud_verify
                    ;;
                *)
                    log_error "Unknown nextcloud command: $subcmd"
                    echo ""
                    echo "Commands:"
                    echo "  nextcloud verify    Run E2E health checks on Nextcloud + OnlyOffice"
                    exit "$EXIT_GENERAL_ERROR"
                    ;;
            esac
            ;;
        backstage)
            local subcmd="${1:-}"
            shift 2>/dev/null || true
            case "$subcmd" in
                verify)
                    cmd_backstage_verify
                    ;;
                *)
                    log_error "Unknown backstage command: $subcmd"
                    echo ""
                    echo "Commands:"
                    echo "  backstage verify    Run E2E health checks on Backstage (RHDH)"
                    exit "$EXIT_GENERAL_ERROR"
                    ;;
            esac
            ;;
        openmetadata)
            local subcmd="${1:-}"
            shift 2>/dev/null || true
            case "$subcmd" in
                verify)
                    cmd_openmetadata_verify
                    ;;
                *)
                    log_error "Unknown openmetadata command: $subcmd"
                    echo ""
                    echo "Commands:"
                    echo "  openmetadata verify    Run E2E health checks on OpenMetadata"
                    exit "$EXIT_GENERAL_ERROR"
                    ;;
            esac
            ;;
        test-all)
            cmd_test_all "$@"
            ;;
        *)
            log_error "Unknown command: $command"
            echo ""
            cmd_help
            exit "$EXIT_GENERAL_ERROR"
            ;;
    esac
}

# Run main if not sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
