# Plan: Generate JSON Data from Script Metadata

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed

**Goal**: Create a script that generates `services.json` and optionally `stacks.json` by scanning metadata embedded in shell scripts.

**Last Updated**: 2026-02-18

**Priority**: Medium (enhances maintainability, not blocking)

**Depends On**: PLAN-001-branding-setup ✅ (completed)

**Related Investigation**: [INVESTIGATE-docs-restructure](INVESTIGATE-docs-restructure.md) - Docs audit and prioritization

**Implementation Notes**: The system was implemented with minor deviations from this plan:
- Scripts located in `provision-host/uis/` instead of `provision-host/kubernetes/`
- JSON format uses simpler field names (`id`, `category`, `website`) instead of JSON-LD (`identifier`, `applicationCategory`, `url`)
- `data.ts` maps between JSON field names and TypeScript types
- CI/CD pipeline handles JSON generation via `uis-docs.sh`
- npm `generate:services` script deferred (CI handles generation)

---

## Overview

Adopt the same self-documenting pattern used in DevContainer Toolbox (DCT). Each setup script in `provision-host/kubernetes/` will contain metadata fields that describe the service. A scanner script will read these scripts and generate the JSON data files for the documentation website.

### Benefits

- **Single source of truth** - Metadata lives with the script
- **Self-documenting** - Each script describes itself
- **Easy to maintain** - Update script metadata, regenerate JSON
- **Consistent with DCT** - Same pattern across SovereignSky projects

---

## DCT Reference Architecture

This section documents how DCT implements the self-documenting pattern, based on analysis of the actual codebase in `.devcontainer/`.

### DCT Directory Structure

```
.devcontainer/
├── additions/
│   ├── install-*.sh           # Installation scripts with metadata
│   ├── config-*.sh            # Configuration scripts
│   ├── service-*.sh           # Service scripts
│   ├── cmd-*.sh               # Command scripts
│   ├── lib/
│   │   ├── categories.sh      # Category definitions (table format)
│   │   ├── component-scanner.sh # Metadata extraction functions
│   │   ├── install-common.sh  # Common installation patterns
│   │   └── ...
│   └── addition-templates/
│       └── _template-install-script.sh
├── manage/
│   ├── dev-docs.sh            # JSON generator (51KB, comprehensive)
│   ├── dev-setup.sh           # Interactive menu
│   └── ...
└── devcontainer.json
```

### DCT Metadata Fields (from actual scripts)

**Core Metadata** (required for dev-setup menu):
```bash
SCRIPT_ID="dev-python"           # Unique identifier
SCRIPT_VER="0.0.1"               # Script version
SCRIPT_NAME="Python Development Tools"
SCRIPT_DESCRIPTION="Adds ipython, pytest-cov, and VS Code extensions for Python development"
SCRIPT_CATEGORY="LANGUAGE_DEV"   # Must match categories.sh
SCRIPT_CHECK_COMMAND="command -v ipython >/dev/null 2>&1"
```

**Extended Metadata** (for documentation website):
```bash
SCRIPT_TAGS="python pip ipython pytest coverage development venv"
SCRIPT_ABSTRACT="Python development environment with ipython, pytest-cov, and python-dotenv for enhanced coding and testing."
SCRIPT_LOGO="dev-python-logo.webp"
SCRIPT_WEBSITE="https://python.org"
SCRIPT_SUMMARY="Complete Python development setup including ipython for interactive development, pytest-cov for test coverage, and python-dotenv for environment management. Includes VS Code extensions for Python, Pylance, Black formatter, Flake8, and Mypy type checking."
SCRIPT_RELATED="dev-typescript dev-golang dev-rust"
```

### DCT Categories Definition (`lib/categories.sh`)

Uses a pipe-separated table format:
```bash
readonly CATEGORY_TABLE="
0|SYSTEM_COMMANDS|System Commands|DevContainer management commands...|Detailed description...|system devcontainer setup|system-commands-logo.webp
1|LANGUAGE_DEV|Development Tools|Programming language development...|Detailed description...|programming languages code|language-dev-logo.webp
2|AI_TOOLS|AI & Machine Learning Tools|AI and machine learning...|Detailed description...|ai artificial intelligence|ai-tools-logo.webp
"
```

Fields: `ORDER|ID|NAME|ABSTRACT|SUMMARY|TAGS|LOGO`

Helper functions:
- `get_category_name()` - Returns human-readable name
- `get_category_abstract()` - Returns brief description
- `get_category_summary()` - Returns detailed description
- `get_category_tags()` - Returns space-separated keywords
- `get_category_logo()` - Returns logo filename
- `is_valid_category()` - Validates category ID

### DCT Component Scanner (`lib/component-scanner.sh`)

Key extraction function:
```bash
extract_script_metadata() {
    local script_path="$1"
    local field_name="$2"
    # Extract value between quotes (first match only)
    local value=$(grep -m 1 "^${field_name}=" "$script_path" 2>/dev/null | cut -d'"' -f2)
    echo "$value"
}
```

Scanner function returns tab-separated data:
```bash
scan_install_scripts() {
    local additions_dir="$1"
    for script in "$additions_dir"/install-*.sh; do
        local script_id=$(extract_script_metadata "$script" "SCRIPT_ID")
        local script_name=$(extract_script_metadata "$script" "SCRIPT_NAME")
        # ... extract other fields
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
            "$script_basename" "$script_id" "$script_name" ...
    done
}
```

### DCT JSON Generation (`manage/dev-docs.sh`)

The `dev-docs` command generates multiple outputs:
- `website/src/data/tools.json` - Tool metadata for React components
- `website/src/data/categories.json` - Category definitions
- `website/docs/tools/index.mdx` - Overview page
- `website/docs/tools/<category>/*.mdx` - Individual tool pages
- `README.md` - Updated tools summary (between markers)

**JSON helper functions:**
```bash
json_escape() {
    local str=$1
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    str="${str//$'\n'/\\n}"
    echo "$str"
}

to_json_array() {
    local input=$1
    local result="["
    local first=1
    for item in $input; do
        [[ $first -eq 1 ]] && first=0 || result+=","
        result+="\"$(json_escape "$item")\""
    done
    result+="]"
    echo "$result"
}
```

**DCT tools.json output format:**
```json
{
  "tools": [
    {
      "id": "dev-python",
      "type": "install",
      "name": "Python Development Tools",
      "description": "Brief description",
      "category": "LANGUAGE_DEV",
      "tags": ["python", "pip", "ipython"],
      "abstract": "Brief summary for cards",
      "logo": "dev-python-logo.webp",
      "website": "https://python.org",
      "summary": "Detailed description",
      "related": ["dev-typescript", "dev-golang"]
    }
  ]
}
```

---

## Phase 1: Define UIS Script Metadata Format

### Metadata Fields for UIS

Adapt DCT pattern for Kubernetes services:

```bash
#!/bin/bash
# file: provision-host/kubernetes/11-monitoring/01-setup-prometheus.sh
#
# Brief description of what this script installs.
#
#------------------------------------------------------------------------------
# METADATA - Used by JSON generator for documentation
#------------------------------------------------------------------------------

# --- Core Metadata ---
SCRIPT_ID="prometheus"
SCRIPT_NAME="Prometheus"
SCRIPT_DESCRIPTION="Time-series metrics collection and alerting"
SCRIPT_CATEGORY="MONITORING"

# --- Extended Metadata (for website documentation) ---
SCRIPT_TAGS="monitoring metrics alerting timeseries promql"
SCRIPT_ABSTRACT="Pull-based metrics collection with powerful query language."
SCRIPT_LOGO="prometheus-logo.svg"
SCRIPT_WEBSITE="https://prometheus.io"
SCRIPT_SUMMARY="Prometheus scrapes metrics from services and stores time-series data. Configured with service discovery and alerting rules for the UIS stack."
SCRIPT_MANIFEST="031-prometheus.yaml"
SCRIPT_PLAYBOOK="030-setup-prometheus.yml"
SCRIPT_DOCS="/docs/services/monitoring/prometheus"
SCRIPT_RELATED="grafana alertmanager loki"
SCRIPT_REQUIRES=""

# --- Stack Metadata (optional, for services that are part of a stack) ---
SCRIPT_STACK="observability"
SCRIPT_STACK_POSITION="1"
SCRIPT_STACK_NOTE="Metrics collection and storage"
SCRIPT_STACK_OPTIONAL="false"

#------------------------------------------------------------------------------
# SCRIPT LOGIC BELOW
#------------------------------------------------------------------------------
```

### Field Mapping to JSON-LD

| Script Field | JSON-LD Field | Notes |
|--------------|---------------|-------|
| SCRIPT_ID | identifier | Lowercase, hyphenated |
| SCRIPT_NAME | name | Display name |
| SCRIPT_DESCRIPTION | description | Brief (1-2 sentences) |
| SCRIPT_CATEGORY | applicationCategory | Must match categories.json |
| SCRIPT_TAGS | tags | Space-separated → array |
| SCRIPT_ABSTRACT | abstract | One-line summary (50-150 chars) |
| SCRIPT_LOGO | logo | Filename in services/ |
| SCRIPT_WEBSITE | url | Official project URL |
| SCRIPT_SUMMARY | summary | Detailed description (150-500 chars) |
| SCRIPT_MANIFEST | manifest | Kubernetes manifest file |
| SCRIPT_PLAYBOOK | playbook | Ansible playbook file |
| SCRIPT_DOCS | docs | Path within site |
| SCRIPT_RELATED | related | Space-separated → array |
| SCRIPT_REQUIRES | requires | Space-separated → array |

### UIS Categories (already defined in `categories.json`)

Current UIS categories that scripts must reference:
- `AI` - AI & Machine Learning
- `AUTHENTICATION` - Authentication & SSO
- `DATABASES` - Databases
- `MONITORING` - Observability & Monitoring
- `QUEUES` - Message Queues & Caching
- `SEARCH` - Search & Indexing
- `DATASCIENCE` - Data Science & Analytics
- `CORE` - Core Infrastructure
- `MANAGEMENT` - Management Tools
- `DEVELOPMENT` - Development Tools

### Tasks

- [ ] 1.1 Create template script: `provision-host/kubernetes/setup-template.sh`
- [ ] 1.2 Document metadata format in template comments
- [ ] 1.3 Create categories mapping file (SCRIPT_CATEGORY → JSON applicationCategory)

---

## Phase 2: Create Shared Bash Library and Scanner

### Decision: Pure Bash (like DCT)

**Rationale**: Use the same approach as DCT for consistency and reusability.

The scanning library will be shared by:
1. **`uis-docs.sh`** - JSON generator for documentation website
2. **`uis-setup.sh`** - Interactive menu for managing Kubernetes services (future plan)

This ensures a single source of truth for metadata extraction logic.

### Two Execution Contexts

The scripts run in different contexts but share the same library:

| Script | Runs In | Purpose |
|--------|---------|---------|
| `uis-docs.sh` | DevContainer / CI-CD | Generate JSON for website |
| `uis-setup.sh` | Provision-host container | Interactive service menu |

**Context 1: DevContainer / CI-CD**
- For website development and JSON generation
- Has access to full repo including `website/`
- Runs `uis-docs.sh` directly

**Context 2: Provision-Host (UIS Runtime)**
- For deploying services to Kubernetes
- Only has `provision-host/` content (copied into container)
- User runs wrapper script that calls `uis-setup.sh` inside container

### Location

```
provision-host/kubernetes/
├── lib/                                    # Shared libraries
│   ├── component-scanner.sh                # Scanning functions
│   ├── categories.sh                       # Category definitions
│   └── json-utils.sh                       # JSON utilities
├── manage/                                 # Management commands
│   ├── uis-docs.sh                         # JSON generator (runs in devcontainer/CI-CD)
│   └── uis-setup.sh                        # Interactive menu (runs in provision-host)
├── 01-core/
│   └── setup-*.sh                          # Setup scripts with metadata
├── 02-databases/
│   └── setup-*.sh
├── ...
└── setup-template.sh                       # Template with all metadata fields

scripts/manage/                             # User-facing wrappers (host machine)
├── k9s.sh                                  # Existing
└── uis-setup.sh                            # NEW: Wrapper for docker exec

website/src/data/                           # Output (generated by uis-docs.sh)
├── services.json                           # Generated from script metadata
├── categories.json                         # Static or generated
└── stacks.json                             # Static or generated
```

### Execution Flows

**Documentation Generation (DevContainer/CI-CD):**
```bash
# From devcontainer or CI-CD pipeline
./provision-host/kubernetes/manage/uis-docs.sh
# Scans: provision-host/kubernetes/*/setup-*.sh
# Writes: website/src/data/services.json
```

**Service Management (UIS Runtime):**
```bash
# User runs from host machine
./scripts/manage/uis-setup.sh
# Which executes:
# docker exec -it provision-host \
#   /mnt/urbalurbadisk/provision-host/kubernetes/manage/uis-setup.sh
```

### Shared Library: `lib/component-scanner.sh`

```bash
#!/bin/bash
# file: provision-host/kubernetes/lib/component-scanner.sh
#
# Shared library for discovering and querying UIS service scripts.
# Used by both uis-docs.sh (JSON generation) and uis-setup.sh (interactive menu).

COMPONENT_SCANNER_VERSION="1.0.0"

#------------------------------------------------------------------------------
# METADATA EXTRACTION
#------------------------------------------------------------------------------

# Extract a single metadata field from a script file
# Args: $1=script_path, $2=field_name
# Returns: field value via stdout (empty if not found)
extract_script_metadata() {
    local script_path="$1"
    local field_name="$2"

    if [[ -z "$script_path" || -z "$field_name" ]]; then
        return 1
    fi

    if [[ ! -f "$script_path" ]]; then
        return 1
    fi

    # Extract value between quotes (first match only)
    grep -m 1 "^${field_name}=" "$script_path" 2>/dev/null | cut -d'"' -f2
}

# Extract all SCRIPT_* metadata from a script
# Args: $1=script_path
# Sets global variables: _SCRIPT_ID, _SCRIPT_NAME, etc.
extract_all_metadata() {
    local script_path="$1"

    _SCRIPT_ID=$(extract_script_metadata "$script_path" "SCRIPT_ID")
    _SCRIPT_NAME=$(extract_script_metadata "$script_path" "SCRIPT_NAME")
    _SCRIPT_DESCRIPTION=$(extract_script_metadata "$script_path" "SCRIPT_DESCRIPTION")
    _SCRIPT_CATEGORY=$(extract_script_metadata "$script_path" "SCRIPT_CATEGORY")
    _SCRIPT_TAGS=$(extract_script_metadata "$script_path" "SCRIPT_TAGS")
    _SCRIPT_ABSTRACT=$(extract_script_metadata "$script_path" "SCRIPT_ABSTRACT")
    _SCRIPT_LOGO=$(extract_script_metadata "$script_path" "SCRIPT_LOGO")
    _SCRIPT_WEBSITE=$(extract_script_metadata "$script_path" "SCRIPT_WEBSITE")
    _SCRIPT_SUMMARY=$(extract_script_metadata "$script_path" "SCRIPT_SUMMARY")
    _SCRIPT_MANIFEST=$(extract_script_metadata "$script_path" "SCRIPT_MANIFEST")
    _SCRIPT_PLAYBOOK=$(extract_script_metadata "$script_path" "SCRIPT_PLAYBOOK")
    _SCRIPT_DOCS=$(extract_script_metadata "$script_path" "SCRIPT_DOCS")
    _SCRIPT_RELATED=$(extract_script_metadata "$script_path" "SCRIPT_RELATED")
    _SCRIPT_REQUIRES=$(extract_script_metadata "$script_path" "SCRIPT_REQUIRES")
    _SCRIPT_STACK=$(extract_script_metadata "$script_path" "SCRIPT_STACK")
    _SCRIPT_STACK_POSITION=$(extract_script_metadata "$script_path" "SCRIPT_STACK_POSITION")
    _SCRIPT_STACK_NOTE=$(extract_script_metadata "$script_path" "SCRIPT_STACK_NOTE")
    _SCRIPT_STACK_OPTIONAL=$(extract_script_metadata "$script_path" "SCRIPT_STACK_OPTIONAL")
}

#------------------------------------------------------------------------------
# SCRIPT SCANNING
#------------------------------------------------------------------------------

# Scan all setup-*.sh scripts and output structured data
# Args: $1=kubernetes_dir (e.g., provision-host/kubernetes)
# Output: tab-separated, one line per service
scan_setup_scripts() {
    local kubernetes_dir="$1"

    if [[ ! -d "$kubernetes_dir" ]]; then
        echo "Error: Directory not found: $kubernetes_dir" >&2
        return 1
    fi

    # Find all setup-*.sh scripts (excluding not-in-use folders)
    find "$kubernetes_dir" -path "*/not-in-use/*" -prune -o \
        -name "setup-*.sh" -type f -print 2>/dev/null | sort | while read -r script; do

        extract_all_metadata "$script"

        # Skip if missing required fields
        if [[ -z "$_SCRIPT_ID" || -z "$_SCRIPT_NAME" ]]; then
            continue
        fi

        # Output tab-separated values
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
            "$script" \
            "$_SCRIPT_ID" \
            "$_SCRIPT_NAME" \
            "$_SCRIPT_DESCRIPTION" \
            "$_SCRIPT_CATEGORY" \
            "$_SCRIPT_TAGS" \
            "$_SCRIPT_ABSTRACT" \
            "$_SCRIPT_LOGO" \
            "$_SCRIPT_WEBSITE" \
            "$_SCRIPT_SUMMARY" \
            "$_SCRIPT_MANIFEST" \
            "$_SCRIPT_PLAYBOOK" \
            "$_SCRIPT_DOCS" \
            "$_SCRIPT_RELATED" \
            "$_SCRIPT_REQUIRES" \
            "$_SCRIPT_STACK" \
            "$_SCRIPT_STACK_POSITION" \
            "$_SCRIPT_STACK_NOTE"
    done
}

COMPONENT_SCANNER_LOADED=1
```

### JSON Utilities: `lib/json-utils.sh`

```bash
#!/bin/bash
# file: provision-host/kubernetes/lib/json-utils.sh
#
# JSON escaping and formatting utilities for bash scripts.

# Escape string for JSON output
json_escape() {
    local str="$1"
    # Escape backslashes, double quotes, and control characters
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    str="${str//$'\n'/\\n}"
    str="${str//$'\r'/\\r}"
    str="${str//$'\t'/\\t}"
    echo "$str"
}

# Convert space-separated string to JSON array
# Args: $1=space-separated string
# Returns: JSON array like ["item1","item2"]
to_json_array() {
    local input="$1"
    if [[ -z "$input" ]]; then
        echo "[]"
        return
    fi

    local result="["
    local first=1
    for item in $input; do
        if [[ $first -eq 1 ]]; then
            first=0
        else
            result+=","
        fi
        result+="\"$(json_escape "$item")\""
    done
    result+="]"
    echo "$result"
}

# Output a JSON object field (with trailing comma)
# Args: $1=field_name, $2=value, $3=type (string|array|number|boolean)
json_field() {
    local name="$1"
    local value="$2"
    local type="${3:-string}"

    case "$type" in
        string)
            echo "    \"$name\": \"$(json_escape "$value")\","
            ;;
        array)
            echo "    \"$name\": $(to_json_array "$value"),"
            ;;
        number)
            echo "    \"$name\": ${value:-0},"
            ;;
        boolean)
            echo "    \"$name\": ${value:-false},"
            ;;
    esac
}

# Output a JSON object field (last field, no trailing comma)
json_field_last() {
    local name="$1"
    local value="$2"
    local type="${3:-string}"

    case "$type" in
        string)
            echo "    \"$name\": \"$(json_escape "$value")\""
            ;;
        array)
            echo "    \"$name\": $(to_json_array "$value")"
            ;;
        number)
            echo "    \"$name\": ${value:-0}"
            ;;
        boolean)
            echo "    \"$name\": ${value:-false}"
            ;;
    esac
}
```

### JSON Generator: `manage/uis-docs.sh`

```bash
#!/bin/bash
# file: provision-host/kubernetes/manage/uis-docs.sh
#
# Generates services.json for the UIS documentation website.
# Uses shared library from lib/component-scanner.sh
#
# Usage:
#   ./uis-docs.sh                    # Generate JSON files
#   ./uis-docs.sh --dry-run          # Preview without writing
#   ./uis-docs.sh --help             # Show help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# Source shared libraries (in parent lib/ folder)
source "${SCRIPT_DIR}/../lib/component-scanner.sh"
source "${SCRIPT_DIR}/../lib/categories.sh"
source "${SCRIPT_DIR}/../lib/json-utils.sh"

# Output paths (relative to repo root)
readonly KUBERNETES_DIR="${SCRIPT_DIR}/.."
readonly WEBSITE_DIR="${SCRIPT_DI../../../website"
readonly SERVICES_JSON="${WEBSITE_DIR}/src/data/services.json"

# Options
DRY_RUN=0
VERBOSE=0

#------------------------------------------------------------------------------
# Generate services.json
#------------------------------------------------------------------------------
generate_services_json() {
    local json=""

    # JSON-LD header
    json+="{\n"
    json+="  \"@context\": \"https://schema.org\",\n"
    json+="  \"@type\": \"ItemList\",\n"
    json+="  \"name\": \"UIS Services\",\n"
    json+="  \"itemListElement\": ["

    local first_service=1

    # Scan all setup scripts
    while IFS=$'\t' read -r script_path id name desc category tags abstract logo website summary manifest playbook docs related requires stack stack_pos stack_note; do
        # Add comma before service (except first)
        if [[ $first_service -eq 1 ]]; then
            first_service=0
        else
            json+=","
        fi

        # Build service JSON object
        json+="\n    {\n"
        json+="      \"@type\": \"SoftwareApplication\",\n"
        json+="      \"identifier\": \"$(json_escape "$id")\",\n"
        json+="      \"name\": \"$(json_escape "$name")\",\n"
        json+="      \"description\": \"$(json_escape "$desc")\",\n"
        json+="      \"applicationCategory\": \"$category\",\n"
        json+="      \"tags\": $(to_json_array "$tags"),\n"
        json+="      \"abstract\": \"$(json_escape "$abstract")\",\n"
        json+="      \"logo\": \"$(json_escape "${logo:-${id}-logo.svg}")\",\n"
        json+="      \"url\": \"$(json_escape "$website")\",\n"
        json+="      \"summary\": \"$(json_escape "$summary")\",\n"
        json+="      \"manifest\": \"$(json_escape "$manifest")\",\n"
        json+="      \"playbook\": \"$(json_escape "$playbook")\",\n"
        json+="      \"docs\": \"$(json_escape "$docs")\",\n"
        json+="      \"related\": $(to_json_array "$related"),\n"
        json+="      \"requires\": $(to_json_array "$requires")"
        json+="\n    }"

    done < <(scan_setup_scripts "$KUBERNETES_DIR")

    json+="\n  ]\n"
    json+="}\n"

    echo -e "$json"
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run) DRY_RUN=1; shift ;;
        --verbose) VERBOSE=1; shift ;;
        --help)
            echo "Usage: $0 [--dry-run] [--verbose] [--help]"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

echo "Generating services.json..."

services_json=$(generate_services_json)

if [[ $DRY_RUN -eq 1 ]]; then
    echo "DRY RUN - Preview:"
    echo -e "$services_json" | head -50
    echo "..."
else
    mkdir -p "$(dirname "$SERVICES_JSON")"
    echo -e "$services_json" > "$SERVICES_JSON"
    echo "Written: $SERVICES_JSON"
fi

echo "Done!"
```

### Tasks

- [ ] 2.1 Create `provision-host/kubernetes/lib/` folder
- [ ] 2.2 Create `provision-host/kubernetes/manage/` folder
- [ ] 2.3 Implement `lib/component-scanner.sh` - shared scanning library
- [ ] 2.4 Implement `lib/categories.sh` - category definitions (adapt from DCT)
- [ ] 2.5 Implement `lib/json-utils.sh` - JSON formatting utilities
- [ ] 2.6 Implement `manage/uis-docs.sh` - JSON generator
- [ ] 2.7 Create `scripts/manage/uis-setup.sh` - user-facing wrapper (for future uis-setup.sh)
- [ ] 2.8 Add npm script to call uis-docs.sh: `npm run generate:services`
- [ ] 2.9 Test that generated JSON matches current services.json schema

---

## Phase 3: Add Metadata to Existing Scripts

### Scripts to Update

Scan `provision-host/kubernetes/*/` for all setup scripts:

| Folder | Scripts | Category |
|--------|---------|----------|
| 01-core | Various core scripts | CORE |
| 02-databases | PostgreSQL, MySQL, MongoDB, Qdrant | DATABASES |
| 07-ai | OpenWebUI, Ollama, LiteLLM, Tika | AI |
| 11-monitoring | Prometheus, Grafana, Loki, Tempo | MONITORING |
| 12-auth | Authentik | AUTHENTICATION |

### Current Script Inventory

Run this to find all scripts:
```bash
find provision-host/kubernetes -name "*.sh" -type f | grep -v not-in-use | sort
```

### Tasks

- [ ] 3.1 Inventory all scripts in provision-host/kubernetes/
- [ ] 3.2 Add metadata to active scripts (prioritize by category)
- [ ] 3.3 Add metadata to not-in-use scripts (for documentation completeness)
- [ ] 3.4 Validate SCRIPT_CATEGORY values match categories.json
- [ ] 3.5 Validate SCRIPT_RELATED references are valid service IDs

---

## Phase 4: Stack Generation

### Decision: Auto-generate vs Manual

**Current state**: `stacks.json` is manually maintained with 3 stacks:
- observability (Prometheus, Grafana, Loki, Tempo, Alertmanager)
- ai-platform (Ollama, LiteLLM, OpenWebUI, Tika)
- data-platform (Spark, JupyterHub, Unity Catalog)

**Recommendation**: Keep stacks.json manual, but validate against SCRIPT_STACK_* fields.

### Stack Validation Logic

```javascript
// Validate stacks.json against script metadata
for (const stack of stacks) {
  for (const component of stack.components) {
    const service = services.find(s => s.identifier === component.service);
    if (!service) {
      console.error(`Stack ${stack.identifier}: unknown service ${component.service}`);
    }
    if (service && service.stackId !== stack.identifier) {
      console.warn(`Service ${component.service} has SCRIPT_STACK=${service.stackId} but is in stack ${stack.identifier}`);
    }
  }
}
```

### Tasks

- [ ] 4.1 Keep stacks.json manual (current approach)
- [ ] 4.2 Add validation to check stacks.json against SCRIPT_STACK_* fields
- [ ] 4.3 Add stack metadata fields to script template

---

## Phase 5: Integration

### npm Scripts

```json
{
  "scripts": {
    "generate:services": "bash ../provision-host/kubernetes/manage/uis-docs.sh",
    "prebuild": "npm run generate:services"
  }
}
```

### CI/CD Integration

Add to `.github/workflows/docs.yml`:
```yaml
- name: Generate services JSON
  run: bash provision-host/kubernetes/manage/uis-docs.sh

- name: Build website
  working-directory: website
  run: npm run build
```

### Local Development Workflow

```bash
# From repository root
./provision-host/kubernetes/manage/uis-docs.sh    # Generate services.json

# Or from website directory
cd website
npm run generate:services  # Calls uis-docs.sh
npm run build              # Build includes generation via prebuild
```

### Tasks

- [ ] 5.1 Add npm scripts to website/package.json
- [ ] 5.2 Update GitHub Actions workflow
- [ ] 5.3 Document workflow in provision-host/kubernetes/README.md

---

## Validation Checklist

- [ ] Scanner runs without errors
- [ ] Generated services.json matches current JSON-LD schema
- [ ] All services from scripts appear in generated JSON
- [ ] Website builds successfully with generated data
- [ ] ServiceCard, ServiceGrid components render correctly
- [ ] Changes to script metadata reflect in generated JSON after rebuild
- [ ] CI/CD pipeline includes generation step

---

## Files to Create

| File | Purpose |
|------|---------|
| `provision-host/kubernetes/lib/component-scanner.sh` | Shared scanning library |
| `provision-host/kubernetes/lib/categories.sh` | Category definitions and helpers |
| `provision-host/kubernetes/lib/json-utils.sh` | JSON escaping and formatting |
| `provision-host/kubernetes/manage/uis-docs.sh` | JSON generator (runs in devcontainer/CI-CD) |
| `provision-host/kubernetes/setup-template.sh` | Template with all metadata fields |
| `scripts/manage/uis-setup.sh` | User-facing wrapper (calls into provision-host) |

## Files to Modify

| File | Changes |
|------|---------|
| All `provision-host/kubernetes/*/setup-*.sh` | Add metadata variables |
| `website/package.json` | Add npm script to call uis-docs.sh |
| `.github/workflows/docs.yml` | Add generation step |

## Future Plans (using shared library)

| File | Purpose |
|------|---------|
| `provision-host/kubernetes/manage/uis-setup.sh` | Interactive menu for managing services (like DCT dev-setup.sh) |

---

## Reference: DCT Source Files

For implementation reference, these DCT files were analyzed:

| File | Purpose |
|------|---------|
| `.devcontainer/additions/lib/categories.sh` | Category table definition and helpers |
| `.devcontainer/additions/lib/component-scanner.sh` | Metadata extraction functions |
| `.devcontainer/manage/dev-docs.sh` | Full JSON generation implementation |
| `.devcontainer/additions/install-dev-python.sh` | Example script with all metadata |
| `.devcontainer/additions/addition-templates/_template-install-script.sh` | Template with metadata docs |
