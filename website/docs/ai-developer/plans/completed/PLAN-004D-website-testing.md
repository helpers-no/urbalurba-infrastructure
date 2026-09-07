# PLAN-004D: Website JSON Generation & Testing Framework

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed

**Goal**: Create JSON generation for website service catalog, deploy tests, and CI/CD integration.

**Last Updated**: 2026-01-22

**Part of**: [PLAN-004-uis-orchestration-system.md](./PLAN-004-uis-orchestration-system.md) (Epic)

**Prerequisites**: [PLAN-004A-core-cli.md](./PLAN-004A-core-cli.md) - Core CLI system (Phases 1-2 for metadata)

**Priority**: Medium

**Delivers**:
- `uis-docs.sh` - JSON generator for Docusaurus website
- `services.json`, `categories.json`, `tools.json` - Website data files
- Deploy tests (full deploy/remove cycle)
- CI/CD integration (GitHub Actions for tests and JSON generation)

---

## Overview

This plan provides:
1. **JSON Generation** (Phase 9) - Generate website data from service metadata
2. **CI/CD & Deploy Tests** (Phase 10) - GitHub Actions and cluster-level testing

**Note**: Basic test framework (unit tests, static tests) is created in [PLAN-004A](./PLAN-004A-core-cli.md) alongside the code it tests. This plan adds:
- **Deploy tests** that require a Kubernetes cluster
- **JSON validation tests** for generated website data
- **CI/CD pipelines** to run tests automatically

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

- [x] 9.1 Create `uis-docs.sh` generator script ✅
  - **File**: `provision-host/uis/manage/uis-docs.sh`
  - Pattern: Based on DCT `dev-docs.sh`
  - Scans service scripts and tool scripts for metadata
  - Generates JSON output

  ```bash
  #!/bin/bash
  # uis-docs.sh - Generate JSON documentation for website
  #
  # Usage: ./uis-docs.sh [output-dir]
  #
  # Scans service and tool scripts for metadata and generates:
  #   - services.json   - All services with metadata
  #   - categories.json - Category definitions
  #   - tools.json      - Optional CLI tools

  set -e

  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LIB_DIR="$SCRIPT_DIR/../lib"
  SERVICES_DIR="$SCRIPT_DIR/../services"
  TOOLS_DIR="$SCRIPT_DIR/../tools"

  # Default output directory
  OUTPUT_DIR="${1:-/mnt/urbalurbadisk/website/src/data}"

  source "$LIB_DIR/service-scanner.sh"
  source "$LIB_DIR/categories.sh"
  source "$LIB_DIR/logging.sh"

  generate_services_json() {
      local output_file="$OUTPUT_DIR/services.json"
      log_info "Generating services.json..."

      echo '{"services": [' > "$output_file"
      local first=true

      while IFS=$'\t' read -r basename id name desc cat; do
          # Extract additional metadata from script
          local script_path
          script_path=$(find "$SERVICES_DIR" -name "$basename" -type f)

          # Source script to get all metadata
          source "$script_path"

          [[ "$first" != "true" ]] && echo "," >> "$output_file"
          first=false

          cat >> "$output_file" <<EOF
    {
      "id": "$SCRIPT_ID",
      "type": "service",
      "name": "$SCRIPT_NAME",
      "description": "$SCRIPT_DESCRIPTION",
      "category": "$SCRIPT_CATEGORY",
      "abstract": "${SCRIPT_ABSTRACT:-$SCRIPT_DESCRIPTION}",
      "logo": "${SCRIPT_LOGO:-}",
      "website": "${SCRIPT_WEBSITE:-}",
      "playbook": "${SCRIPT_PLAYBOOK:-}",
      "manifest": "${SCRIPT_MANIFEST:-}",
      "priority": "${SCRIPT_PRIORITY:-50}"
    }
EOF
      done < <(scan_setup_scripts "$SERVICES_DIR")

      echo ']}' >> "$output_file"
      log_success "Generated $output_file"
  }

  generate_categories_json() {
      local output_file="$OUTPUT_DIR/categories.json"
      log_info "Generating categories.json..."

      # Use categories.sh definitions
      generate_categories_json_internal > "$output_file"
      log_success "Generated $output_file"
  }

  generate_tools_json() {
      local output_file="$OUTPUT_DIR/tools.json"
      log_info "Generating tools.json..."

      echo '{"tools": [' > "$output_file"
      local first=true

      # Built-in tools
      for tool in kubectl k9s helm ansible; do
          [[ "$first" != "true" ]] && echo "," >> "$output_file"
          first=false
          cat >> "$output_file" <<EOF
    {
      "id": "$tool",
      "type": "tool",
      "name": "$tool",
      "description": "Built-in tool",
      "builtin": true
    }
EOF
      done

      # Optional tools from install scripts
      for script in "$TOOLS_DIR"/install-*.sh; do
          [[ -f "$script" ]] || continue
          source "$script"

          [[ "$first" != "true" ]] && echo "," >> "$output_file"
          first=false

          cat >> "$output_file" <<EOF
    {
      "id": "$SCRIPT_ID",
      "type": "tool",
      "name": "$SCRIPT_NAME",
      "description": "$SCRIPT_DESCRIPTION",
      "category": "${SCRIPT_CATEGORY:-TOOLS}",
      "size": "${SCRIPT_SIZE:-unknown}",
      "builtin": false
    }
EOF
      done

      echo ']}' >> "$output_file"
      log_success "Generated $output_file"
  }

  # Main
  mkdir -p "$OUTPUT_DIR"
  generate_services_json
  generate_categories_json
  generate_tools_json

  log_info "JSON generation complete"
  ```

- [x] 9.2 Generate `services.json` ✅
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
        "abstract": "Time-series database for metrics",
        "logo": "prometheus-logo.webp",
        "website": "https://prometheus.io",
        "playbook": "030-setup-prometheus.yml",
        "manifest": "030-prometheus-config.yaml",
        "priority": "10"
      },
      {
        "id": "grafana",
        "type": "service",
        "name": "Grafana",
        "description": "Visualization and dashboards",
        "category": "MONITORING",
        "abstract": "Observability platform for metrics and logs",
        "logo": "grafana-logo.webp",
        "website": "https://grafana.com",
        "playbook": "034-setup-grafana.yml",
        "manifest": "034-grafana-config.yaml",
        "priority": "20"
      }
    ]
  }
  ```

- [x] 9.3 Generate `categories.json` ✅
  - **Output**: `website/src/data/categories.json`
  - Contains UIS service categories:

  ```json
  {
    "categories": [
      {
        "id": "CORE",
        "name": "Core Infrastructure",
        "order": 0,
        "description": "Essential infrastructure services",
        "icon": "server"
      },
      {
        "id": "MONITORING",
        "name": "Observability",
        "order": 1,
        "description": "Metrics, logs, and tracing",
        "icon": "chart-line"
      },
      {
        "id": "DATABASES",
        "name": "Databases",
        "order": 2,
        "description": "Data storage and caching",
        "icon": "database"
      },
      {
        "id": "AI",
        "name": "AI & Machine Learning",
        "order": 3,
        "description": "AI models and inference",
        "icon": "brain"
      },
      {
        "id": "AUTHENTICATION",
        "name": "Authentication",
        "order": 4,
        "description": "Identity and access management",
        "icon": "shield"
      },
      {
        "id": "QUEUES",
        "name": "Message Queues",
        "order": 5,
        "description": "Async messaging and event streams",
        "icon": "inbox"
      },
      {
        "id": "SEARCH",
        "name": "Search",
        "order": 6,
        "description": "Full-text search and indexing",
        "icon": "search"
      },
      {
        "id": "MANAGEMENT",
        "name": "Management",
        "order": 7,
        "description": "Admin tools and GitOps",
        "icon": "cog"
      }
    ]
  }
  ```

- [x] 9.4 Generate `tools.json` ✅
  - **Output**: `website/src/data/tools.json`
  - Contains optional CLI tools:

  ```json
  {
    "tools": [
      {
        "id": "kubectl",
        "type": "tool",
        "name": "Kubernetes CLI",
        "description": "Command-line tool for Kubernetes",
        "builtin": true
      },
      {
        "id": "k9s",
        "type": "tool",
        "name": "K9s",
        "description": "Terminal UI for Kubernetes",
        "builtin": true
      },
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
        "id": "aws-cli",
        "type": "tool",
        "name": "AWS CLI",
        "description": "Command-line interface for Amazon Web Services",
        "category": "CLOUD_TOOLS",
        "size": "~200MB",
        "builtin": false
      },
      {
        "id": "gcp-cli",
        "type": "tool",
        "name": "Google Cloud CLI",
        "description": "Command-line interface for Google Cloud",
        "category": "CLOUD_TOOLS",
        "size": "~500MB",
        "builtin": false
      }
    ]
  }
  ```

- [x] 9.5 Update `categories.sh` to support JSON export ✅ (already exists)
  - **File**: `provision-host/uis/lib/categories.sh` (update)
  - Add function: `generate_categories_json_internal()` that outputs category JSON

- [x] 9.6 Add GitHub Action to regenerate JSON ✅
  - **File**: `.github/workflows/generate-uis-docs.yml`
  - Triggers on changes to service/tool scripts
  - Runs `uis-docs.sh` inside container and commits updated JSON

  ```yaml
  name: Generate UIS Documentation

  on:
    push:
      branches: [main]
      paths:
        - 'provision-host/uis/services/**'
        - 'provision-host/uis/tools/**'
        - 'provision-host/uis/lib/categories.sh'
    workflow_dispatch:

  jobs:
    generate:
      runs-on: ubuntu-latest
      steps:
        - uses: actions/checkout@v4

        - name: Set up Docker
          uses: docker/setup-buildx-action@v3

        - name: Pull UIS container
          run: docker pull ghcr.io/terchris/uis-provision-host:latest

        - name: Generate JSON files
          run: |
            docker run --rm \
              -v "${{ github.workspace }}:/mnt/urbalurbadisk" \
              ghcr.io/terchris/uis-provision-host:latest \
              /mnt/urbalurbadisk/provision-host/uis/manage/uis-docs.sh \
              /mnt/urbalurbadisk/website/src/data

        - name: Check for changes
          id: git-check
          run: |
            git diff --exit-code website/src/data/ || echo "changes=true" >> $GITHUB_OUTPUT

        - name: Commit changes
          if: steps.git-check.outputs.changes == 'true'
          run: |
            git config --local user.email "github-actions[bot]@users.noreply.github.com"
            git config --local user.name "github-actions[bot]"
            git add website/src/data/
            git commit -m "chore: regenerate UIS documentation JSON"
            git push
  ```

- [x] 9.7 Add CLI command for manual generation ✅
  - **Command**: `uis docs generate`
  - Calls `uis-docs.sh` with appropriate output path
  - Useful for local development

### Validation

```bash
# Run inside uis-provision-host container
./provision-host/uis/manage/uis-docs.sh

# Outputs:
#   ✅ Generated website/src/data/services.json (15 services)
#   ✅ Generated website/src/data/categories.json (8 categories)
#   ✅ Generated website/src/data/tools.json (8 tools)

# Validate JSON is valid
jq . website/src/data/services.json > /dev/null && echo "services.json: valid"
jq . website/src/data/categories.json > /dev/null && echo "categories.json: valid"
jq . website/src/data/tools.json > /dev/null && echo "tools.json: valid"

# Preview locally
cd website && npm start
# Browse to services catalog page
```

---

## Phase 10: CI/CD Integration & Deploy Tests

Add CI/CD pipelines and cluster-level deploy tests.

> **Note**: Basic test framework (unit tests, static tests) is created in [PLAN-004A](./PLAN-004A-core-cli.md) alongside the code it tests. This phase adds JSON validation, deploy tests, and CI/CD.

### What's Already in PLAN-004A

| Test | Created In | Purpose |
|------|------------|---------|
| `test-framework.sh` | 004A Phase 1 | Assertions, test runners |
| `test-phase1-libraries.sh` | 004A Phase 1 | Library loading tests |
| `test-metadata.sh` | 004A Phase 2 | Metadata validation |
| `test-categories.sh` | 004A Phase 2 | Category validation |
| `test-syntax.sh` | 004A Phase 2 | Bash syntax check |
| `test-phase3-config.sh` | 004A Phase 3 | Config system tests |
| `test-phase4-cli.sh` | 004A Phase 4 | CLI command tests |

### What This Phase Adds

| Test/Config | Purpose |
|-------------|---------|
| `test-generated-json.sh` | Validate JSON files from Phase 9 |
| `test-deploy-cycle.sh` | Full deploy/remove (needs cluster) |
| `.github/workflows/test-uis.yml` | CI/CD for automated testing |
| `.github/workflows/generate-uis-docs.yml` | Auto-regenerate JSON |

### Tasks

- [x] 10.1 Create JSON validation tests ✅
  - **File**: `provision-host/uis/tests/static/test-generated-json.sh`
  - Validates JSON files generated by Phase 9
  - Uses test framework from PLAN-004A

  ```bash
  #!/bin/bash
  source "$(dirname "$0")/../lib/test-framework.sh"
  DATA_DIR="${DATA_DIR:-/mnt/urbalurbadisk/website/src/data}"

  echo "=== JSON Validation Tests ==="

  # Test files exist
  for file in services.json categories.json tools.json; do
      start_test "$file exists"
      [[ -f "$DATA_DIR/$file" ]] && pass_test || fail_test
  done

  # Test valid JSON
  for file in services.json categories.json tools.json; do
      start_test "$file is valid JSON"
      jq . "$DATA_DIR/$file" >/dev/null 2>&1 && pass_test || fail_test
  done

  # Test services.json has content
  start_test "services.json has services"
  count=$(jq '.services | length' "$DATA_DIR/services.json" 2>/dev/null)
  [[ "$count" -gt 0 ]] && pass_test || fail_test "No services found"

  # Test categories.json has content
  start_test "categories.json has categories"
  count=$(jq '.categories | length' "$DATA_DIR/categories.json" 2>/dev/null)
  [[ "$count" -gt 0 ]] && pass_test || fail_test "No categories found"

  print_summary
  ```

- [x] 10.2 Create deploy tests ✅
  - **File**: `provision-host/uis/tests/deploy/test-deploy-cycle.sh`
  - Deploy service → verify running → remove → verify removed
  - **Requires**: Running Kubernetes cluster

  ```bash
  #!/bin/bash
  # test-deploy-cycle.sh - Test full deploy/remove cycle
  #
  # WARNING: This test modifies the Kubernetes cluster!
  # Only run when explicitly requested.

  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR/../lib/test-framework.sh"

  UIS_CLI="${UIS_CLI:-/mnt/urbalurbadisk/provision-host/uis/manage/uis-cli.sh}"
  TEST_SERVICE="${TEST_SERVICE:-nginx}"

  print_section "Deploy Tests: Full Cycle"
  echo ""
  echo "⚠️  WARNING: This test modifies the Kubernetes cluster!"
  echo "Service being tested: $TEST_SERVICE"
  echo ""

  # Check cluster connectivity first
  start_test "Kubernetes cluster is accessible"
  if kubectl cluster-info >/dev/null 2>&1; then
      pass_test
  else
      fail_test "Cannot connect to Kubernetes cluster"
      echo "Skipping deploy tests - no cluster connection"
      print_summary
      exit 1
  fi

  # Ensure service is not deployed
  start_test "Service is initially not deployed (or being removed)"
  "$UIS_CLI" remove "$TEST_SERVICE" 2>/dev/null || true
  sleep 5
  pass_test

  # Deploy service
  start_test "Deploy $TEST_SERVICE"
  if "$UIS_CLI" deploy "$TEST_SERVICE" 2>&1; then
      pass_test
  else
      fail_test "Deploy failed"
  fi

  # Wait for deployment
  sleep 10

  # Verify service is running
  start_test "Service shows as deployed"
  status=$("$UIS_CLI" status 2>&1)
  if [[ "$status" == *"$TEST_SERVICE"* ]] && [[ "$status" == *"✅"* || "$status" == *"Running"* ]]; then
      pass_test
  else
      fail_test "Service not showing as deployed"
  fi

  # Remove service
  start_test "Remove $TEST_SERVICE"
  if "$UIS_CLI" remove "$TEST_SERVICE" 2>&1; then
      pass_test
  else
      fail_test "Remove failed"
  fi

  # Wait for removal
  sleep 10

  # Verify service is removed
  start_test "Service shows as not deployed"
  status=$("$UIS_CLI" status 2>&1)
  if [[ "$status" != *"$TEST_SERVICE"*"Running"* ]]; then
      pass_test
  else
      fail_test "Service still running after removal"
  fi

  print_summary
  ```

- [x] 10.3 Add `deploy` option to test orchestrator ✅ (already exists)
  - **File**: `provision-host/uis/tests/run-tests.sh`
  - Run by level: `./run-tests.sh static|unit|deploy|all`

  ```bash
  #!/bin/bash
  # run-tests.sh - UIS Test Orchestrator
  #
  # Usage:
  #   ./run-tests.sh static    # Run static tests (fast)
  #   ./run-tests.sh unit      # Run unit tests (fast)
  #   ./run-tests.sh deploy    # Run deploy tests (slow, needs cluster)
  #   ./run-tests.sh all       # Run all tests
  #
  # Options:
  #   --verbose     Show detailed output
  #   --help        Show this help

  set -e

  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  # Colors
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  BOLD='\033[1m'
  NC='\033[0m'

  TOTAL_PASSED=0
  TOTAL_FAILED=0

  show_help() {
      cat << EOF
  UIS Test Orchestrator

  Usage: $0 [level] [options]

  Levels:
    static    Run static tests (metadata, syntax, categories, JSON)
    unit      Run unit tests (library functions, CLI commands)
    deploy    Run deploy tests (full deploy/remove cycle) - MODIFIES CLUSTER
    all       Run all test levels

  Options:
    --verbose Show detailed output
    --help    Show this help

  Examples:
    $0 static              # Quick validation
    $0 unit                # Test functions
    $0 static unit         # Run static and unit tests
    $0 all                 # Full test suite (requires cluster)
  EOF
  }

  run_test_level() {
      local level="$1"
      local test_dir="$SCRIPT_DIR/$level"

      echo ""
      echo -e "${BOLD}Running $level tests...${NC}"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

      for test_script in "$test_dir"/test-*.sh; do
          [[ -f "$test_script" ]] || continue

          echo ""
          echo "→ $(basename "$test_script")"

          if "$test_script"; then
              ((TOTAL_PASSED++))
          else
              ((TOTAL_FAILED++))
          fi
      done
  }

  # Parse arguments
  LEVELS=()
  VERBOSE=false

  for arg in "$@"; do
      case "$arg" in
          static|unit|deploy)
              LEVELS+=("$arg")
              ;;
          all)
              LEVELS=(static unit deploy)
              ;;
          --verbose)
              VERBOSE=true
              ;;
          --help|-h)
              show_help
              exit 0
              ;;
          *)
              echo "Unknown argument: $arg"
              show_help
              exit 1
              ;;
      esac
  done

  # Default to static if no level specified
  [[ ${#LEVELS[@]} -eq 0 ]] && LEVELS=(static)

  # Header
  echo ""
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}       UIS Test Suite${NC}"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo "Levels: ${LEVELS[*]}"

  # Warning for deploy tests
  if [[ " ${LEVELS[*]} " =~ " deploy " ]]; then
      echo ""
      echo -e "${YELLOW}⚠️  WARNING: Deploy tests will modify your Kubernetes cluster!${NC}"
      echo "Press Ctrl+C to cancel or wait 5 seconds to continue..."
      sleep 5
  fi

  # Run tests
  for level in "${LEVELS[@]}"; do
      run_test_level "$level"
  done

  # Final summary
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo -e "${BOLD}Final Summary${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Test scripts passed: $TOTAL_PASSED"
  echo "Test scripts failed: $TOTAL_FAILED"

  if [[ "$TOTAL_FAILED" -eq 0 ]]; then
      echo -e "${GREEN}✅ ALL TEST LEVELS PASSED${NC}"
      exit 0
  else
      echo -e "${RED}❌ SOME TEST LEVELS FAILED${NC}"
      exit 1
  fi
  ```

- [x] 10.4 Add CI/CD integration ✅
  - **File**: `.github/workflows/test-uis.yml`
  - Run static and unit tests on PR
  - Deploy tests optional (requires cluster)

  ```yaml
  name: Test UIS Scripts

  on:
    pull_request:
      paths:
        - 'provision-host/uis/**'
    push:
      branches: [main]
      paths:
        - 'provision-host/uis/**'

  jobs:
    static-tests:
      name: Static Tests
      runs-on: ubuntu-latest
      steps:
        - uses: actions/checkout@v4

        - name: Run static tests
          run: |
            # These tests don't need a container
            bash provision-host/uis/tests/run-tests.sh static

    unit-tests:
      name: Unit Tests
      runs-on: ubuntu-latest
      steps:
        - uses: actions/checkout@v4

        - name: Set up Docker
          uses: docker/setup-buildx-action@v3

        - name: Pull UIS container
          run: docker pull ghcr.io/terchris/uis-provision-host:latest

        - name: Run unit tests
          run: |
            docker run --rm \
              -v "${{ github.workspace }}:/mnt/urbalurbadisk" \
              ghcr.io/terchris/uis-provision-host:latest \
              /mnt/urbalurbadisk/provision-host/uis/tests/run-tests.sh unit

    deploy-tests:
      name: Deploy Tests
      runs-on: ubuntu-latest
      if: github.event_name == 'workflow_dispatch'  # Only run manually
      steps:
        - uses: actions/checkout@v4

        - name: Set up kind
          uses: helm/kind-action@v1

        - name: Pull UIS container
          run: docker pull ghcr.io/terchris/uis-provision-host:latest

        - name: Run deploy tests
          run: |
            docker run --rm \
              --network host \
              -v "${{ github.workspace }}:/mnt/urbalurbadisk" \
              -v "$HOME/.kube:/home/ansible/.kube:ro" \
              ghcr.io/terchris/uis-provision-host:latest \
              /mnt/urbalurbadisk/provision-host/uis/tests/run-tests.sh deploy
  ```

### Validation

```bash
# Run all static tests (fast)
./provision-host/uis/tests/run-tests.sh static

# Run unit tests
./provision-host/uis/tests/run-tests.sh unit

# Run deploy tests (slow, needs cluster)
./provision-host/uis/tests/run-tests.sh deploy

# Run all tests
./provision-host/uis/tests/run-tests.sh all

# Output:
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Static Tests (Level 1)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Running: test-metadata.sh
#   Testing: service-nginx.sh has SCRIPT_ID... PASS
#   Testing: service-nginx.sh has SCRIPT_NAME... PASS
# ...
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Final Summary
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Test scripts passed: 4
# Test scripts failed: 0
# ✅ ALL TEST LEVELS PASSED
```

---

## Acceptance Criteria

### Phase 9: JSON Generation
- [ ] `uis-docs.sh` runs without error
- [ ] `services.json` is generated with all service metadata
- [ ] `categories.json` is generated with category definitions
- [ ] `tools.json` is generated with tool information
- [ ] All JSON files pass validation (`jq .`)
- [ ] GitHub Action regenerates JSON on script changes (optional)
- [ ] `uis docs generate` CLI command works

### Phase 10: CI/CD & Deploy Tests
- [ ] JSON validation tests pass for generated files
- [ ] Deploy tests complete full cycle (optional, needs cluster)
- [ ] GitHub Action runs tests on PR
- [ ] GitHub Action regenerates JSON on changes

> **Note**: Basic test framework, static tests, and unit tests are created and validated in [PLAN-004A](./PLAN-004A-core-cli.md).

---

## Files to Create

| File | Description |
|------|-------------|
| **JSON Generator** | |
| `provision-host/uis/manage/uis-docs.sh` | JSON documentation generator |
| **Tests (this plan)** | |
| `provision-host/uis/tests/static/test-generated-json.sh` | JSON validation (for Phase 9 output) |
| `provision-host/uis/tests/deploy/test-deploy-cycle.sh` | Deploy/remove cycle tests |
| **CI/CD** | |
| `.github/workflows/generate-uis-docs.yml` | JSON regeneration workflow |
| `.github/workflows/test-uis.yml` | Test workflow |
| **Website Data** (generated) | |
| `website/src/data/services.json` | Service catalog metadata |
| `website/src/data/categories.json` | Category definitions |
| `website/src/data/tools.json` | Optional tools metadata |

> **Note**: Most test files (test-framework.sh, test-metadata.sh, test-categories.sh, test-syntax.sh, test-libraries.sh, test-cli-commands.sh, run-tests.sh) are created in [PLAN-004A](./PLAN-004A-core-cli.md) alongside the code they test.

## Files to Modify

| File | Change |
|------|--------|
| `provision-host/uis/lib/categories.sh` | Add JSON export function |
| `provision-host/uis/manage/uis-cli.sh` | Add `docs generate` command |

---

## Gaps Identified

1. **JSON Schema Validation** - Should we define JSON Schema for `services.json`, `categories.json`, `tools.json` to ensure consistent structure?

2. **Website Components** - The Docusaurus components to consume this JSON are out of scope (separate task). Need to coordinate data format with website developers.

3. **Test Coverage Metrics** - Should we track code coverage for library functions?

4. **Test Data Fixtures** - Deploy tests use real services. Should we create mock/fixture data for faster testing?

5. **Parallel Test Execution** - Static tests could run in parallel for faster CI. Current implementation is sequential.

6. **Test Isolation** - Deploy tests could interfere with each other. Need to ensure clean state between tests.

7. **Version Compatibility** - JSON format changes could break website. Need versioning strategy or backwards compatibility.

8. **Logo/Asset Management** - Where do service logos come from? Need to coordinate with `website/static/img/` assets.

9. **Incremental Updates** - Currently regenerates all JSON on any change. Could optimize to only update changed services.

10. **Documentation for JSON Format** - Need to document the JSON structure for website developers.

---

## Next Steps

After completing this plan:
1. Update the main [PLAN-004-uis-orchestration-system.md](./PLAN-004-uis-orchestration-system.md) to reference all sub-plans
2. Create website components to consume the generated JSON (separate plan)
3. Consider PLAN-004E for advanced features (versioning, auto-update, etc.)
