# PLAN-004: UIS Orchestration System

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed (Epic)

**Goal**: Create a DCT-inspired orchestration system for UIS with config-driven deployment, interactive menu, and install script.

**Last Updated**: 2026-01-22

**Based on**: [INVESTIGATE-uis-distribution.md](./INVESTIGATE-uis-distribution.md)

**Prerequisites**: [PLAN-003-minimal-container-delivery.md](../completed/PLAN-003-minimal-container-delivery.md) - ✅ Complete

**Priority**: High

---

## Sub-Plans

This epic is split into 4 implementation plans. Execute them in order:

| Plan | Phases | Focus | Prerequisites |
|------|--------|-------|---------------|
| [PLAN-004A: Core CLI](../completed/PLAN-004A-core-cli.md) | 1-4 | Foundation, scanner, config, CLI | ✅ Complete |
| [PLAN-004B: Menu & Secrets](../completed/PLAN-004B-menu-secrets.md) | 5-6 | TUI menu, init wizard, secrets | ✅ Complete |
| [PLAN-004C: Distribution](../completed/PLAN-004C-distribution.md) | 7-8 | Install script, cross-platform | ✅ Complete |
| [PLAN-004D: Website & Testing](../completed/PLAN-004D-website-testing.md) | 9-10 | JSON generation, test framework | ✅ Complete |
| [PLAN-004E: JSON Schema Validation](../completed/PLAN-004E-json-schema-validation.md) | - | Schema validation framework | ✅ Complete |
| [PLAN-004F: Build and Test](./PLAN-004F-build-and-test.md) | - | Build container, run tests | 🚧 In Progress |

**Delivery Summary**:
- **004A**: `uis list`, `uis deploy`, `uis enable/disable`, first-run initialization
- **004B**: `uis setup` (TUI), `uis init`, `uis secrets`, `uis tools`
- **004C**: `curl ... | bash` install, Windows PowerShell support
- **004D**: `services.json`, test framework, CI/CD
- **004E**: Schema validation script, schema alignment for all JSON files
- **004F**: Container build, end-to-end testing, validation

**Note**: 004C and 004D can be done in parallel after 004A is complete.

---

> **Implementation Detail**: The sections below provide full context for the sub-plans. When implementing, refer to the specific sub-plan file for tasks and validation.

---

## Pre-Implementation: Secrets Cleanup

**⚠️ REQUIRED BEFORE IMPLEMENTATION**

Some secrets are already tracked in git history and need to be addressed:

### Already Tracked Files (in `topsecret/kubernetes/`)
```
topsecret/kubernetes/argocd-secret-correct.yml    # Contains bcrypt hash
topsecret/kubernetes/argocd-secret-fix.yml
topsecret/kubernetes/argocd-secret-fixed.yml
topsecret/kubernetes/argocd-urbalurba-secrets.yml
```

### Required Actions

- [ ] **Option A: Rotate secrets** (recommended)
  - Change ArgoCD admin password after implementation
  - Bcrypt hashes are slow to crack but still exposed
  - Document in runbook: "rotate ArgoCD password after cluster setup"

- [ ] **Option B: Remove from git history** (thorough but complex)
  - Use `git filter-branch` or BFG Repo-Cleaner
  - Requires force-push and team coordination
  - Only needed if repo is public or secrets are highly sensitive

- [ ] **Update .gitignore** for future protection
  - Add `.uis.secrets/` to gitignore
  - Add `/topsecret/kubernetes/*.yml` pattern (except templates)

### Gitignore Additions Needed
```gitignore
# UIS secrets folder (created by ./uis on first run)
.uis.secrets/

# Prevent future kubernetes secrets from being tracked
/topsecret/kubernetes/*.yml
!/topsecret/kubernetes/*.template
```

---

## Overview

Build a new orchestration layer in `provision-host/uis/` that provides:

1. **Zero-Config Start** - Works immediately with sensible defaults for localhost
2. **Service Scanner** - DCT-style component discovery with metadata
3. **Config-Driven Deployment** - `enabled-services.conf` for selective deployment
4. **Interactive Menu** - `uis setup` for service selection and management
5. **Init Wizard** - `uis init` for first-time configuration
6. **CLI Entry Point** - `uis-cli.sh` called by the wrapper script

**Core Philosophy**: Users should see value BEFORE investing time in configuration.

```
curl ... | bash           # Install
./uis start && ./uis deploy   # Works immediately!
# User explores, sees value
# THEN customizes secrets when ready
```

**Key Constraint**: Do NOT modify `provision-host/kubernetes/`. Build the new system alongside it.

---

## DCT Pattern Reference

Understanding the DCT (DevContainer Toolbox) patterns that UIS will adapt:

### DCT Folder Structure

```
project/
├── .devcontainer/                    # Product (never edited by user)
│   ├── additions/
│   │   ├── install-*.sh              # Tool installers with metadata
│   │   ├── service-*.sh              # Service scripts with metadata
│   │   ├── config-*.sh               # Configuration scripts
│   │   └── lib/
│   │       ├── component-scanner.sh  # Discovers scripts and extracts metadata
│   │       ├── categories.sh         # Category table definition
│   │       ├── tool-installation.sh  # Batch install from config
│   │       └── service-auto-enable.sh # Enable/disable in config
│   └── manage/
│       ├── dev-setup.sh              # Interactive TUI menu (dialog)
│       ├── dev-services.sh           # CLI service management
│       └── postCreateCommand.sh      # Runs on container create
│
├── .devcontainer.extend/             # Team config (tracked in git)
│   ├── enabled-tools.conf            # Tools to auto-install
│   ├── enabled-services.conf         # Services to auto-start
│   └── project-installs.sh           # Custom project setup
│
└── .devcontainer.secrets/            # Personal secrets (gitignored)
    ├── .kube/config                  # Kubernetes credentials
    ├── env-vars/                     # Environment files
    └── README.md                     # Documentation
```

### Key DCT Patterns

1. **Config files** - One SCRIPT_ID per line, comments with `#`
2. **Status icons** - `✅` running/installed, `❌` not installed, `⏸️` stopped
3. **Category grouping** - Services organized by category in menus
4. **Enable/disable** - Commands like `dev-services enable nginx`
5. **Auto-update config** - When you enable/disable, config file is updated
6. **TUI with dialog** - Interactive menus with `dialog --menu`

### UIS Adaptation

| DCT | UIS | Notes |
|-----|-----|-------|
| `.devcontainer/` | `provision-host/uis/` | Product code baked into uis-provision-host container |
| `.devcontainer.extend/` | `.uis.extend/` | Project config (created in current dir) |
| `.devcontainer.secrets/` | `.uis.secrets/` | Secrets (gitignored) |
| `install-*.sh` | `*-setup-*.sh` (wrappers) | Service deployment scripts |
| `dev-setup` | `uis setup` | Interactive TUI menu |
| `dev-services` | `uis` | CLI commands (list, deploy, remove) |
| `enabled-tools.conf` | `enabled-tools.conf` | Tools installed in uis-provision-host container |
| `enabled-services.conf` | `enabled-services.conf` | Services to deploy |

### Zero-Config Start Philosophy

**Key Principle**: Users should see value BEFORE investing time in configuration.

```
1. ./uis start        → Works immediately with sensible defaults
2. ./uis deploy       → Services come up and are usable
3. User explores      → Sees the system working, gains confidence
4. ./uis secrets edit → THEN customizes secrets when ready for real use
```

The default secrets are designed for **local development on localhost**:
- `DEFAULT_ADMIN_EMAIL=admin@localhost`
- `DEFAULT_ADMIN_PASSWORD=LocalDev123!`
- `DEFAULT_DATABASE_PASSWORD=LocalDevDB456!`

These work immediately for Rancher Desktop. Users only need to configure real secrets when:
- Exposing services externally (Tailscale/Cloudflare)
- Moving to production
- Integrating with external APIs (OpenAI, Azure, etc.)

### First-Run Initialization

When `./uis` is started for the first time, it creates:

```
my-project/                           # User's current directory
├── .uis.extend/                      # Project config (like .devcontainer.extend/)
│   ├── enabled-services.conf         # Default: nginx
│   ├── enabled-tools.conf            # Default: kubectl, k9s (NOT azure/aws/gcp)
│   ├── cluster-config.sh             # Default: rancher-desktop
│   └── README.md                     # Documentation
│
├── .uis.secrets/                     # Personal secrets (like .devcontainer.secrets/)
│   ├── .kube/                        # Kubernetes credentials
│   ├── api-keys/                     # API keys and tokens
│   └── README.md                     # Documentation
│
└── .gitignore                        # Auto-updated to ignore .uis.secrets/
```

### Cluster Types (from hosts/ folder)

| Cluster Type | Install Script | Description |
|--------------|----------------|-------------|
| `rancher-desktop` | `install-rancher-kubernetes.sh` | Local laptop (default) |
| `azure-aks` | `install-azure-aks.sh` | Azure Kubernetes Service |
| `azure-microk8s` | `install-azure-microk8s-v2.sh` | MicroK8s on Azure VM |
| `multipass-microk8s` | `install-multipass-microk8s.sh` | MicroK8s on local VM |
| `raspberry-microk8s` | (manual) | MicroK8s on Raspberry Pi |

### Tools vs Services

**Tools** (installed in uis-provision-host container, from provision-host scripts):
- `kubectl` - Kubernetes CLI (always available)
- `k9s` - Kubernetes TUI (always available)
- `helm` - Package manager (always available)
- `azure-cli` - Azure CLI (optional, saves ~637MB)
- `aws-cli` - AWS CLI (optional)
- `gcp-cli` - Google Cloud CLI (optional)

**Services** (deployed to Kubernetes cluster):
- `nginx` - Web server / catch-all (default enabled)
- `traefik` - Ingress controller (core)
- `prometheus` - Metrics (monitoring)
- `grafana` - Dashboards (monitoring)
- `openwebui` - AI chat UI (AI)
- etc.

---

## Phase 1: Foundation - Library and Scanner

Create the core library infrastructure based on DCT patterns.

### Tasks

- [ ] 1.1 Create folder structure
  ```
  provision-host/uis/
  ├── lib/
  │   ├── service-scanner.sh      # Component discovery
  │   ├── categories.sh           # Category definitions
  │   ├── logging.sh              # Logging utilities
  │   └── utilities.sh            # Common functions
  ├── manage/
  │   └── uis-cli.sh              # CLI entry point
  ├── services/
  │   └── .gitkeep                # Will hold new scripts with metadata
  └── .version
  ```

- [ ] 1.2 Create `lib/categories.sh`
  - Define UIS service categories (based on existing manifest numbering)
  - Categories: CORE, MONITORING, DATABASES, AI, AUTHENTICATION, QUEUES, SEARCH, MANAGEMENT
  - Include display names, descriptions, tags for each category
  - Pattern: Follow DCT `categories.sh` structure

- [ ] 1.3 Create `lib/service-scanner.sh`
  - Function: `scan_setup_scripts()` - discovers `*-setup-*.sh` scripts
  - Function: `extract_script_metadata()` - reads metadata from scripts
  - Function: `check_service_deployed()` - checks if service is running
  - Output format: tab-separated metadata (like DCT)
  - Pattern: Based on DCT `component-scanner.sh`

- [ ] 1.4 Create `lib/logging.sh`
  - Colored output functions (log_info, log_warn, log_error, log_success)
  - Progress indicators
  - Pattern: Based on DCT `logging.sh`

- [ ] 1.5 Create `lib/utilities.sh`
  - Common helper functions
  - Path resolution utilities
  - Kubernetes context helpers

### Validation

```bash
# Test scanner library
source provision-host/uis/lib/service-scanner.sh
scan_setup_scripts "/mnt/urbalurbadisk/provision-host/kubernetes"
```

---

## Phase 2: Service Scripts with Metadata

Add metadata headers to existing scripts (or create wrapper scripts).

### UIS Metadata Format

```bash
# === Service Metadata (Required) ===
SCRIPT_ID="prometheus"
SCRIPT_NAME="Prometheus"
SCRIPT_DESCRIPTION="Metrics collection and storage for observability"
SCRIPT_CATEGORY="MONITORING"

# === UIS-Specific (Optional) ===
SCRIPT_PLAYBOOK="030-setup-prometheus.yml"
SCRIPT_MANIFEST="030-prometheus-config.yaml"
SCRIPT_CHECK_COMMAND="kubectl get pods -n monitoring -l app=prometheus --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REMOVE="01-remove-prometheus.sh"
SCRIPT_REQUIRES=""                    # Space-separated SCRIPT_IDs (dependencies)
SCRIPT_PRIORITY="10"                  # Lower = deploy first

# === Website Metadata (Optional) ===
SCRIPT_ABSTRACT="Time-series database for metrics"
SCRIPT_LOGO="prometheus.svg"
SCRIPT_WEBSITE="https://prometheus.io"
```

### Tasks

- [ ] 2.1 Create metadata wrapper for monitoring services
  - **Files**: Create `provision-host/uis/services/monitoring/*.sh`
  - Scripts wrap existing `provision-host/kubernetes/11-monitoring/*.sh`
  - Add full metadata headers
  - Services: prometheus, tempo, loki, otel-collector, grafana

- [ ] 2.2 Create metadata wrapper for core services
  - **Files**: Create `provision-host/uis/services/core/*.sh`
  - Services: nginx, traefik (from 01-core)

- [ ] 2.3 Create metadata wrapper for database services
  - **Files**: Create `provision-host/uis/services/databases/*.sh`
  - Services: postgresql, mysql, mongodb, redis (from 02-databases)

- [ ] 2.4 Create metadata wrapper for AI services
  - **Files**: Create `provision-host/uis/services/ai/*.sh`
  - Services: openwebui, ollama, litellm, tika (from 31-ai)

### Validation

```bash
# Test metadata extraction
source provision-host/uis/lib/service-scanner.sh
while IFS=$'\t' read -r basename id name desc cat; do
    echo "Service: $name (ID: $id, Category: $cat)"
done < <(scan_setup_scripts "provision-host/uis/services")
```

---

## Phase 3: Config System - First-Run Initialization

Create the folder structure that gets created on first run.

### Tasks

- [ ] 3.1 Create templates for `.uis.extend/` (baked into uis-provision-host container)
  ```
  provision-host/uis/templates/uis.extend/
  ├── enabled-services.conf.default   # Default: nginx
  ├── enabled-tools.conf.default      # Default: kubectl, k9s
  ├── cluster-config.sh.default       # Default: rancher-desktop
  ├── service-overrides/
  │   └── .gitkeep
  └── README.md
  ```

- [ ] 3.2 Create templates for `.uis.secrets/` (baked into uis-provision-host container)

  **Understanding the Secrets System:**

  The existing `topsecret/` folder has this structure:
  ```
  topsecret/                              # In repository root (gitignored)
  ├── secrets-templates/                  # Templates (COMMITTED to git)
  │   ├── 00-common-values.env.template   # Master variable definitions
  │   ├── 00-master-secrets.yml.template  # Combined K8s secrets
  │   ├── 01-core-secrets.yml.template    # Core service secrets
  │   ├── 02-database-secrets.yml.template
  │   ├── ... (more templates)
  │   └── configmaps/                     # ConfigMap templates
  │       ├── ai/models/litellm.yaml.template
  │       └── monitoring/dashboards/*.template
  ├── secrets-config/                     # User's filled-in values (NOT committed)
  │   └── (copies of templates with real values)
  ├── secrets-generated/                  # Generated output (NOT committed)
  │   └── 00-common-values.env
  └── scripts (create-kubernetes-secrets.sh, etc.)
  ```

  The new `.uis.secrets/` will mirror this structure but live in the USER'S project directory:
  ```
  my-project/
  └── .uis.secrets/                       # User's secrets folder (gitignored)
      ├── secrets-config/                 # User's filled-in templates (EDIT THIS)
      │   ├── 00-common-values.env.template   # Main config - keeps .template suffix
      │   ├── 00-master-secrets.yml.template  # Optional overrides
      │   └── configmaps/                     # Custom configmaps
      ├── kubernetes/                     # Generated K8s secrets (DO NOT EDIT)
      │   └── kubernetes-secrets.yml      # Applied to cluster
      ├── .kube/                          # Kubeconfig (alternative location)
      │   └── config
      ├── api-keys/                       # API keys for external services
      │   └── *.key
      ├── .gitignore                      # Ignore everything
      └── README.md                       # Documentation
  ```

  > **Note**: Files in `secrets-config/` keep the `.template` suffix even after copying.
  > This follows the existing convention where the same file contains both structure and values.

  **Template Location:**

  Templates are baked into the uis-provision-host container at:
  ```
  /mnt/urbalurbadisk/topsecret/secrets-templates/
  ```

  The `uis secrets init` command copies templates to `.uis.secrets/secrets-config/` for the user to fill in.

  **Files to create:**
  ```
  provision-host/uis/templates/uis.secrets/
  ├── secrets-config/
  │   └── .gitkeep
  ├── kubernetes/
  │   └── .gitkeep
  ├── .kube/
  │   └── .gitkeep
  ├── api-keys/
  │   └── .gitkeep
  ├── .gitignore                          # Ignore everything except README
  └── README.md                           # Documentation
  ```

- [ ] 3.3 Create `enabled-services.conf.default`
  ```bash
  # UIS Enabled Services
  # Format: One SCRIPT_ID per line
  # Run 'uis list' to see available services
  # Run 'uis enable <service>' to add a service
  # Run 'uis disable <service>' to remove a service

  # === Core (default) ===
  nginx

  # === Monitoring ===
  # prometheus
  # grafana
  # loki

  # === AI ===
  # openwebui
  # ollama

  # === Databases ===
  # postgresql
  # redis
  ```

- [ ] 3.4 Create `enabled-tools.conf.default`
  ```bash
  # UIS Enabled Tools
  # These are tools installed in the container
  # Format: One TOOL_ID per line

  # === Always Available (built into container) ===
  kubectl
  k9s
  helm
  ansible

  # === Cloud Provider CLIs (optional, install with 'uis tools install') ===
  # azure-cli        # ~637MB - Azure CLI
  # aws-cli          # AWS CLI
  # gcp-cli          # Google Cloud CLI
  ```

- [ ] 3.5 Create `cluster-config.sh.default`
  ```bash
  # UIS Cluster Configuration
  # Edit this file to configure your cluster

  # Cluster type (see 'uis cluster types' for options)
  # Options: rancher-desktop, azure-aks, azure-microk8s, multipass-microk8s, raspberry-microk8s
  CLUSTER_TYPE="rancher-desktop"

  # Project name (used for namespaces, labels)
  PROJECT_NAME="uis"

  # Base domain for services
  BASE_DOMAIN="localhost"

  # Target host for Ansible (matches inventory)
  TARGET_HOST="rancher-desktop"

  # External domains (optional)
  # TAILSCALE_DOMAIN=""
  # CLOUDFLARE_DOMAIN=""
  ```

- [ ] 3.6 Create first-run initialization library
  - **File**: `provision-host/uis/lib/first-run.sh`
  - Function: `check_first_run()` - Checks if `.uis.extend/` exists
  - Function: `initialize_uis()` - Creates folders from templates
  - Function: `update_gitignore()` - Adds `.uis.secrets/` to .gitignore
  - Called automatically on first `./uis` command

- [ ] 3.7 Create service deployment library
  - **File**: `provision-host/uis/lib/service-deployment.sh`
  - Function: `deploy_enabled_services()` - reads config, deploys matching services
  - Function: `deploy_single_service()` - deploys one service with validation
  - Function: `remove_single_service()` - removes one service
  - Dependency resolution using SCRIPT_REQUIRES
  - Pattern: Based on DCT `tool-installation.sh`

### Validation

```bash
# Test first-run (in a fresh directory)
./uis start
# Should create:
#   .uis.extend/enabled-services.conf
#   .uis.extend/enabled-tools.conf
#   .uis.extend/cluster-config.sh
#   .uis.secrets/README.md
#   .gitignore updated

# Test config processing
./uis list-enabled
# Output: nginx (from default enabled-services.conf)
```

---

## Phase 4: CLI Entry Point

Create the CLI that the `./uis` wrapper calls into.

### Tasks

- [ ] 4.1 Create `manage/uis-cli.sh`
  - Entry point for all UIS commands
  - Sources required libraries
  - Routes commands to appropriate functions

  **Commands**:
  ```bash
  # Service Discovery
  uis list                    # List available services with status
  uis status                  # Show deployed services health

  # Service Deployment
  uis deploy                  # Deploy all enabled services
  uis deploy <service>        # Deploy specific service
  uis remove <service>        # Remove specific service

  # Config Management (like DCT dev-services enable/disable)
  uis enable <service>        # Add service to enabled-services.conf
  uis disable <service>       # Remove service from enabled-services.conf
  uis list-enabled            # Show enabled services

  # Interactive
  uis setup                   # Interactive TUI menu (dialog)
  uis init                    # First-time configuration wizard

  # Secrets
  uis secrets generate        # Generate K8s secrets from templates
  uis secrets apply           # Apply secrets to cluster

  # Info
  uis version                 # Show UIS version
  uis help                    # Show help
  ```

- [ ] 4.2 Implement `uis list` command
  - Scans all service scripts
  - Shows: ID, Name, Category, Status (deployed/not deployed)
  - Groups by category
  - Pattern: Like `kubectl get pods` output

- [ ] 4.3 Implement `uis status` command
  - Shows currently deployed services
  - Checks SCRIPT_CHECK_COMMAND for each
  - Shows health status

- [ ] 4.4 Implement `uis deploy` command
  - Without args: deploys all services from enabled-services.conf
  - With service ID: deploys that specific service
  - Resolves dependencies automatically
  - Shows progress with emojis

- [ ] 4.5 Implement `uis remove` command
  - Finds matching removal script (SCRIPT_REMOVE metadata)
  - Warns about dependent services
  - Requires confirmation

- [ ] 4.6 Implement `uis enable/disable` commands
  - **File**: `provision-host/uis/lib/service-auto-enable.sh`
  - `enable_service()` - Add SCRIPT_ID to enabled-services.conf
  - `disable_service()` - Remove SCRIPT_ID from enabled-services.conf
  - `is_service_enabled()` - Check if service is in config
  - `list_enabled_services()` - Show all enabled services
  - Pattern: Based on DCT `service-auto-enable.sh`
  - Auto-enable when service is successfully deployed
  - Keep comments and formatting in config file

- [ ] 4.7 Update `./uis` wrapper script
  - Route new commands to `uis-cli.sh`
  - Keep existing commands working (shell, provision, start, stop)

### Validation

```bash
./uis list                    # Shows all services with status
./uis status                  # Shows deployed services
./uis enable prometheus       # Adds to enabled-services.conf
./uis list-enabled            # Shows: nginx, traefik, prometheus
./uis deploy                  # Deploys all enabled services
./uis deploy grafana          # Deploys specific service (auto-enables)
./uis disable prometheus      # Removes from enabled-services.conf
./uis remove grafana          # Removes service (prompts to disable)
```

---

## Phase 5: Interactive Menu

Create dialog-based menu like DCT's dev-setup.

### Main Menu Structure

```
┌─────────────────────────────────────────┐
│         UIS Setup Menu v1.0.0           │
├─────────────────────────────────────────┤
│  1. Browse & Deploy Services            │
│  2. Install Optional Tools              │
│  3. Cluster Configuration               │
│  4. Secrets Management                  │
│  5. System Status                       │
│  6. Exit                                │
└─────────────────────────────────────────┘
```

### Tasks

- [ ] 5.1 Implement `uis setup` command
  - Uses dialog for TUI menu
  - Main menu with: Services, Tools, Config, Secrets, Status
  - Pattern: Based on DCT dev-setup.sh

- [ ] 5.2 Create service selection menu
  - Lists services by category (Core, Monitoring, AI, Databases, etc.)
  - Shows status: ✅ deployed, ❌ not deployed
  - Toggle enable/disable updates enabled-services.conf
  - Option to deploy immediately or just save config

- [ ] 5.3 Create tool installation menu (DCT-style)
  - **File**: `provision-host/uis/lib/tool-installation.sh`
  - Lists optional tools with install status
  - Shows: ✅ installed, ❌ not installed
  - Selecting a tool runs its install script
  - Updates `enabled-tools.conf` after successful install

  ```
  ┌─────────────────────────────────────────┐
  │       Install Optional Tools            │
  ├─────────────────────────────────────────┤
  │  ❌ Azure CLI      Cloud management     │
  │  ❌ AWS CLI        Cloud management     │
  │  ❌ GCP CLI        Cloud management     │
  │  ✅ kubectl        Always installed     │
  │  ✅ k9s            Always installed     │
  └─────────────────────────────────────────┘
  ```

- [ ] 5.4 Create tool install scripts with metadata
  - **Files**: `provision-host/uis/tools/install-*.sh`
  - Pattern: Same metadata format as DCT install scripts

  ```bash
  # provision-host/uis/tools/install-azure-cli.sh
  SCRIPT_ID="azure-cli"
  SCRIPT_NAME="Azure CLI"
  SCRIPT_DESCRIPTION="Command-line interface for Microsoft Azure"
  SCRIPT_CATEGORY="CLOUD_TOOLS"
  SCRIPT_CHECK_COMMAND="command -v az"
  SCRIPT_SIZE="~637MB"
  ```

- [ ] 5.5 Implement CLI tool commands
  ```bash
  uis tools list              # List all tools with status
  uis tools install <tool>    # Install specific tool
  uis tools remove <tool>     # Remove tool (if possible)
  ```

### Validation

```bash
./uis setup
# Interactive menu appears
# Navigate to "Install Optional Tools"
# Select "Azure CLI" → installs azure-cli
# Shows ✅ after installation

./uis tools list
# Output:
# ✅ kubectl      Kubernetes CLI (built-in)
# ✅ k9s          Kubernetes TUI (built-in)
# ✅ helm         Package manager (built-in)
# ❌ azure-cli    Azure CLI (~637MB)
# ❌ aws-cli      AWS CLI (~200MB)
# ❌ gcp-cli      Google Cloud CLI (~500MB)

./uis tools install azure-cli
# Installing Azure CLI...
# ✅ Azure CLI installed successfully
```

---

## Phase 6: Init Wizard

Create configuration wizard for customizing the setup.

### Tasks

- [ ] 6.1 Implement `uis init` command
  - Interactive wizard for customizing configuration
  - Updates `.uis.extend/cluster-config.sh` with user choices
  - Prompts for:
    - Project name
    - Cluster type (shows available options from hosts/)
    - Base domain
  - Optional: Admin email/password for Authentik

- [ ] 6.2 Implement `uis cluster types` command
  - Lists available cluster types from hosts/ folder
  - Shows description and requirements for each

- [ ] 6.3 Create `uis secrets` subcommands
  - **File**: `provision-host/uis/lib/secrets-management.sh`
  - **Based on**: Existing [Secrets Management System](../../../contributors/architecture/secrets.md)

  **Commands:**
  ```bash
  uis secrets init      # Create .uis.secrets/ structure and copy templates
  uis secrets edit      # Open 00-common-values.env in editor
  uis secrets generate  # Generate kubernetes-secrets.yml from templates
  uis secrets apply     # Apply generated secrets to Kubernetes cluster
  uis secrets status    # Show which secrets are configured vs missing
  uis secrets validate  # Check templates for required variables
  ```

  **Workflow:**

  **Option A: Zero-Config Start (recommended for first-time users)**
  ```
  ./uis start           # Container starts
  ./uis deploy          # Deploys with built-in defaults - JUST WORKS!
  # User explores the system, sees value
  # Later, when ready to customize:
  ./uis secrets init    # Creates .uis.secrets/ for customization
  ```

  **Option B: Custom Secrets (for users who want to configure first)**
  ```
  1. uis secrets init
     └── Creates .uis.secrets/secrets-config/
     └── Copies 00-common-values.env.template with working defaults
     └── User edits to customize (optional)

  2. uis secrets generate
     └── Reads .uis.secrets/secrets-config/00-common-values.env.template
     └── Sources templates from container: /mnt/urbalurbadisk/topsecret/secrets-templates/
     └── Generates .uis.secrets/kubernetes/kubernetes-secrets.yml

  3. uis secrets apply
     └── kubectl apply -f .uis.secrets/kubernetes/kubernetes-secrets.yml
  ```

  **Key Design Decision**: Built-in defaults are embedded in the uis-provision-host container.
  Users do NOT need to run `uis secrets init` to get started - the system works immediately.

  > **Note**: The `.template` suffix is kept in `secrets-config/` per the existing convention
  > documented in [secrets-management.md](../../../contributors/architecture/secrets.md).

  **Key Variables in 00-common-values.env:**

  | Variable | Default | When to Customize |
  |----------|---------|-------------------|
  | `DEFAULT_ADMIN_EMAIL` | `admin@localhost` | Works for local dev |
  | `DEFAULT_ADMIN_PASSWORD` | `LocalDev123!` | Works for local dev |
  | `DEFAULT_DATABASE_PASSWORD` | `LocalDevDB456!` | Works for local dev |
  | `TAILSCALE_SECRET` | _(empty)_ | Only if exposing via Tailscale |
  | `CLOUDFLARE_DNS_TOKEN` | _(empty)_ | Only if exposing via Cloudflare |
  | `GITHUB_ACCESS_TOKEN` | _(empty)_ | Only if using private GitHub packages |
  | `OPENAI_API_KEY` | _(empty)_ | Only if using OpenAI models |
  | `ANTHROPIC_API_KEY` | _(empty)_ | Only if using Anthropic models |

  **The defaults work for localhost!** Users only need to edit secrets when:
  - Exposing services externally (Tailscale, Cloudflare)
  - Using external AI providers (OpenAI, Anthropic, Azure)
  - Moving beyond local development

- [ ] 6.4 Create secrets library
  - **File**: `provision-host/uis/lib/secrets-management.sh`
  - Function: `init_secrets()` - Create folder structure, copy templates
  - Function: `generate_secrets()` - Process templates with envsubst
  - Function: `apply_secrets()` - kubectl apply
  - Function: `validate_secrets()` - Check required variables are set
  - Function: `show_secrets_status()` - Show configured vs missing

- [ ] 6.5 Handle migration from existing `topsecret/`
  - If user has existing `topsecret/secrets-config/`, offer to migrate
  - Copy `00-common-values.env` → `.uis.secrets/secrets-config/`
  - Copy any custom configmaps

### Validation

**Zero-Config Flow (first-time user experience):**
```bash
./uis start
./uis deploy
# Output:
#   Using built-in defaults for localhost development
#   ✅ Deploying nginx...
#   ✅ Services available at http://*.localhost
#
#   💡 To customize secrets later: uis secrets init
```

**Custom Secrets Flow (when user is ready to customize):**
```bash
./uis cluster types
# Lists: rancher-desktop, azure-aks, azure-microk8s, multipass-microk8s, raspberry-microk8s

./uis init
# Wizard walks through configuration
# Updates .uis.extend/cluster-config.sh

./uis secrets init
# Creates .uis.secrets/ structure with working defaults
# Output:
#   ✅ Created .uis.secrets/secrets-config/
#   ✅ Created .uis.secrets/kubernetes/
#   ✅ Copied defaults to 00-common-values.env.template
#   📝 Edit .uis.secrets/secrets-config/00-common-values.env.template to customize
#   Then run: uis secrets generate && uis secrets apply

# User edits the file (only if they want to customize)
nano .uis.secrets/secrets-config/00-common-values.env.template

./uis secrets status
# Output:
#   Secrets Source: Built-in defaults (no .uis.secrets/ found)
#
#   Core (have working defaults):
#   ✅ DEFAULT_ADMIN_EMAIL: admin@localhost
#   ✅ DEFAULT_ADMIN_PASSWORD: LocalDev123!
#   ✅ DEFAULT_DATABASE_PASSWORD: LocalDevDB456!
#
#   External Services (configure when needed):
#   ⚪ TAILSCALE_SECRET: not set (for Tailscale access)
#   ⚪ CLOUDFLARE_DNS_TOKEN: not set (for Cloudflare access)
#   ⚪ OPENAI_API_KEY: not set (for OpenAI models)

./uis secrets generate
# Output:
#   Processing templates from /mnt/urbalurbadisk/topsecret/secrets-templates/
#   ✅ Generated .uis.secrets/kubernetes/kubernetes-secrets.yml (520 lines)

./uis secrets apply
# Output:
#   Applying secrets to Kubernetes cluster...
#   ✅ namespace/ai created
#   ✅ secret/urbalurba-secrets created
#   ...
```

---

## Phase 7: Install Script

Create curl-installable script for new users.

### Tasks

- [ ] 7.1 Create `install.sh` for website hosting
  - **File**: `website/static/install.sh`
  - Checks Docker is installed
  - Pulls container image from ghcr.io
  - Creates `./uis` wrapper script in current directory
  - Does NOT create folders yet (first-run does that)
  - Prints next steps

- [ ] 7.2 Add install URL to website
  - URL: `https://uis.sovereignsky.no/install.sh`
  - Usage: `curl -fsSL https://uis.sovereignsky.no/install.sh | bash`

### Validation

```bash
# In a fresh directory
curl -fsSL https://uis.sovereignsky.no/install.sh | bash
# Creates: ./uis wrapper script

./uis start
# First-run creates:
#   .uis.extend/
#   .uis.secrets/
#   Updates .gitignore

./uis deploy
# Deploys nginx (default enabled service)
```

---

## Phase 8: Cross-Platform Wrapper Scripts

Create platform-specific wrapper scripts that call into the container.

### Architecture

```
User's machine                          uis-provision-host container
┌─────────────────┐                    ┌─────────────────────────────┐
│                 │                    │                             │
│  uis (bash)     │ ──── docker ────▶  │  provision-host/uis/        │
│  uis.ps1        │      exec          │  └── manage/uis-cli.sh      │
│                 │                    │                             │
└─────────────────┘                    └─────────────────────────────┘
```

The wrapper scripts are thin - they just:
1. Ensure uis-provision-host container is running
2. Create `.uis.extend/` and `.uis.secrets/` on first run
3. Pass commands to `uis-cli.sh` inside the uis-provision-host container

### Tasks

- [ ] 8.1 Create `uis` bash wrapper (macOS/Linux)
  - **File**: `uis` (already exists, needs update)
  - Handles: macOS, Linux, WSL2, Git Bash on Windows
  - Kubeconfig: `$HOME/.kube/config`
  - First-run: Creates `.uis.extend/`, `.uis.secrets/`
  - Commands routed to: `docker exec uis-provision-host /mnt/urbalurbadisk/provision-host/uis/manage/uis-cli.sh`

- [ ] 8.2 Create `uis.ps1` PowerShell wrapper (Windows)
  - **File**: `uis.ps1` (new)
  - Handles: Windows PowerShell, PowerShell Core
  - Kubeconfig: `$env:USERPROFILE\.kube\config`
  - First-run: Creates `.uis.extend\`, `.uis.secrets\`
  - Same command routing as bash version

- [ ] 8.3 Create `uis.cmd` batch wrapper (Windows fallback)
  - **File**: `uis.cmd` (new, optional)
  - For users who prefer Command Prompt
  - Calls PowerShell script internally

- [ ] 8.4 Update install script with platform detection
  - **File**: `website/static/install.sh` (bash)
  - **File**: `website/static/install.ps1` (PowerShell)
  - Downloads appropriate wrapper script for platform

### Wrapper Script Responsibilities

| Responsibility | Where |
|----------------|-------|
| Container lifecycle (start/stop) | Wrapper (host) |
| First-run folder creation | Wrapper (host) |
| Mount `.uis.extend/`, `.uis.secrets/`, `.kube/` | Wrapper (host) |
| Service scanning, deployment | Container (`uis-cli.sh`) |
| Kubernetes operations | Container (`kubectl`) |
| Ansible playbooks | Container (`ansible-playbook`) |

### Kubeconfig Paths by Platform

| Platform | Kubeconfig Location | Notes |
|----------|---------------------|-------|
| macOS | `~/.kube/config` | Rancher Desktop writes here |
| Linux | `~/.kube/config` | Standard location |
| WSL2 | `~/.kube/config` | Rancher Desktop integration |
| Windows | `%USERPROFILE%\.kube\config` | Rancher Desktop writes here |

### Validation

```bash
# macOS/Linux
./uis version
./uis list

# Windows PowerShell
.\uis.ps1 version
.\uis.ps1 list

# Windows CMD
uis version
uis list
```

---

## Phase 9: JSON Generation for Website

Generate JSON files from scanner output for the Docusaurus website (like DCT's `dev-docs.sh`).

### Architecture

```
Scanner scripts          JSON files              Docusaurus
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│ service-*.sh    │     │ services.json   │     │ Service catalog │
│ (with metadata) │ ──▶ │ categories.json │ ──▶ │ Browse by cat.  │
│ install-*.sh    │     │ tools.json      │     │ Tool listing    │
└─────────────────┘     └─────────────────┘     └─────────────────┘
        ▲                       │
        │                       ▼
 provision-host/uis/      website/src/data/
```

### Tasks

- [ ] 9.1 Create `uis-docs.sh` generator script
  - **File**: `provision-host/uis/manage/uis-docs.sh`
  - Pattern: Based on DCT `dev-docs.sh`
  - Scans service scripts and tool scripts for metadata
  - Generates JSON output

- [ ] 9.2 Generate `services.json`
  - **Output**: `website/src/data/services.json`
  - Contains all services with metadata:
    ```json
    {
      "services": [
        {
          "id": "prometheus",
          "type": "service",
          "name": "Prometheus",
          "description": "Metrics collection and storage",
          "category": "MONITORING",
          "tags": ["metrics", "monitoring", "observability"],
          "abstract": "Time-series database for metrics",
          "logo": "prometheus-logo.webp",
          "website": "https://prometheus.io",
          "playbook": "030-setup-prometheus.yml",
          "manifest": "030-prometheus-config.yaml"
        }
      ]
    }
    ```

- [ ] 9.3 Generate `categories.json`
  - **Output**: `website/src/data/categories.json`
  - Contains UIS service categories:
    ```json
    {
      "categories": [
        {
          "id": "CORE",
          "name": "Core Infrastructure",
          "order": 0,
          "tags": ["core", "infrastructure", "networking"],
          "abstract": "Essential infrastructure services",
          "logo": "core-logo.webp"
        },
        {
          "id": "MONITORING",
          "name": "Observability",
          "order": 1,
          ...
        }
      ]
    }
    ```

- [ ] 9.4 Generate `tools.json`
  - **Output**: `website/src/data/tools.json`
  - Contains optional CLI tools:
    ```json
    {
      "tools": [
        {
          "id": "azure-cli",
          "type": "tool",
          "name": "Azure CLI",
          "description": "Command-line interface for Microsoft Azure",
          "category": "CLOUD_TOOLS",
          "size": "~637MB",
          "builtin": false
        },
        {
          "id": "kubectl",
          "type": "tool",
          "name": "Kubernetes CLI",
          "builtin": true
        }
      ]
    }
    ```

- [ ] 9.5 Add GitHub Action to regenerate JSON
  - **File**: `.github/workflows/generate-docs.yml`
  - Triggers on changes to service/tool scripts
  - Runs `uis-docs.sh` and commits updated JSON
  - Or: Run locally and commit as part of development

### Validation

```bash
# Run inside uis-provision-host container
./provision-host/uis/manage/uis-docs.sh

# Outputs:
#   website/src/data/services.json (XX services)
#   website/src/data/categories.json (X categories)
#   website/src/data/tools.json (X tools)

# Preview locally
cd website && npm start
# Browse to services catalog page
```

---

## Phase 10: Testing Framework

Create a test suite for UIS scripts following DCT's testing patterns.

### Test Structure

```
provision-host/uis/tests/
├── lib/
│   └── test-framework.sh       # Shared assertions and test runners
├── static/
│   ├── test-metadata.sh        # Validate script metadata fields
│   ├── test-categories.sh      # Validate category assignments
│   ├── test-syntax.sh          # Bash syntax check (bash -n)
│   └── test-generated-json.sh  # Validate JSON output
├── unit/
│   ├── test-libraries.sh       # Test lib/*.sh functions
│   └── test-cli-commands.sh    # Test uis-cli.sh commands
├── deploy/
│   └── test-deploy-cycle.sh    # Test deploy → verify → remove cycle
└── run-all-tests.sh            # Test orchestrator
```

### Test Levels

| Level | Directory | What It Tests | Speed |
|-------|-----------|---------------|-------|
| 1. Static | `static/` | Metadata, syntax, categories, JSON | Fast (no execution) |
| 2. Unit | `unit/` | Library functions, CLI help | Fast (safe execution) |
| 3. Deploy | `deploy/` | Full deploy/remove cycle | Slow (modifies cluster) |

### Tasks

- [ ] 10.1 Create test framework library
  - **File**: `provision-host/uis/tests/lib/test-framework.sh`
  - Assertion functions: `assert_equals`, `assert_not_empty`, `assert_success`
  - Test runner: `run_test "name" function`
  - Summary: `print_summary`
  - Pattern: Based on DCT `test-framework.sh`

- [ ] 10.2 Create static tests
  - **test-metadata.sh**: Check SCRIPT_ID, SCRIPT_NAME, SCRIPT_DESCRIPTION, etc.
  - **test-categories.sh**: Validate category assignments are valid
  - **test-syntax.sh**: Run `bash -n` on all scripts
  - **test-generated-json.sh**: Validate JSON files are valid

- [ ] 10.3 Create unit tests
  - **test-libraries.sh**: Test scanner, deployment, logging functions
  - **test-cli-commands.sh**: Test `uis list`, `uis help`, `uis version`

- [ ] 10.4 Create deploy tests
  - **test-deploy-cycle.sh**: Deploy service → verify running → remove → verify removed
  - Only runs when explicitly requested (modifies cluster)

- [ ] 10.5 Create test orchestrator
  - **File**: `provision-host/uis/tests/run-all-tests.sh`
  - Run by level: `./run-all-tests.sh static|unit|deploy|all`
  - Filter by script: `./run-all-tests.sh static service-nginx.sh`

- [ ] 10.6 Add CI/CD integration
  - **File**: `.github/workflows/test-uis.yml`
  - Run static and unit tests on PR
  - Deploy tests optional (requires cluster)

### Validation

```bash
# Run all static tests (fast)
./provision-host/uis/tests/run-all-tests.sh static

# Run unit tests
./provision-host/uis/tests/run-all-tests.sh unit

# Run deploy tests (slow, needs cluster)
./provision-host/uis/tests/run-all-tests.sh deploy

# Run all tests
./provision-host/uis/tests/run-all-tests.sh all

# Output:
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Static Tests (Level 1)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Running: 1.1) Service scripts have required metadata... PASS
# Running: 1.2) Tool scripts have required metadata... PASS
# ...
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Test Summary
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Total: 15  Passed: 15  Failed: 0
# ✅ ALL TESTS PASSED
```

---

## Acceptance Criteria

- [ ] First-run creates `.uis.extend/` and `.uis.secrets/` folders
- [ ] First-run updates `.gitignore` to ignore `.uis.secrets/`
- [ ] `./uis list` shows all available services with metadata
- [ ] `./uis status` shows deployed services with health check
- [ ] `./uis enable <service>` adds service to enabled-services.conf
- [ ] `./uis disable <service>` removes service from enabled-services.conf
- [ ] `./uis deploy` deploys services from enabled-services.conf
- [ ] `./uis deploy <service>` deploys specific service (auto-enables)
- [ ] `./uis remove <service>` removes service cleanly
- [ ] `./uis setup` shows interactive menu (services, tools, config)
- [ ] `./uis setup` → "Install Optional Tools" shows available CLIs
- [ ] `./uis tools list` shows all tools with install status
- [ ] `./uis tools install azure-cli` installs Azure CLI
- [ ] `./uis init` walks through configuration wizard
- [ ] `./uis cluster types` lists available cluster types
- [ ] `./uis secrets init` creates `.uis.secrets/` structure with templates
- [ ] `./uis secrets validate` checks required variables are set
- [ ] `./uis secrets generate` generates Kubernetes secrets from templates
- [ ] `./uis secrets apply` applies secrets to Kubernetes cluster
- [ ] `./uis secrets status` shows configured vs missing secrets
- [ ] `uis-docs.sh` generates JSON files for website
- [ ] `website/src/data/services.json` contains all service metadata
- [ ] `website/src/data/categories.json` contains category definitions
- [ ] Static tests pass: `run-all-tests.sh static`
- [ ] Unit tests pass: `run-all-tests.sh unit`
- [ ] Install script works: `curl ... | bash`
- [ ] Existing `./uis provision` continues to work (backwards compatible)
- [ ] New system runs alongside existing `provision-host/kubernetes/`

---

## Files to Create

| File | Description |
|------|-------------|
| **Libraries** | |
| `provision-host/uis/lib/categories.sh` | Category definitions |
| `provision-host/uis/lib/service-scanner.sh` | Component discovery |
| `provision-host/uis/lib/service-deployment.sh` | Deployment logic |
| `provision-host/uis/lib/service-auto-enable.sh` | Enable/disable in config |
| `provision-host/uis/lib/first-run.sh` | First-run initialization |
| `provision-host/uis/lib/logging.sh` | Logging utilities |
| `provision-host/uis/lib/utilities.sh` | Common functions |
| `provision-host/uis/lib/tool-installation.sh` | Tool install logic (DCT-style) |
| `provision-host/uis/lib/secrets-management.sh` | Secrets init/generate/apply logic |
| **CLI & Scripts** | |
| `provision-host/uis/manage/uis-cli.sh` | CLI entry point |
| `provision-host/uis/manage/uis-docs.sh` | JSON generator for website (like DCT dev-docs.sh) |
| **Tool Install Scripts** | |
| `provision-host/uis/tools/install-azure-cli.sh` | Azure CLI installer |
| `provision-host/uis/tools/install-aws-cli.sh` | AWS CLI installer |
| `provision-host/uis/tools/install-gcp-cli.sh` | Google Cloud CLI installer |
| **Service Wrappers** | |
| `provision-host/uis/services/core/*.sh` | Core service wrappers |
| `provision-host/uis/services/monitoring/*.sh` | Monitoring service wrappers |
| `provision-host/uis/services/databases/*.sh` | Database service wrappers |
| `provision-host/uis/services/ai/*.sh` | AI service wrappers |
| **Templates** (baked into container) | |
| `provision-host/uis/templates/uis.extend/enabled-services.conf.default` | Default services |
| `provision-host/uis/templates/uis.extend/enabled-tools.conf.default` | Default tools |
| `provision-host/uis/templates/uis.extend/cluster-config.sh.default` | Default cluster config |
| `provision-host/uis/templates/uis.extend/README.md` | Documentation |
| `provision-host/uis/templates/uis.secrets/README.md` | Documentation |
| `provision-host/uis/templates/uis.secrets/.gitignore` | Ignore pattern |
| `provision-host/uis/templates/uis.secrets/secrets-config/.gitkeep` | Placeholder for user config |
| `provision-host/uis/templates/uis.secrets/kubernetes/.gitkeep` | Placeholder for generated secrets |
| **Wrapper Scripts** (user-facing) | |
| `uis` | Bash wrapper for macOS/Linux (update existing) |
| `uis.ps1` | PowerShell wrapper for Windows |
| `uis.cmd` | CMD wrapper for Windows (optional) |
| **Install Scripts** | |
| `website/static/install.sh` | Curl-installable script (bash) |
| `website/static/install.ps1` | PowerShell install script |
| **Website Data** (generated by uis-docs.sh) | |
| `website/src/data/services.json` | Service catalog metadata |
| `website/src/data/categories.json` | Category definitions |
| `website/src/data/tools.json` | Optional tools metadata |
| **Tests** | |
| `provision-host/uis/tests/lib/test-framework.sh` | Shared test utilities |
| `provision-host/uis/tests/static/test-metadata.sh` | Metadata validation |
| `provision-host/uis/tests/static/test-categories.sh` | Category validation |
| `provision-host/uis/tests/static/test-syntax.sh` | Bash syntax check |
| `provision-host/uis/tests/unit/test-libraries.sh` | Library function tests |
| `provision-host/uis/tests/unit/test-cli-commands.sh` | CLI command tests |
| `provision-host/uis/tests/deploy/test-deploy-cycle.sh` | Deploy/remove cycle tests |
| `provision-host/uis/tests/run-all-tests.sh` | Test orchestrator |
| **Other** | |
| `provision-host/uis/.version` | Version file |

---

## Files to Modify

| File | Change |
|------|--------|
| `uis` | Add routing to uis-cli.sh for new commands |
| `Dockerfile.uis-provision-host` | Include provision-host/uis/ folder |
| `.github/workflows/build-uis-container.yml` | Include uis/ in container build |

## Files to Create (CI/CD)

| File | Description |
|------|-------------|
| `.github/workflows/test-uis.yml` | Run tests on PR (static + unit) |
| `.github/workflows/generate-docs.yml` | Regenerate JSON on script changes (optional) |

---

## Out of Scope

Deferred to future plans:
- Multiple container image variants (full/local/azure)
- Auto-update check on container start
- Service dependency visualization
- Rollback mechanism
- Website React components to consume JSON data (separate task)

---

## Implementation Order

Recommended implementation sequence:

1. **Phase 1** (Foundation) - Must be first, provides core libraries
2. **Phase 2** (Metadata) - Creates services to scan
3. **Phase 3** (Config) - Enables config-driven deployment
4. **Phase 4** (CLI) - Makes it usable via commands
5. **Phase 5** (Menu) - Adds interactive experience
6. **Phase 6** (Init) - First-time user experience
7. **Phase 7** (Install) - Public distribution
8. **Phase 8** (Platform) - Broader compatibility
9. **Phase 9** (Website JSON) - Generate data for Docusaurus
10. **Phase 10** (Testing) - Test framework and CI/CD

Each phase can be tested independently before moving to the next.

**Notes**:
- Phase 9 can be done anytime after Phase 2 (once metadata exists to scan)
- Phase 10 (Testing) should be started early - create test framework after Phase 1, add tests incrementally

---

## Notes

- The new system builds alongside the existing one - no modifications to `provision-host/kubernetes/`
- Both systems can coexist during transition
- Users can choose either: `./uis provision` (old) or `./uis deploy` (new)
- DCT patterns provide proven, tested approaches - adapt rather than reinvent
- The uis-provision-host container includes both systems, so existing users are not disrupted

### Folder Naming Convention

Follows DCT pattern with `.uis.` prefix:
- `.uis.extend/` - Project configuration (like `.devcontainer.extend/`)
- `.uis.secrets/` - Personal secrets (like `.devcontainer.secrets/`)

These folders are created in the user's current directory, NOT inside the uis-provision-host container. The uis-provision-host container mounts them to access the configuration.

### Tools vs Services

- **Tools** = Software installed inside the uis-provision-host container (kubectl, k9s, helm, azure-cli, etc.)
- **Services** = Applications deployed to the Kubernetes cluster (nginx, grafana, openwebui, etc.)

Tools are managed via `enabled-tools.conf` and affect what's available in the uis-provision-host container.
Services are managed via `enabled-services.conf` and affect what's deployed to the Kubernetes cluster.

### Core Tools vs Optional Tools

| Type | Examples | When Installed | Size Impact |
|------|----------|----------------|-------------|
| **Core** (built-in) | kubectl, k9s, helm, ansible | Build time (Dockerfile) | Always included in uis-provision-host container |
| **Optional** (DCT-style) | azure-cli, aws-cli, gcp-cli | Runtime via menu/CLI | ~200-700MB each |

Core tools are always available in the uis-provision-host container. Optional tools can be installed via:
- `uis setup` → "Install Optional Tools" menu
- `uis tools install <tool>` CLI command

This keeps the base uis-provision-host container small (~1.8GB) while allowing users to add cloud CLIs as needed.

### Wrapper Script Architecture

The user interacts with thin wrapper scripts (`uis` for bash, `uis.ps1` for PowerShell) that run on their host machine. These wrappers:

1. **Handle platform differences** - Kubeconfig paths, folder creation
2. **Manage container lifecycle** - Start/stop the uis-provision-host container
3. **Create config folders** - `.uis.extend/`, `.uis.secrets/` on first run
4. **Route commands** - Pass everything else to `uis-cli.sh` inside the uis-provision-host container

All the heavy lifting (scanning services, deploying to Kubernetes, Ansible, kubectl) happens inside the uis-provision-host container. This keeps the wrappers simple and ensures consistent behavior across platforms.

### Secrets Architecture

> **Reference Documentation:**
> - [Secrets Management Quick Start](../../../contributors/architecture/secrets.md) - How-to guide
> - [Secrets Management Rules](../../../contributors/rules/secrets-management.md) - Detailed rules and patterns

**Migration from `topsecret/` to `.uis.secrets/`**

The existing `topsecret/` folder system is being replaced with `.uis.secrets/` for better portability:

| Old Location | New Location | Notes |
|--------------|--------------|-------|
| `topsecret/secrets-templates/` | Baked into uis-provision-host container | Templates are read-only product code |
| `topsecret/secrets-config/` | `.uis.secrets/secrets-config/` | User's filled-in values |
| `topsecret/secrets-generated/` | `.uis.secrets/kubernetes/` | Generated K8s manifests |
| Mounted at container build | Mounted at runtime | More flexible |

**How it works:**

```
┌─────────────────────────────────────────────────────────────────────────┐
│                      uis-provision-host container                        │
│                                                                          │
│  /mnt/urbalurbadisk/topsecret/secrets-templates/  (baked in, read-only) │
│  ├── 00-common-values.env.template                                      │
│  ├── 00-master-secrets.yml.template                                     │
│  └── ...                                                                 │
│                                                                          │
│  /mnt/urbalurbadisk/.uis.secrets/  (mounted from host)                  │
│  ├── secrets-config/                                                     │
│  │   └── 00-common-values.env.template  ← User fills this in            │
│  └── kubernetes/                                                         │
│      └── kubernetes-secrets.yml  ← Generated output                     │
└─────────────────────────────────────────────────────────────────────────┘
           │                              ▲
           │ envsubst                     │ kubectl apply
           ▼                              │
    ┌──────────────────────────────────────────────────────────────────┐
    │                      Kubernetes Cluster                           │
    │  Namespaces: default, ai, monitoring, authentik, argocd, etc.    │
    │  Secrets: urbalurba-secrets (per namespace)                       │
    └──────────────────────────────────────────────────────────────────┘
```

**Key Design Decisions:**

1. **Zero-config start** - Built-in defaults work immediately for localhost development
2. **See value first** - Users can explore the system before investing time in configuration
3. **Templates stay in the container** - Users don't need to manage template files
4. **Only one file to edit** - `00-common-values.env.template` contains all user-specific values
5. **Generated secrets are local** - `.uis.secrets/kubernetes/` is on the host, easy to inspect
6. **Backwards compatible** - Existing `topsecret/` workflows continue to work

**When Secrets Need Customization:**

| Use Case | Default Works? | Action Needed |
|----------|----------------|---------------|
| Local dev on localhost | ✅ Yes | None - just start |
| Expose via Tailscale | ❌ No | Set `TAILSCALE_*` variables |
| Expose via Cloudflare | ❌ No | Set `CLOUDFLARE_*` variables |
| Use OpenAI/Anthropic | ❌ No | Set API keys |
| Production deployment | ❌ No | Change all passwords |

**Secrets File Hierarchy:**

```
secrets-config/00-common-values.env.template  # Master config - user edits this
    │
    ├── DEFAULT_ADMIN_EMAIL    # → Used by all services
    ├── DEFAULT_ADMIN_PASSWORD # → Used by all services
    ├── DEFAULT_DATABASE_PASSWORD # → PostgreSQL, MySQL, MongoDB, etc.
    ├── TAILSCALE_SECRET       # → Tailscale network access
    ├── CLOUDFLARE_DNS_TOKEN   # → Cloudflare DNS management
    └── ...
    │
    ▼
secrets-templates/00-master-secrets.yml.template # → kubernetes-secrets.yml
    │
    ├── namespace: default     # Core secrets
    ├── namespace: ai          # AI service secrets
    ├── namespace: monitoring  # Grafana, Prometheus secrets
    ├── namespace: authentik   # SSO secrets
    └── ...
```
