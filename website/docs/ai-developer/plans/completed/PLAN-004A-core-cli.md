# PLAN-004A: UIS Core CLI System

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed

**Goal**: Create the foundation libraries, service scanner, config system, and basic CLI commands for UIS.

**Last Updated**: 2026-01-22

**Part of**: [PLAN-004-uis-orchestration-system.md](./PLAN-004-uis-orchestration-system.md) (Epic)

**Prerequisites**: [PLAN-003-minimal-container-delivery.md](../completed/PLAN-003-minimal-container-delivery.md) - ✅ Complete

**Priority**: High

**Delivers**:
- `uis list` - List available services with status
- `uis status` - Show deployed services health
- `uis deploy` - Deploy services from config
- `uis enable/disable` - Manage enabled-services.conf
- First-run folder creation (`.uis.extend/`, `.uis.secrets/`)

---

## Overview

This plan creates the MVP of the UIS orchestration system - a working CLI that can:
1. Scan and discover services with metadata
2. Deploy services based on `enabled-services.conf`
3. Show service status
4. Enable/disable services in config

**Core Philosophy**: Zero-config start - works immediately with sensible defaults.

```
./uis start && ./uis deploy   # Works immediately with defaults!
```

**Key Constraint**: Do NOT modify `provision-host/kubernetes/`. Build alongside it.

---

## Architecture: Container vs Host Boundary

**IMPORTANT**: This section clarifies where code runs to avoid confusion.

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              USER'S HOST MACHINE                                 │
│                                                                                  │
│   ./uis (bash) or uis.ps1 (PowerShell)                                          │
│   ├── Responsibility: Container lifecycle (start/stop)                          │
│   ├── Responsibility: First-run folder creation (.uis.extend/, .uis.secrets/)   │
│   ├── Responsibility: Mount folders into container                              │
│   └── Routes ALL other commands to container                                     │
│                                                                                  │
│   .uis.extend/            <- Created by HOST wrapper on first run               │
│   .uis.secrets/           <- Created by HOST wrapper on first run               │
│   .kube/config            <- Already exists on host (Rancher Desktop)           │
│                                                                                  │
└────────────────────────────────────┬────────────────────────────────────────────┘
                                     │ docker exec
                                     ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                         UIS-PROVISION-HOST CONTAINER                             │
│                                                                                  │
│   /mnt/urbalurbadisk/provision-host/uis/manage/uis-cli.sh                       │
│   ├── Receives ALL commands from host wrapper (except start/stop/shell)         │
│   ├── Sources libraries from /mnt/urbalurbadisk/provision-host/uis/lib/         │
│   ├── Scans services from /mnt/urbalurbadisk/provision-host/uis/services/       │
│   ├── Runs kubectl, ansible-playbook, helm                                      │
│   └── Reads config from mounted .uis.extend/ and .uis.secrets/                  │
│                                                                                  │
│   Mounted volumes:                                                               │
│   ├── .uis.extend/  → /mnt/urbalurbadisk/.uis.extend/   (config)               │
│   ├── .uis.secrets/ → /mnt/urbalurbadisk/.uis.secrets/  (secrets)              │
│   └── .kube/config  → /home/ansible/.kube/config        (kubernetes access)    │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### What Runs Where

| Operation | Runs On | Tool |
|-----------|---------|------|
| `./uis start` | HOST | Docker commands |
| `./uis stop` | HOST | Docker commands |
| `./uis shell` | HOST | docker exec -it |
| First-run folder creation | HOST | mkdir (in wrapper) |
| `./uis list` | CONTAINER | uis-cli.sh |
| `./uis deploy` | CONTAINER | uis-cli.sh → ansible |
| `./uis status` | CONTAINER | uis-cli.sh → kubectl |
| `./uis enable/disable` | CONTAINER | uis-cli.sh |
| Service scanning | CONTAINER | uis-cli.sh |
| Kubernetes operations | CONTAINER | kubectl/helm |
| Ansible playbooks | CONTAINER | ansible-playbook |

### Config File Locations (Inside Container)

| Purpose | Container Path | Host Path (mounted) |
|---------|---------------|---------------------|
| Enabled services | `/mnt/urbalurbadisk/.uis.extend/enabled-services.conf` | `./.uis.extend/enabled-services.conf` |
| Cluster config | `/mnt/urbalurbadisk/.uis.extend/cluster-config.sh` | `./.uis.extend/cluster-config.sh` |
| Service templates | `/mnt/urbalurbadisk/provision-host/uis/templates/` | *(baked into container)* |
| Secrets config | `/mnt/urbalurbadisk/.uis.secrets/secrets-config/` | `./.uis.secrets/secrets-config/` |

---

## Error Handling Strategy

All UIS commands follow consistent error handling:

### Exit Codes

| Code | Meaning | Example |
|------|---------|---------|
| 0 | Success | Command completed |
| 1 | General error | Unknown command |
| 2 | Config error | Malformed config file, missing required field |
| 3 | Kubernetes error | Cluster unreachable, deployment failed |
| 4 | Dependency error | Required service not deployed |

### Error Handling Functions

```bash
# lib/utilities.sh - Error handling helpers
die() {
    log_error "$1"
    exit "${2:-1}"
}

die_config() {
    log_error "Configuration error: $1"
    exit 2
}

die_k8s() {
    log_error "Kubernetes error: $1"
    log_error "Is the cluster running? Try: kubectl cluster-info"
    exit 3
}

die_dependency() {
    log_error "Dependency error: $1"
    log_error "Try deploying the required service first"
    exit 4
}
```

### Deployment Failure Behavior

1. **Single service fails**: Stop and report error, don't continue to next service
2. **Dependency not met**: Stop and show which dependency is missing
3. **Cluster unreachable**: Stop immediately with helpful error message
4. **Partial rollback**: NOT automatic (too risky) - user must manually clean up

---

## Phase 1: Foundation - Library, Scanner, and Test Framework — ✅ DONE

Create the core library infrastructure and test framework. **Tests are created alongside code from the start.**

### Tasks

- [x] 1.1 Create folder structure ✓
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
  ├── tests/
  │   ├── lib/
  │   │   └── test-framework.sh   # Test assertions and runners
  │   ├── static/
  │   │   └── .gitkeep            # Static analysis tests
  │   ├── unit/
  │   │   └── .gitkeep            # Unit tests
  │   └── run-tests.sh            # Test orchestrator
  └── .version
  ```

- [x] 1.2 Create `lib/categories.sh` ✓
  - Define UIS service categories (based on existing manifest numbering)
  - Categories: CORE, MONITORING, DATABASES, AI, AUTHENTICATION, QUEUES, SEARCH, MANAGEMENT
  - Include display names, descriptions, tags for each category
  - Function: `get_category_name()` - Get display name for a category
  - Function: `get_category_description()` - Get description for a category
  - Function: `is_valid_category()` - Check if a category ID is valid
  - Function: `generate_categories_json_internal()` - Export categories as JSON (used by uis-docs.sh)
  - Pattern: Follow DCT `categories.sh` structure

  ```bash
  # categories.sh - UIS service category definitions

  # Category format: "Display Name|Description|tags"
  declare -A CATEGORIES=(
      ["CORE"]="Core Infrastructure|Essential services|core,infrastructure"
      ["MONITORING"]="Observability|Metrics, logs, traces|monitoring,observability"
      ["DATABASES"]="Databases|Data storage services|database,storage"
      ["AI"]="AI & ML|AI and machine learning|ai,ml,llm"
      ["AUTHENTICATION"]="Authentication|Identity and access|auth,sso"
      ["QUEUES"]="Message Queues|Async messaging|queue,messaging"
      ["SEARCH"]="Search|Search engines|search,indexing"
      ["MANAGEMENT"]="Management|Admin tools|admin,management"
  )

  # Category order for display
  CATEGORY_ORDER=(CORE MONITORING DATABASES AI AUTHENTICATION QUEUES SEARCH MANAGEMENT)

  # Category icons (for website)
  declare -A CATEGORY_ICONS=(
      ["CORE"]="server"
      ["MONITORING"]="chart-line"
      ["DATABASES"]="database"
      ["AI"]="brain"
      ["AUTHENTICATION"]="shield"
      ["QUEUES"]="inbox"
      ["SEARCH"]="search"
      ["MANAGEMENT"]="cog"
  )

  # Get display name for a category
  get_category_name() {
      local cat_id="$1"
      local data="${CATEGORIES[$cat_id]}"
      echo "${data%%|*}"
  }

  # Get description for a category
  get_category_description() {
      local cat_id="$1"
      local data="${CATEGORIES[$cat_id]}"
      local rest="${data#*|}"
      echo "${rest%%|*}"
  }

  # Check if a category ID is valid
  is_valid_category() {
      local cat_id="$1"
      [[ -n "${CATEGORIES[$cat_id]}" ]]
  }

  # Generate JSON output for categories (used by uis-docs.sh)
  generate_categories_json_internal() {
      echo '{"categories": ['
      local first=true
      local order=0

      for cat_id in "${CATEGORY_ORDER[@]}"; do
          [[ "$first" != "true" ]] && echo ","
          first=false

          local name=$(get_category_name "$cat_id")
          local desc=$(get_category_description "$cat_id")
          local icon="${CATEGORY_ICONS[$cat_id]}"

          cat <<EOF
    {
      "id": "$cat_id",
      "name": "$name",
      "order": $order,
      "description": "$desc",
      "icon": "$icon"
    }
EOF
          ((order++))
      done

      echo ']}'
  }
  ```

- [x] 1.3 Create `lib/service-scanner.sh` ✓
  - Function: `scan_setup_scripts()` - discovers `*-setup-*.sh` scripts
  - Function: `extract_script_metadata()` - reads metadata from scripts
  - Function: `check_service_deployed()` - checks if service is running
  - Function: `get_service_value()` - get specific metadata field from a service
  - Output format: tab-separated metadata (like DCT)
  - Pattern: Based on DCT `component-scanner.sh`

  ```bash
  # service-scanner.sh - Service discovery and metadata extraction

  SERVICES_DIR="${SERVICES_DIR:-/mnt/urbalurbadisk/provision-host/uis/services}"

  # Scan directory for service scripts and output metadata
  # Usage: scan_setup_scripts [directory]
  # Output: tab-separated: basename, id, name, description, category
  scan_setup_scripts() {
      local dir="${1:-$SERVICES_DIR}"
      for script in "$dir"/**/*-setup-*.sh "$dir"/**/*.sh; do
          [[ -f "$script" ]] || continue
          extract_script_metadata "$script"
      done
  }

  # Extract metadata from a service script
  # Usage: extract_script_metadata <script_path>
  # Output: tab-separated line of metadata
  extract_script_metadata() {
      local script="$1"
      local basename=$(basename "$script")

      # Clear previous values
      unset SCRIPT_ID SCRIPT_NAME SCRIPT_DESCRIPTION SCRIPT_CATEGORY

      # Source script to get metadata (in subshell for safety)
      source "$script" 2>/dev/null

      # Output tab-separated
      printf "%s\t%s\t%s\t%s\t%s\n" \
          "$basename" \
          "${SCRIPT_ID:-}" \
          "${SCRIPT_NAME:-}" \
          "${SCRIPT_DESCRIPTION:-}" \
          "${SCRIPT_CATEGORY:-}"
  }

  # Check if a service is deployed by running its check command
  # Usage: check_service_deployed <service_id>
  # Returns: 0 if deployed, 1 if not
  check_service_deployed() {
      local service_id="$1"
      local script=$(find_service_script "$service_id")
      [[ -z "$script" ]] && return 1

      source "$script" 2>/dev/null
      [[ -z "$SCRIPT_CHECK_COMMAND" ]] && return 1

      eval "$SCRIPT_CHECK_COMMAND" >/dev/null 2>&1
  }

  # Get a specific metadata field from a service
  # Usage: get_service_value <service_id> <field_name>
  # Example: get_service_value "prometheus" "SCRIPT_PLAYBOOK"
  get_service_value() {
      local service_id="$1"
      local field_name="$2"
      local script=$(find_service_script "$service_id")
      [[ -z "$script" ]] && return 1

      source "$script" 2>/dev/null
      echo "${!field_name}"
  }

  # Find script file by service ID
  # Usage: find_service_script <service_id>
  # Output: full path to script, or empty if not found
  find_service_script() {
      local service_id="$1"
      for script in "$SERVICES_DIR"/**/*.sh; do
          [[ -f "$script" ]] || continue
          unset SCRIPT_ID
          source "$script" 2>/dev/null
          [[ "$SCRIPT_ID" == "$service_id" ]] && echo "$script" && return 0
      done
      return 1
  }
  ```

- [x] 1.4 Create `lib/logging.sh` ✓
  - Colored output functions (log_info, log_warn, log_error, log_success)
  - Progress indicators
  - Pattern: Based on DCT `logging.sh`

  ```bash
  # Example functions
  log_info() { echo -e "\033[0;34mℹ\033[0m $*"; }
  log_success() { echo -e "\033[0;32m✓\033[0m $*"; }
  log_warn() { echo -e "\033[0;33m⚠\033[0m $*"; }
  log_error() { echo -e "\033[0;31m✗\033[0m $*"; }
  ```

- [x] 1.5 Create `lib/utilities.sh` ✓
  - Common helper functions
  - Path resolution utilities
  - Kubernetes context helpers
  - Config file reading helpers

- [x] 1.6 Create test framework ✓
  - **File**: `provision-host/uis/tests/lib/test-framework.sh`
  - Assertion functions: `assert_equals`, `assert_not_empty`, `assert_success`, `assert_file_exists`, `assert_contains`
  - Test runner: `start_test`, `pass_test`, `fail_test`
  - Summary: `print_summary`
  - Pattern: Based on DCT test patterns

  ```bash
  #!/bin/bash
  # test-framework.sh - UIS Test Framework

  # Colors
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  NC='\033[0m'

  TESTS_RUN=0
  TESTS_PASSED=0
  TESTS_FAILED=0

  start_test() {
      ((TESTS_RUN++))
      echo -n "  Testing: $1... "
  }

  pass_test() {
      ((TESTS_PASSED++))
      echo -e "${GREEN}PASS${NC}"
  }

  fail_test() {
      ((TESTS_FAILED++))
      echo -e "${RED}FAIL${NC}"
      [[ -n "$1" ]] && echo -e "    ${RED}→ $1${NC}"
  }

  assert_equals() {
      [[ "$1" == "$2" ]] && return 0
      fail_test "Expected '$1', got '$2'"
      return 1
  }

  assert_not_empty() {
      [[ -n "$1" ]] && return 0
      fail_test "${2:-Value is empty}"
      return 1
  }

  print_summary() {
      echo ""
      echo "Total: $TESTS_RUN  Passed: $TESTS_PASSED  Failed: $TESTS_FAILED"
      [[ "$TESTS_FAILED" -eq 0 ]] && echo -e "${GREEN}ALL TESTS PASSED${NC}" && return 0
      echo -e "${RED}SOME TESTS FAILED${NC}" && return 1
  }
  ```

- [x] 1.7 Create test orchestrator ✓
  - **File**: `provision-host/uis/tests/run-tests.sh`
  - Run by level: `./run-tests.sh static|unit|all`
  - Simple runner that executes test scripts

- [x] 1.8 Create tests for Phase 1 libraries ✓
  - **File**: `provision-host/uis/tests/unit/test-phase1-libraries.sh`
  - Test that logging.sh loads and defines functions
  - Test that categories.sh loads and defines categories
  - Test that utilities.sh loads
  - Test that service-scanner.sh loads and defines scan functions

  ```bash
  #!/bin/bash
  source "$(dirname "$0")/../lib/test-framework.sh"
  LIB_DIR="/mnt/urbalurbadisk/provision-host/uis/lib"

  echo "=== Phase 1: Library Tests ==="

  # Test logging.sh
  start_test "logging.sh loads"
  source "$LIB_DIR/logging.sh" 2>/dev/null && pass_test || fail_test

  for fn in log_info log_warn log_error log_success; do
      start_test "logging.sh defines $fn"
      type $fn &>/dev/null && pass_test || fail_test
  done

  # Test categories.sh
  start_test "categories.sh loads"
  source "$LIB_DIR/categories.sh" 2>/dev/null && pass_test || fail_test

  # Test service-scanner.sh
  start_test "service-scanner.sh loads"
  source "$LIB_DIR/service-scanner.sh" 2>/dev/null && pass_test || fail_test

  start_test "scan_setup_scripts function exists"
  type scan_setup_scripts &>/dev/null && pass_test || fail_test

  print_summary
  ```

### Validation

```bash
# Run Phase 1 tests
./provision-host/uis/tests/run-tests.sh unit
# Expected: All tests pass

# Manual test of scanner library
source provision-host/uis/lib/service-scanner.sh
scan_setup_scripts "/mnt/urbalurbadisk/provision-host/kubernetes"
```

---

## Phase 2: Service Scripts with Metadata — ✅ DONE

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

- [x] 2.1 Create metadata wrapper for monitoring services ✓
  - **Files**: Create `provision-host/uis/services/monitoring/*.sh`
  - Scripts wrap existing `provision-host/kubernetes/11-monitoring/*.sh`
  - Add full metadata headers
  - Services: prometheus, tempo, loki, otel-collector, grafana

- [x] 2.2 Create metadata wrapper for core services ✓
  - **Files**: Create `provision-host/uis/services/core/*.sh`
  - Services: nginx, traefik (from 01-core)

- [x] 2.3 Create metadata wrapper for database services ✓
  - **Files**: Create `provision-host/uis/services/databases/*.sh`
  - Services: postgresql, mysql, mongodb, redis (from 02-databases)

- [x] 2.4 Create metadata wrapper for AI services ✓
  - **Files**: Create `provision-host/uis/services/ai/*.sh`
  - Services: openwebui, ollama, litellm, tika (from 31-ai)

- [x] 2.5 Create metadata wrapper for authentication services ✓
  - **Files**: Create `provision-host/uis/services/authentication/*.sh`
  - Services: authentik (from 21-authentication)

- [x] 2.6 Create metadata wrapper for queue services ✓
  - **Files**: Create `provision-host/uis/services/queues/*.sh`
  - Services: rabbitmq, redis (from 02-databases)

- [x] 2.7 Create metadata wrapper for search services ✓
  - **Files**: Create `provision-host/uis/services/search/*.sh`
  - Services: elasticsearch (from manifests)

- [x] 2.8 Create tests for Phase 2 metadata ✓
  - **File**: `provision-host/uis/tests/static/test-metadata.sh`
  - Validate all service scripts have required metadata fields
  - Check SCRIPT_ID, SCRIPT_NAME, SCRIPT_DESCRIPTION, SCRIPT_CATEGORY

  ```bash
  #!/bin/bash
  source "$(dirname "$0")/../lib/test-framework.sh"
  SERVICES_DIR="/mnt/urbalurbadisk/provision-host/uis/services"

  echo "=== Phase 2: Metadata Validation Tests ==="

  REQUIRED_FIELDS=(SCRIPT_ID SCRIPT_NAME SCRIPT_DESCRIPTION SCRIPT_CATEGORY)

  for script in "$SERVICES_DIR"/**/*.sh; do
      [[ -f "$script" ]] || continue
      basename=$(basename "$script")

      # Source script to get metadata
      unset SCRIPT_ID SCRIPT_NAME SCRIPT_DESCRIPTION SCRIPT_CATEGORY
      source "$script"

      for field in "${REQUIRED_FIELDS[@]}"; do
          start_test "$basename has $field"
          assert_not_empty "${!field}" "$field is empty" && pass_test
      done
  done

  print_summary
  ```

- [x] 2.9 Create tests for category validation ✓
  - **File**: `provision-host/uis/tests/static/test-categories.sh`
  - Validate SCRIPT_CATEGORY values are valid categories

- [x] 2.10 Create tests for bash syntax ✓
  - **File**: `provision-host/uis/tests/static/test-syntax.sh`
  - Run `bash -n` on all scripts to catch syntax errors early

### Validation

```bash
# Run all tests so far
./provision-host/uis/tests/run-tests.sh all
# Expected: Phase 1 + Phase 2 tests pass

# Manual test of metadata extraction
source provision-host/uis/lib/service-scanner.sh
while IFS=$'\t' read -r basename id name desc cat; do
    echo "Service: $name (ID: $id, Category: $cat)"
done < <(scan_setup_scripts "provision-host/uis/services")
```

---

## Phase 3: Config System - First-Run Initialization — ✅ DONE

Create the folder structure that gets created on first run.

### Tasks

- [x] 3.1 Create templates for `.uis.extend/` (baked into uis-provision-host container) ✓
  ```
  provision-host/uis/templates/uis.extend/
  ├── enabled-services.conf.default   # Default: nginx
  ├── enabled-tools.conf.default      # Default: kubectl, k9s
  ├── cluster-config.sh.default       # Default: rancher-desktop
  ├── service-overrides/
  │   └── .gitkeep
  └── README.md
  ```

- [x] 3.2 Create templates for `.uis.secrets/` (baked into uis-provision-host container) ✓
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

- [x] 3.3 Create `enabled-services.conf.default` ✓
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

- [x] 3.4 Create `enabled-tools.conf.default` ✓
  ```bash
  # UIS Enabled Tools
  # These are tools installed in the uis-provision-host container
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

- [x] 3.5 Create `cluster-config.sh.default` ✓
  ```bash
  # UIS Cluster Configuration
  # Edit this file to configure your cluster

  # Cluster type (see 'uis cluster types' for options)
  CLUSTER_TYPE="rancher-desktop"

  # Project name (used for namespaces, labels)
  PROJECT_NAME="uis"

  # Base domain for services
  BASE_DOMAIN="localhost"

  # Target host for Ansible (matches inventory)
  TARGET_HOST="rancher-desktop"
  ```

- [x] 3.6 Create first-run initialization library ✓
  - **File**: `provision-host/uis/lib/first-run.sh`
  - **NOTE**: Folder creation happens on HOST (see Architecture section)
  - This library provides helper functions for the CONTAINER to:
    - Check if config has been initialized
    - Copy default templates to mounted .uis.extend/
    - Validate configuration structure
  - Function: `check_first_run()` - Checks if `.uis.extend/enabled-services.conf` exists
  - Function: `copy_defaults_if_missing()` - Copies .default templates to mounted volume
  - Function: `validate_config_structure()` - Verifies required files exist

  ```bash
  # first-run.sh - First-run helpers (runs INSIDE container)
  # NOTE: Folder creation (.uis.extend/, .uis.secrets/) happens on HOST in wrapper script
  # This library manages CONTENTS of those folders

  EXTEND_DIR="${EXTEND_DIR:-/mnt/urbalurbadisk/.uis.extend}"
  SECRETS_DIR="${SECRETS_DIR:-/mnt/urbalurbadisk/.uis.secrets}"
  TEMPLATES_DIR="${TEMPLATES_DIR:-/mnt/urbalurbadisk/provision-host/uis/templates}"

  # Check if first-run setup has been completed
  # Returns: 0 if configured, 1 if needs setup
  check_first_run() {
      [[ -f "$EXTEND_DIR/enabled-services.conf" ]]
  }

  # Copy default config files if they don't exist
  # Called when container starts with empty mounted volumes
  copy_defaults_if_missing() {
      local templates_extend="$TEMPLATES_DIR/uis.extend"

      # Copy enabled-services.conf
      if [[ ! -f "$EXTEND_DIR/enabled-services.conf" ]]; then
          cp "$templates_extend/enabled-services.conf.default" "$EXTEND_DIR/enabled-services.conf"
          log_info "Created enabled-services.conf with defaults"
      fi

      # Copy cluster-config.sh
      if [[ ! -f "$EXTEND_DIR/cluster-config.sh" ]]; then
          cp "$templates_extend/cluster-config.sh.default" "$EXTEND_DIR/cluster-config.sh"
          log_info "Created cluster-config.sh with defaults"
      fi

      # Copy enabled-tools.conf
      if [[ ! -f "$EXTEND_DIR/enabled-tools.conf" ]]; then
          cp "$templates_extend/enabled-tools.conf.default" "$EXTEND_DIR/enabled-tools.conf"
          log_info "Created enabled-tools.conf with defaults"
      fi
  }

  # Validate that config structure is correct
  # Returns: 0 if valid, dies with error if invalid
  validate_config_structure() {
      [[ -d "$EXTEND_DIR" ]] || die_config ".uis.extend/ not mounted"
      [[ -d "$SECRETS_DIR" ]] || die_config ".uis.secrets/ not mounted"
      [[ -f "$EXTEND_DIR/enabled-services.conf" ]] || die_config "enabled-services.conf missing"
  }
  ```

- [x] 3.7 Create service deployment library ✓
  - **File**: `provision-host/uis/lib/service-deployment.sh`
  - Function: `deploy_enabled_services()` - reads config, deploys matching services
  - Function: `deploy_single_service()` - deploys one service with validation
  - Function: `remove_single_service()` - removes one service
  - Function: `check_dependencies()` - verify required services are deployed
  - Dependency resolution using SCRIPT_REQUIRES
  - Pattern: Based on DCT `tool-installation.sh`

  ```bash
  # service-deployment.sh - Service deployment logic

  source "$(dirname "${BASH_SOURCE[0]}")/service-scanner.sh"
  source "$(dirname "${BASH_SOURCE[0]}")/logging.sh"
  source "$(dirname "${BASH_SOURCE[0]}")/utilities.sh"

  CONFIG_DIR="${CONFIG_DIR:-/mnt/urbalurbadisk/.uis.extend}"

  # Deploy all services listed in enabled-services.conf
  # Usage: deploy_enabled_services
  deploy_enabled_services() {
      local config_file="$CONFIG_DIR/enabled-services.conf"

      if [[ ! -f "$config_file" ]]; then
          die_config "enabled-services.conf not found at $config_file"
      fi

      local services=()
      while IFS= read -r line; do
          # Skip comments and empty lines
          [[ "$line" =~ ^[[:space:]]*# ]] && continue
          [[ -z "${line// }" ]] && continue
          services+=("$line")
      done < "$config_file"

      if [[ ${#services[@]} -eq 0 ]]; then
          log_warn "No services enabled in $config_file"
          return 0
      fi

      log_info "Deploying ${#services[@]} enabled service(s)..."

      for service_id in "${services[@]}"; do
          deploy_single_service "$service_id" || return $?
      done

      log_success "All enabled services deployed"
  }

  # Deploy a single service by ID
  # Usage: deploy_single_service <service_id>
  deploy_single_service() {
      local service_id="$1"
      local script=$(find_service_script "$service_id")

      if [[ -z "$script" ]]; then
          die_config "Service '$service_id' not found"
      fi

      # Load service metadata
      source "$script" 2>/dev/null

      log_info "Deploying $SCRIPT_NAME ($service_id)..."

      # Check dependencies first
      if [[ -n "$SCRIPT_REQUIRES" ]]; then
          check_dependencies "$SCRIPT_REQUIRES" || return $?
      fi

      # Determine deployment method
      if [[ -n "$SCRIPT_PLAYBOOK" ]]; then
          # Ansible deployment
          local playbook_path="/mnt/urbalurbadisk/ansible/playbooks/$SCRIPT_PLAYBOOK"
          if [[ ! -f "$playbook_path" ]]; then
              die_config "Playbook not found: $SCRIPT_PLAYBOOK"
          fi
          ansible-playbook "$playbook_path" || die_k8s "Playbook failed: $SCRIPT_PLAYBOOK"

      elif [[ -n "$SCRIPT_MANIFEST" ]]; then
          # Direct manifest deployment
          local manifest_path="/mnt/urbalurbadisk/manifests/$SCRIPT_MANIFEST"
          if [[ ! -f "$manifest_path" ]]; then
              die_config "Manifest not found: $SCRIPT_MANIFEST"
          fi
          kubectl apply -f "$manifest_path" || die_k8s "Manifest apply failed: $SCRIPT_MANIFEST"

      else
          die_config "Service '$service_id' has no SCRIPT_PLAYBOOK or SCRIPT_MANIFEST"
      fi

      # Verify deployment
      if check_service_deployed "$service_id"; then
          log_success "$SCRIPT_NAME deployed successfully"
      else
          log_warn "$SCRIPT_NAME deployed but health check failed (may need time to start)"
      fi
  }

  # Remove a single service by ID
  # Usage: remove_single_service <service_id>
  remove_single_service() {
      local service_id="$1"
      local script=$(find_service_script "$service_id")

      if [[ -z "$script" ]]; then
          die_config "Service '$service_id' not found"
      fi

      source "$script" 2>/dev/null

      if [[ -z "$SCRIPT_REMOVE" ]]; then
          die_config "Service '$service_id' has no removal script defined"
      fi

      log_info "Removing $SCRIPT_NAME ($service_id)..."

      local remove_script="/mnt/urbalurbadisk/provision-host/kubernetes/$SCRIPT_REMOVE"
      if [[ -f "$remove_script" ]]; then
          bash "$remove_script" || die_k8s "Removal script failed"
      else
          log_warn "Removal script not found, attempting manifest delete..."
          [[ -n "$SCRIPT_MANIFEST" ]] && kubectl delete -f "/mnt/urbalurbadisk/manifests/$SCRIPT_MANIFEST" --ignore-not-found
      fi

      log_success "$SCRIPT_NAME removed"
  }

  # Check if required dependencies are deployed
  # Usage: check_dependencies "service1 service2 service3"
  check_dependencies() {
      local requires="$1"
      for dep in $requires; do
          if ! check_service_deployed "$dep"; then
              die_dependency "Required service '$dep' is not deployed"
          fi
      done
  }
  ```

- [x] 3.8 Create default secrets with working localhost values ✓
  - **File**: `provision-host/uis/templates/default-secrets.env`
  - Contains working defaults for localhost development:
    ```bash
    DEFAULT_ADMIN_EMAIL=admin@localhost
    DEFAULT_ADMIN_PASSWORD=LocalDev123!
    DEFAULT_DATABASE_PASSWORD=LocalDevDB456!
    ```
  - Used when no `.uis.secrets/` exists (zero-config start)

- [x] 3.9 Create tests for Phase 3 config system ✓
  - **File**: `provision-host/uis/tests/unit/test-phase3-config.sh`
  - Test first-run.sh functions exist
  - Test service-deployment.sh functions exist
  - Test template files exist
  - Test config file parsing

  ```bash
  #!/bin/bash
  source "$(dirname "$0")/../lib/test-framework.sh"
  LIB_DIR="/mnt/urbalurbadisk/provision-host/uis/lib"
  TEMPLATES_DIR="/mnt/urbalurbadisk/provision-host/uis/templates"

  echo "=== Phase 3: Config System Tests ==="

  # Test first-run.sh
  start_test "first-run.sh loads"
  source "$LIB_DIR/first-run.sh" 2>/dev/null && pass_test || fail_test

  for fn in check_first_run initialize_uis update_gitignore; do
      start_test "first-run.sh defines $fn"
      type $fn &>/dev/null && pass_test || fail_test
  done

  # Test service-deployment.sh
  start_test "service-deployment.sh loads"
  source "$LIB_DIR/service-deployment.sh" 2>/dev/null && pass_test || fail_test

  for fn in deploy_enabled_services deploy_single_service; do
      start_test "service-deployment.sh defines $fn"
      type $fn &>/dev/null && pass_test || fail_test
  done

  # Test templates exist
  start_test "enabled-services.conf.default exists"
  [[ -f "$TEMPLATES_DIR/uis.extend/enabled-services.conf.default" ]] && pass_test || fail_test

  start_test "cluster-config.sh.default exists"
  [[ -f "$TEMPLATES_DIR/uis.extend/cluster-config.sh.default" ]] && pass_test || fail_test

  print_summary
  ```

### Validation

```bash
# Run all tests so far
./provision-host/uis/tests/run-tests.sh all
# Expected: Phase 1 + Phase 2 + Phase 3 tests pass

# Integration test: first-run (in a fresh directory)
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

## Phase 4: CLI Entry Point — ✅ DONE

Create the CLI that the `./uis` wrapper calls into.

### Tasks

- [x] 4.1 Create `manage/uis-cli.sh` ✓
  - Entry point for all UIS commands
  - Sources required libraries
  - Routes commands to appropriate functions

  **Commands for this plan**:
  ```bash
  # Service Discovery
  uis list                    # List available services with status
  uis status                  # Show deployed services health

  # Service Deployment
  uis deploy                  # Deploy all enabled services
  uis deploy <service>        # Deploy specific service
  uis remove <service>        # Remove specific service

  # Config Management
  uis enable <service>        # Add service to enabled-services.conf
  uis disable <service>       # Remove service from enabled-services.conf
  uis list-enabled            # Show enabled services

  # Info
  uis version                 # Show UIS version
  uis help                    # Show help
  ```

- [x] 4.2 Implement `uis list` command ✓
  - Scans all service scripts
  - Shows: ID, Name, Category, Status (deployed/not deployed)
  - Groups by category
  - Pattern: Like `kubectl get pods` output

  ```
  CATEGORY        ID              NAME            STATUS
  ─────────────────────────────────────────────────────────
  CORE            nginx           Nginx           ✅ Deployed
  CORE            traefik         Traefik         ✅ Deployed
  MONITORING      prometheus      Prometheus      ❌ Not deployed
  MONITORING      grafana         Grafana         ❌ Not deployed
  DATABASES       postgresql      PostgreSQL      ❌ Not deployed
  AI              openwebui       Open WebUI      ❌ Not deployed
  ```

- [x] 4.3 Implement `uis status` command ✓
  - Shows currently deployed services
  - Checks SCRIPT_CHECK_COMMAND for each
  - Shows health status

- [x] 4.4 Implement `uis deploy` command ✓
  - Without args: deploys all services from enabled-services.conf
  - With service ID: deploys that specific service
  - Resolves dependencies automatically
  - Shows progress

  ```bash
  ./uis deploy
  # Output:
  #   Using built-in defaults for localhost development
  #   ✓ Deploying nginx...
  #   ✓ nginx deployed successfully
  #
  #   Services available at http://*.localhost
  ```

- [x] 4.5 Implement `uis remove` command ✓
  - Finds matching removal script (SCRIPT_REMOVE metadata)
  - Warns about dependent services
  - Requires confirmation

- [x] 4.6 Implement `uis enable/disable` commands ✓
  - **File**: `provision-host/uis/lib/service-auto-enable.sh`
  - `enable_service()` - Add SCRIPT_ID to enabled-services.conf
  - `disable_service()` - Remove SCRIPT_ID from enabled-services.conf
  - `is_service_enabled()` - Check if service is in config
  - `list_enabled_services()` - Show all enabled services
  - Pattern: Based on DCT `service-auto-enable.sh`
  - Auto-enable when service is successfully deployed
  - Keep comments and formatting in config file

- [ ] 4.7 Update `./uis` wrapper script (deferred to integration)
  - Route new commands to `uis-cli.sh`
  - Keep existing commands working (shell, provision, start, stop)
  - First-run detection and folder creation

- [x] 4.8 Create tests for Phase 4 CLI commands ✓
  - **File**: `provision-host/uis/tests/unit/test-phase4-cli.sh`
  - Test CLI help command
  - Test CLI version command
  - Test CLI list command (no cluster needed)
  - Test service-auto-enable.sh functions

  ```bash
  #!/bin/bash
  source "$(dirname "$0")/../lib/test-framework.sh"
  UIS_CLI="/mnt/urbalurbadisk/provision-host/uis/manage/uis-cli.sh"
  LIB_DIR="/mnt/urbalurbadisk/provision-host/uis/lib"

  echo "=== Phase 4: CLI Command Tests ==="

  # Test CLI exists and is executable
  start_test "uis-cli.sh exists"
  [[ -f "$UIS_CLI" ]] && pass_test || fail_test

  start_test "uis-cli.sh is executable"
  [[ -x "$UIS_CLI" ]] && pass_test || fail_test

  # Test help command
  start_test "uis help runs without error"
  "$UIS_CLI" help >/dev/null 2>&1 && pass_test || fail_test

  start_test "uis help shows Usage"
  output=$("$UIS_CLI" help 2>&1)
  [[ "$output" == *"Usage"* ]] && pass_test || fail_test "No 'Usage' in help output"

  # Test version command
  start_test "uis version runs without error"
  "$UIS_CLI" version >/dev/null 2>&1 && pass_test || fail_test

  # Test list command (doesn't require cluster)
  start_test "uis list runs without error"
  "$UIS_CLI" list >/dev/null 2>&1 && pass_test || fail_test

  # Test service-auto-enable.sh
  start_test "service-auto-enable.sh loads"
  source "$LIB_DIR/service-auto-enable.sh" 2>/dev/null && pass_test || fail_test

  for fn in enable_service disable_service is_service_enabled list_enabled_services; do
      start_test "service-auto-enable.sh defines $fn"
      type $fn &>/dev/null && pass_test || fail_test
  done

  # Test unknown command returns error
  start_test "uis unknown-cmd returns error"
  "$UIS_CLI" unknown-cmd >/dev/null 2>&1
  [[ $? -ne 0 ]] && pass_test || fail_test "Unknown command should fail"

  print_summary
  ```

- [x] 4.9 Create integration test for enable/disable cycle ✓
  - **File**: `provision-host/uis/tests/unit/test-enable-disable.sh`
  - Test enable adds service to config
  - Test disable removes service from config
  - Test list-enabled shows correct services

### Validation

```bash
# Run all tests
./provision-host/uis/tests/run-tests.sh all
# Expected: All Phase 1-4 tests pass

# Manual integration tests
./uis list                    # Shows all services with status
./uis status                  # Shows deployed services
./uis enable prometheus       # Adds to enabled-services.conf
./uis list-enabled            # Shows: nginx, prometheus
./uis deploy                  # Deploys all enabled services
./uis deploy grafana          # Deploys specific service (auto-enables)
./uis disable prometheus      # Removes from enabled-services.conf
./uis remove grafana          # Removes service (prompts to disable)
```

---

## Acceptance Criteria

### Functionality
- [ ] First-run creates `.uis.extend/` and `.uis.secrets/` folders
- [ ] First-run updates `.gitignore` to ignore `.uis.secrets/`
- [ ] `./uis list` shows all available services with metadata
- [ ] `./uis status` shows deployed services with health check
- [ ] `./uis enable <service>` adds service to enabled-services.conf
- [ ] `./uis disable <service>` removes service from enabled-services.conf
- [ ] `./uis list-enabled` shows currently enabled services
- [ ] `./uis deploy` deploys services from enabled-services.conf
- [ ] `./uis deploy <service>` deploys specific service (auto-enables)
- [ ] `./uis remove <service>` removes service cleanly
- [ ] Zero-config: `./uis deploy` works with built-in defaults
- [ ] Existing `./uis provision` continues to work (backwards compatible)
- [ ] New system runs alongside existing `provision-host/kubernetes/`

### Testing (run tests after each phase)
- [ ] `./run-tests.sh unit` passes after Phase 1
- [ ] `./run-tests.sh static` passes after Phase 2
- [ ] `./run-tests.sh all` passes after Phase 3
- [ ] `./run-tests.sh all` passes after Phase 4
- [ ] All service scripts pass syntax check (`bash -n`)
- [ ] All service scripts have required metadata fields

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
| **CLI** | |
| `provision-host/uis/manage/uis-cli.sh` | CLI entry point |
| **Service Wrappers** | |
| `provision-host/uis/services/core/*.sh` | Core service wrappers |
| `provision-host/uis/services/monitoring/*.sh` | Monitoring service wrappers |
| `provision-host/uis/services/databases/*.sh` | Database service wrappers |
| `provision-host/uis/services/ai/*.sh` | AI service wrappers |
| `provision-host/uis/services/authentication/*.sh` | Auth service wrappers |
| `provision-host/uis/services/queues/*.sh` | Queue service wrappers |
| `provision-host/uis/services/search/*.sh` | Search service wrappers |
| **Templates** | |
| `provision-host/uis/templates/uis.extend/enabled-services.conf.default` | Default services |
| `provision-host/uis/templates/uis.extend/enabled-tools.conf.default` | Default tools |
| `provision-host/uis/templates/uis.extend/cluster-config.sh.default` | Default cluster config |
| `provision-host/uis/templates/uis.extend/README.md` | Documentation |
| `provision-host/uis/templates/uis.secrets/README.md` | Documentation |
| `provision-host/uis/templates/uis.secrets/.gitignore` | Ignore pattern |
| `provision-host/uis/templates/default-secrets.env` | Working localhost defaults |
| **Test Framework** | |
| `provision-host/uis/tests/lib/test-framework.sh` | Test assertions and runners |
| `provision-host/uis/tests/run-tests.sh` | Test orchestrator |
| `provision-host/uis/tests/unit/test-phase1-libraries.sh` | Phase 1 library tests |
| `provision-host/uis/tests/static/test-metadata.sh` | Metadata validation tests |
| `provision-host/uis/tests/static/test-categories.sh` | Category validation tests |
| `provision-host/uis/tests/static/test-syntax.sh` | Bash syntax tests |
| `provision-host/uis/tests/unit/test-phase3-config.sh` | Phase 3 config tests |
| `provision-host/uis/tests/unit/test-phase4-cli.sh` | Phase 4 CLI tests |
| `provision-host/uis/tests/unit/test-enable-disable.sh` | Enable/disable integration test |
| **Other** | |
| `provision-host/uis/.version` | Version file |

## Files to Modify

| File | Change |
|------|--------|
| `uis` | Add routing to uis-cli.sh for new commands |
| `Dockerfile.uis-provision-host` | Include provision-host/uis/ folder |
| `.github/workflows/build-uis-container.yml` | Include uis/ in container build |

---

## Gaps Identified

### Resolved in This Plan

1. ~~**Error handling**~~ - ✅ Defined in "Error Handling Strategy" section above
   - Exit codes defined (0-4)
   - Error helper functions defined (`die`, `die_config`, `die_k8s`, `die_dependency`)
   - Deployment failure behavior documented

2. ~~**Container vs Host boundary**~~ - ✅ Defined in "Architecture" section above
   - Clear separation of what runs where
   - First-run responsibility clarified (HOST creates folders, CONTAINER copies templates)

3. ~~**Undefined functions**~~ - ✅ All functions now have explicit implementations:
   - `scan_setup_scripts()`, `extract_script_metadata()`, `check_service_deployed()`, `get_service_value()`, `find_service_script()`
   - `deploy_enabled_services()`, `deploy_single_service()`, `remove_single_service()`, `check_dependencies()`
   - `generate_categories_json_internal()`
   - `check_first_run()`, `copy_defaults_if_missing()`, `validate_config_structure()`

### Remaining Gaps (To Address During Implementation)

4. **Logging verbosity** - Need `-v` or `--verbose` flag for debugging

5. **Dry-run mode** - `uis deploy --dry-run` to show what would be deployed

6. **Circular dependencies** - Need to detect and report circular SCRIPT_REQUIRES gracefully

7. **Rollback on failure** - Current design: NO automatic rollback (too risky). User must manually clean up.

---

## Next Plan

After completing this plan, proceed to:
- [PLAN-004B-menu-secrets.md](./PLAN-004B-menu-secrets.md) - Interactive menu and secrets management
