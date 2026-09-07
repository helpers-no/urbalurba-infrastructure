# Investigation: UIS Distribution Architecture

> **Purpose**: Design a new distribution model for UIS that allows users to install and update without forking the repo or editing core files.

**Status:** Completed

**Goal**: Design a container-based distribution model for UIS.

**Created**: 2026-01-22
**Completed**: 2026-02-18

**Priority**: High (foundational for product scalability)

**Decision**: **Container-as-Deliverable** - The UIS product is delivered as a container image, not a zip file. Users only need to provide their `topsecret/` folder (secrets + config).

**Completed**: PLAN-003 implemented minimal container delivery:
- Container image published to `ghcr.io/terchris/uis-provision-host:latest`
- Size reduced from 2.7GB to 1.86GB
- `./uis` wrapper script with auto-pull from registry
- CI/CD pipeline for multi-arch builds (amd64/arm64)
- Branded welcome page for nginx catch-all

**Next Action**: Implement full orchestration system (Phase 1-6 below).

**Related Plans**:
- [PLAN-003-minimal-container-delivery.md](PLAN-003-minimal-container-delivery.md) - ✅ Complete
- [PLAN-004-uis-orchestration-system.md](PLAN-004-uis-orchestration-system.md) - ✅ Complete
- [PLAN-002-json-generator.md](./PLAN-002-json-generator.md) - Complete

---

## Problem Statement

### Current Model (Fork & Edit)
- Users fork the entire repository
- Users edit files directly (move from `not-in-use/`, modify configs)
- Updates require git pull and merge conflicts
- Works for creator/power users, not scalable for product

### Desired Model (Install & Configure)
- CI/CD creates distributable package
- Users install via simple command
- Users customize via config files (never edit core files)
- Updates via `uis-update` command
- Parallel to existing system during development

---

## Investigation Questions

### 1. Distribution Package
- [x] What files should be included in the distribution? → **Container image with baked-in files**
- [x] What files should be excluded (website, docs, dev tools)? → **website/, docs/, .devcontainer/, .git/**
- [x] What is the package format (zip, tar.gz)? → **Container image (not zip)**
- [x] Where is the package hosted (GitHub releases)? → **Container registry: ghcr.io/sovereignsky/uis-provision-host**

### 2. User Customization
- [x] Where does the user customization folder live? → **`topsecret/config/` for config, `topsecret/secrets-config/` for secrets**
- [x] What is the structure of `enabled-services.conf`? → **One SCRIPT_ID per line (like DCT)**
- [x] How do users override service configurations (Helm values, manifests)? → **`topsecret/config/service-overrides/`**
- [x] How do users add their own custom services? → **`topsecret/config/custom-manifests/`**

### 3. Service Enable/Disable
- [x] How does config-driven enable/disable work? → **Read enabled-services.conf, match against SCRIPT_ID**
- [x] What happens to `not-in-use/` folders? → **Keep for old system; new system ignores file location**
- [x] Should all services be in the package (enabled via config)? → **Yes, all in container, enabled via config**
- [x] Or should there be "core" vs "optional" services? → **No distinction - all config-driven**

### 4. Update Mechanism
- [x] How does `uis-update` work? → **`docker pull` new image; user config in mounts preserved**
- [x] How are user customizations preserved during update? → **Mounts stay on host, image gets replaced**
- [x] How is version tracked? → **Container image tags + `.version` file inside container**
- [ ] What about breaking changes between versions? → TBD during implementation

### 5. Provision-Host Integration
- [x] How does the new system integrate with provision-host container? → **UIS IS the container**
- [x] What paths are mounted into the container? → **`topsecret/` → `/mnt/urbalurbadisk/topsecret/`**
- [x] How does `uis-setup.sh` (wrapper on host) call into provision-host? → **`docker exec` to `uis-cli.sh`**

### 6. Migration Path
- [ ] How do existing users migrate to new system? → TBD (Phase 6)
- [x] Can both systems coexist during transition? → **Yes, container includes both orchestration systems**
- [ ] What documentation is needed? → TBD (Phase 6)

---

## Reference: DCT Architecture

### Distribution
```
CI/CD creates: dev_containers.zip
├── .devcontainer/           # Product (never edited by user)
│   ├── additions/
│   ├── manage/
│   ├── devcontainer.json
│   └── .version
```

### User Customization
```
.devcontainer.extend/        # User customization (persisted)
├── enabled-tools.conf       # Which tools to install
├── enabled-services.conf    # Which services to start
└── project-installs.sh      # Custom project setup
```

### Update Flow
```bash
dev-update
# 1. Downloads latest zip from GitHub releases
# 2. Extracts to temp folder
# 3. Replaces .devcontainer/ (preserves .devcontainer.extend/)
# 4. Records version in .devcontainer/.version
# 5. Prompts rebuild if devcontainer.json changed
```

### Key DCT Files to Study
- `.devcontainer/manage/dev-update.sh` - Update mechanism
- `.devcontainer/manage/dev-setup.sh` - Interactive menu
- `.devcontainer.extend/enabled-tools.conf` - Config-driven installation
- `.devcontainer/additions/lib/component-scanner.sh` - Metadata discovery

---

## Proposed UIS Architecture: Container-as-Deliverable

> **Key Decision**: The UIS product is delivered as a **container image**, not a zip file.
> The repository structure stays as-is. CI/CD builds a container with everything inside.
> Users only need their `topsecret/` folder locally (config + secrets).

### Container Image Contents
```
ghcr.io/sovereignsky/uis-provision-host:1.0.0
│
├── /mnt/urbalurbadisk/                 # UIS product (baked into image) - SAME PATH AS TODAY
│   ├── ansible/                        # Playbooks
│   ├── manifests/                      # K8s manifests
│   ├── hosts/                          # Cluster setup scripts
│   ├── cloud-init/                     # VM templates
│   ├── networking/                     # Network scripts
│   ├── provision-host/
│   │   ├── kubernetes/                 # Existing orchestration (unchanged)
│   │   └── uis/                        # NEW orchestration (to be built)
│   │       ├── lib/
│   │       ├── manage/
│   │       └── services/
│   ├── topsecret/                      # Mount point - user's folder overlays this
│   │   └── secrets-templates/          # Base templates (baked in)
│   ├── scripts/
│   └── .version
│
└── (tools: ansible, kubectl, helm, az, tailscale, etc.)
```

### User's Local Folder
```
my-project/
├── topsecret/                      # User's folder (mounted into container)
│   ├── secrets-templates/          # Can override templates (optional)
│   ├── secrets-config/             # User-edited secret values (required)
│   │   └── 00-common-values.env
│   ├── secrets-generated/          # Temp processing
│   ├── kubernetes/                 # Generated K8s secrets
│   └── config/                     # NEW - user config files
│       ├── enabled-services.conf   # Which services to deploy
│       ├── cluster-config.sh       # Cluster type, project name, domain
│       └── service-overrides/      # Per-service customization (optional)
│
└── (user's own project files...)
```

### What's In Container vs Local

> **Note**: Current system uses `docker cp` to copy files. New model uses **mounts** instead.

| Location | Contents | New Model |
|----------|----------|-----------|
| Container `/mnt/urbalurbadisk/` | UIS product (ansible, manifests, scripts) | Baked in |
| Local `topsecret/` → `/mnt/urbalurbadisk/topsecret/` | User config + secrets | Mounted |
| Local `~/.kube/` → `/home/ansible/.kube/` | Kubernetes config | Mounted (ro) |

### Repository Structure (Unchanged)

The repo stays as-is. CI/CD builds the container from it:

```
urbalurba-infrastructure/               # Repository (source)
├── ansible/                            # → /mnt/urbalurbadisk/ansible/
├── manifests/                          # → /mnt/urbalurbadisk/manifests/
├── hosts/                              # → /mnt/urbalurbadisk/hosts/
├── cloud-init/                         # → /mnt/urbalurbadisk/cloud-init/
├── networking/                         # → /mnt/urbalurbadisk/networking/
├── provision-host/                     # → /mnt/urbalurbadisk/provision-host/
│   ├── kubernetes/                     # Existing (keep working)
│   └── uis/                            # NEW (build alongside)
├── topsecret/                          # → /mnt/urbalurbadisk/topsecret/
├── scripts/                            # → /mnt/urbalurbadisk/scripts/
│
├── website/                            # NOT in container
├── docs/                               # NOT in container
├── .devcontainer/                      # NOT in container
└── .github/workflows/                  # Builds the container
```

### User Config Folder (topsecret/config/)
```
topsecret/config/                   # NEW - user config files
├── enabled-services.conf           # Services to deploy
├── cluster-config.sh               # Cluster type, project name, domain
├── service-overrides/              # Per-service customization
│   ├── prometheus/
│   │   └── values.yaml             # Helm value overrides
│   └── grafana/
│       └── values.yaml
└── custom-manifests/               # User's own manifests
```

### enabled-services.conf Format
```bash
# UIS Enabled Services
# Format: One SCRIPT_ID per line
# Run 'uis-setup --list' to see available services

# === Core (recommended) ===
nginx
traefik

# === Monitoring ===
prometheus
grafana
loki
# tempo                            # Commented = disabled

# === AI ===
# openwebui                        # Commented = disabled
# ollama

# === Databases ===
# postgresql
# redis
```

### Wrapper Commands
```bash
# On host machine (scripts/manage/)
./uis-setup.sh                      # Interactive menu
./uis-setup.sh --list               # List all available services
./uis-setup.sh --status             # Show which are deployed
./uis-setup.sh --deploy             # Deploy enabled services
./uis-setup.sh --deploy prometheus  # Deploy specific service
./uis-setup.sh --remove prometheus  # Remove specific service
./uis-update.sh                     # Update to latest version
```

---

## Parallel Development Strategy

> **CRITICAL CONSTRAINT**: Do NOT modify `provision-host/kubernetes/` or anything below it.
> The existing system must continue working unchanged while the new system is developed.

### Phase 1: Build New System in Separate Location
```
provision-host/kubernetes/          # EXISTING - DO NOT TOUCH
├── 01-core/
├── 11-monitoring/
│   ├── 01-setup-prometheus.sh      # Leave as-is
│   └── not-in-use/
└── provision-kubernetes.sh

provision-host/uis/                 # NEW - Build from scratch
├── lib/
│   └── service-scanner.sh
├── manage/
│   ├── uis-setup.sh
│   └── uis-update.sh
├── services/
│   ├── core/
│   ├── monitoring/
│   └── ...
└── .version
```

### Phase 2: Validate New System
- Test with fresh installs
- Test update mechanism
- Test config-driven enable/disable
- Document migration path

### Phase 3: Switchover
- When new system is validated, it becomes primary
- Provide migration guide for existing users
- Old `provision-host/kubernetes/` can be removed later

---

## Research Findings

### DCT Architecture Deep Dive (Completed)

#### 1. dev-update.sh - Self-Updating Mechanism
**Key Pattern**: Self-copy before execution for safe self-update

```bash
# dev-update.sh copies itself to temp before running
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPDATE_SCRIPT="$SCRIPT_DIR/dev-update.sh"
TEMP_SCRIPT="/tmp/dev-update-$$.sh"
cp "$UPDATE_SCRIPT" "$TEMP_SCRIPT"
exec bash "$TEMP_SCRIPT" --from-temp
```

**Update Flow**:
1. Download latest zip from GitHub releases
2. Extract to temp folder
3. Replace `.devcontainer/` (preserves `.devcontainer.extend/`)
4. Track version in `.devcontainer/.version` (format: `VERSION=1.2.3`)
5. Compare devcontainer.json - prompt rebuild if changed

#### 2. enabled-tools.conf Processing
**File**: `.devcontainer/additions/lib/tool-installation.sh`

```bash
# install_enabled_tools() function:
# 1. Read enabled-tools.conf line by line (skip # comments and empty lines)
# 2. Call scan_install_scripts() to discover all install-*.sh scripts
# 3. Match SCRIPT_ID from scripts against enabled tools list
# 4. Install matching tools using install_single_tool()
```

**enabled-tools.conf Format**:
```bash
# One tool identifier per line (matches SCRIPT_ID in scripts)
dev-imagetools
dev-python
# dev-nodejs    # Commented = disabled
```

#### 3. postCreateCommand.sh - Orchestration
**Flow**:
1. Source libraries: `component-scanner.sh`, `tool-installation.sh`, `prerequisite-check.sh`
2. Call `install_enabled_tools "$ADDITIONS_DIR"` for config-driven installation
3. Run `.devcontainer.extend/project-installs.sh` for custom user installations
4. Start supervisor services if configured

#### 4. component-scanner.sh - Metadata Discovery
**Scan Functions** (each script type has its own scanner):
- `scan_install_scripts()` - Scans `install-*.sh` files
- `scan_service_scripts()` - Scans `start-*.sh` files
- `scan_config_scripts()` - Scans `config-*.sh` files
- `scan_cmd_scripts()` - Scans `cmd-*.sh` files
- `scan_manage_scripts()` - Scans `dev-*.sh` files

**Metadata Extraction**:
```bash
extract_script_metadata() {
    local script_path="$1"
    local field_name="$2"
    # Extract using grep: grep "^${field_name}=" "$script_path" | cut -d'"' -f2
}
```

**Output Format** (tab-separated):
```
script_basename<TAB>SCRIPT_ID<TAB>SCRIPT_NAME<TAB>SCRIPT_DESCRIPTION<TAB>SCRIPT_CATEGORY<TAB>SCRIPT_CHECK_COMMAND<TAB>SCRIPT_PREREQUISITES
```

---

### Repository Root Structure Analysis (Completed)

The UIS repository has multiple interconnected folders. Understanding these is critical for designing the new distribution.

#### Root Folder Map
```
urbalurba-infrastructure/
├── .devcontainer/              # DevContainer Toolbox (for development)
├── .devcontainer.extend/       # DCT user customization
├── .github/                    # CI/CD workflows
│
├── ansible/                    # Ansible automation
│   ├── ansible.cfg
│   ├── inventory.yml
│   └── playbooks/              # 60+ playbooks (030-setup-prometheus.yml, etc.)
│
├── manifests/                  # Kubernetes manifests (60+ YAML files)
│   ├── 030-prometheus-config.yaml
│   ├── 030-grafana-config.yaml
│   └── ...
│
├── provision-host/             # Main provisioning system
│   ├── kubernetes/             # ← Setup scripts (DO NOT TOUCH)
│   │   ├── 01-core/
│   │   ├── 11-monitoring/
│   │   └── provision-kubernetes.sh
│   ├── provision-host-*.sh     # Container provisioning scripts
│   └── ...
│
├── hosts/                      # Host-specific installation scripts
│   ├── install-rancher-kubernetes.sh
│   ├── install-azure-microk8s.sh
│   ├── rancher-kubernetes/
│   └── azure-microk8s/
│
├── cloud-init/                 # Cloud-init templates for VMs
│   ├── azure-cloud-init.yml
│   ├── multipass-cloud-init.yml
│   └── raspberry-cloud-init.yml
│
├── scripts/                    # Utility scripts
│   └── manage/
│       └── k9s.sh
│
├── containers/                 # Container configurations
│   └── postgresql/
│
├── secrets/                    # SSH keys for Ansible
│   ├── id_rsa_ansible
│   └── create-secrets.sh
│
├── networking/                 # Network configurations
├── topsecret/                  # Sensitive configs (gitignored content)
├── troubleshooting/            # Debug/troubleshooting scripts
│
├── website/                    # Docusaurus documentation site
└── docs/                       # Legacy docs (being migrated)
```

#### Supported Kubernetes Cluster Types

The `hosts/` folder defines different Kubernetes environments that UIS can deploy to:

| Host Type | Folder | Description |
|-----------|--------|-------------|
| **Rancher Desktop** | `rancher-kubernetes/` | Local laptop (macOS/Windows/Linux) |
| **Azure MicroK8s** | `azure-microk8s/` | MicroK8s on Azure VM |
| **Azure AKS** | `azure-aks/` | Azure Kubernetes Service (managed) |
| **Multipass MicroK8s** | `multipass-microk8s/` | MicroK8s on local Multipass VM |
| **Raspberry Pi** | `raspberry-microk8s/` | MicroK8s on Raspberry Pi cluster |

**Workflow:**
```
1. User runs: hosts/install-azure-microk8s.sh
   ↓
2. Creates VM using cloud-init/azure-cloud-init.yml
   ↓
3. Registers in ansible/inventory.yml
   ↓
4. Merges kubeconfig
   ↓
5. Now ready for: provision-host/kubernetes/provision-kubernetes.sh
```

**Two-Phase Setup:**
- **Phase 1**: `hosts/` - Sets up the Kubernetes cluster itself
- **Phase 2**: `provision-host/kubernetes/` - Deploys services on the cluster

#### Key Dependencies Between Folders

| Folder | Used By | Purpose |
|--------|---------|---------|
| `hosts/` | Users (Phase 1) | Create/configure K8s cluster |
| `cloud-init/` | `hosts/*.sh` | VM bootstrap templates |
| `ansible/playbooks/` | `provision-host/kubernetes/*/*.sh` | Service deployment |
| `manifests/` | `ansible/playbooks/*.yml` | K8s resource definitions |
| `secrets/` | Ansible | SSH authentication |

#### How Scripts Reference Other Folders

**From setup scripts** (`provision-host/kubernetes/11-monitoring/01-setup-prometheus.sh`):
```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
ansible-playbook "$PROJECT_ROOT/ansible/playbooks/030-setup-prometheus.yml" -e "target_host=$TARGET_HOST"
```

**From Ansible playbooks** (`ansible/playbooks/030-setup-prometheus.yml`):
```yaml
vars:
  manifests_folder: "/mnt/urbalurbadisk/manifests"  # Mounted path in provision-host container
  prometheus_config_file: "{{ manifests_folder }}/030-prometheus-config.yaml"
```

#### Provision-Host Container Mount Points
When running inside provision-host container:
- `/mnt/urbalurbadisk/` = Repository root
- `/mnt/urbalurbadisk/manifests/` = Manifests folder
- `/mnt/urbalurbadisk/ansible/` = Ansible folder
- `/mnt/urbalurbadisk/provision-host/` = Provisioning scripts

---

### Current UIS Scripts Analysis (Completed)

#### Directory Structure
```
provision-host/kubernetes/
├── provision-kubernetes.sh      # Main orchestration (runs all scripts in order)
├── 01-core/
│   ├── 020-setup-nginx.sh       # Active scripts
│   └── not-in-use/              # Disabled scripts
│       └── 020-remove-nginx.sh
├── 02-databases/
│   └── not-in-use/
│       ├── 05-setup-postgres.sh
│       └── 05-remove-postgres.sh
├── 11-monitoring/
│   ├── 01-setup-prometheus.sh   # Active
│   ├── 02-setup-tempo.sh
│   ├── 03-setup-loki.sh
│   ├── 04-setup-otel-collector.sh
│   ├── 05-setup-grafana.sh
│   ├── 06-setup-testdata.sh
│   └── not-in-use/              # Disabled/remove scripts
│       ├── 01-remove-prometheus.sh
│       └── ...
└── ... (other categories)
```

#### provision-kubernetes.sh Logic
```bash
# 1. Find all directories starting with a number, sorted
directories=$(find . -maxdepth 1 -type d -name "[0-9]*" | sort -n)

# 2. For each directory, find scripts starting with number
scripts=$(find "$dir" -maxdepth 1 -type f -name "[0-9]*.sh" | sort -n)

# 3. Execute each script with TARGET_HOST parameter
bash "$script" "$TARGET_HOST"
```

**Note**: Scripts in `not-in-use/` are NOT in maxdepth 1, so they're skipped.

#### Current Script Pattern (No Metadata)
```bash
#!/bin/bash
# File: provision-host/kubernetes/11-monitoring/01-setup-prometheus.sh
# Description: Deploy Prometheus for metrics collection and storage
# Usage: ./01-setup-prometheus.sh [target_host]

set -e
TARGET_HOST=${1:-rancher-desktop}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Call Ansible playbook
ansible-playbook "$PROJECT_ROOT/ansible/playbooks/030-setup-prometheus.yml" -e "target_host=$TARGET_HOST"
```

---

### Comparison: DCT vs UIS

| Feature | DCT | UIS Current |
|---------|-----|-------------|
| Metadata in scripts | Yes (SCRIPT_ID, SCRIPT_NAME, etc.) | No (just comments) |
| Config-driven enable | `enabled-tools.conf` | Move files to `not-in-use/` |
| Scanner library | `component-scanner.sh` | None |
| Interactive menu | `dev-setup.sh` | None |
| Update mechanism | `dev-update.sh` | Fork & git pull |
| JSON generation | `dev-docs.sh` | Manual `services.json` |
| User customization | `.devcontainer.extend/` | Fork entire repo |
| Remove scripts | `--uninstall` flag | Separate `*-remove-*.sh` files |
| Script naming | `install-dev-python.sh` | `01-setup-prometheus.sh` |
| Ordering | Category-based (no numbers) | Number prefix (01-, 02-) |

---

## Tasks

### Research (Completed)
- [x] Study DCT `dev-update.sh` in detail
- [x] Study DCT `enabled-tools.conf` processing
- [x] Study DCT `postCreateCommand.sh` (how it reads configs)
- [x] Map current UIS scripts to understand what exists
- [x] Investigate root folder structure (ansible/, manifests/, hosts/, cloud-init/, topsecret/)
- [x] Analyze secrets management system
- [x] Understand copy model (docker cp vs mounts)

### Design Decisions (Resolved)
- [x] Package name and format → **Container image: `ghcr.io/sovereignsky/uis-provision-host`**
- [x] User customization folder name and location → **`topsecret/config/` (uses existing topsecret folder)**
- [x] How to handle manifests (in package vs separate) → **Baked into container**
- [x] How to handle Ansible playbooks → **Baked into container**
- [x] Version numbering scheme → **SemVer (1.0.0) + container image tags**
- [x] Keep number prefixes for ordering or use dependencies? → **Hybrid: keep numbers + add SCRIPT_REQUIRES**
- [x] Merge setup/remove into single script with flags or keep separate? → **Keep separate + add SCRIPT_REMOVE metadata**

### Implementation (To Do)

**Completed in PLAN-003:**
- [x] Create `Dockerfile.uis-provision-host`
- [x] Create CI/CD workflow for container build
- [x] Create `./uis` thin wrapper script
- [x] Container image at `ghcr.io/terchris/uis-provision-host:latest`
- [x] Size reduced from 2.7GB to 1.86GB
- [x] Auto-pull from registry
- [x] Branded welcome page

**Remaining for full orchestration system (see PLAN-004):**

All remaining items are detailed in [PLAN-004-uis-orchestration-system.md](PLAN-004-uis-orchestration-system.md):
- Phase 1: Foundation - Library and Scanner
- Phase 2: Service Scripts with Metadata
- Phase 3: Config System - enabled-services.conf
- Phase 4: CLI Entry Point
- Phase 5: Interactive Menu
- Phase 6: Init Wizard
- Phase 7: Install Script
- Phase 8: Platform Support (Windows/WSL2)

### Container Optimization (To Do)
- [ ] Add `none` option to `provision-host-01-cloudproviders.sh` to skip cloud CLI installation
- [ ] Create `topsecret/config/container-options.conf` template for tool selection
- [ ] UIS setup system to read available options from `provision-host-01-cloudproviders.sh`
- [ ] `uis init` wizard asks user which cloud providers they need
- [ ] Consider multiple container image variants (full/local/azure)
- [ ] **Review provision-host-*.sh scripts** - remove unused tools (MkDocs), make optional tools configurable
- [ ] Remove `provision-host-05-builddocs.sh` (MkDocs no longer used)
- [ ] Remove MkDocs installation from `provision-host-00-coresw.sh`

---

## Design Decisions (Analysis & Recommendations)

### 1. Package Name and Format

**Options**:
- A) `uis-kubernetes.zip` - Matches content
- B) `uis-provision-host.zip` - Matches folder
- C) `urbalurba-stack.zip` - Product name

**Recommendation**: Option A - `uis-kubernetes.zip`
- Clear what's included
- Leaves room for future `uis-ansible.zip` etc.
- Format: `.zip` (like DCT, cross-platform)
- Hosted: GitHub releases (like DCT)

---

### 2. User Customization Folder Location

**Options**:
- A) `/uis.extend/` in repo root (like DCT's `.devcontainer.extend/`)
- B) `/provision-host/uis.extend/` inside provision-host
- C) `~/.uis/` in user home directory

**Recommendation**: Option A - `/uis.extend/` in repo root
- Consistent with DCT pattern
- Easy to find
- Clearly separated from distributed files
- Can be gitignored for user secrets

---

### 3. Keep Number Prefixes or Use Dependencies?

**Current**: `01-setup-prometheus.sh`, `02-setup-tempo.sh` (order by number)

**Options**:
- A) Keep number prefixes (current system works)
- B) Remove numbers, use dependency metadata (SCRIPT_REQUIRES)
- C) Hybrid: Keep numbers for human readability, but scanner reads SCRIPT_REQUIRES

**Recommendation**: Option C - Hybrid approach
- Keep `01-setup-prometheus.sh` naming (humans can see order)
- Add `SCRIPT_REQUIRES="prometheus"` to scripts that depend on others
- `uis-setup --deploy` resolves dependencies automatically
- Backwards compatible with `provision-kubernetes.sh`

---

### 4. Merge Setup/Remove into Single Script or Keep Separate?

**Current**: Separate files (`01-setup-prometheus.sh`, `01-remove-prometheus.sh`)

**Options**:
- A) Merge into single script with `--uninstall` flag (like DCT)
- B) Keep separate (current system)
- C) Keep separate but add metadata pointing to removal script

**Recommendation**: Option B - Keep separate for now
- Less invasive change
- Backwards compatible
- Add metadata `SCRIPT_REMOVE="01-remove-prometheus.sh"` to link them
- Future: Can migrate to flags later if desired

---

### 5. Manifests Handling

**Current**: `manifests/` folder with numbered YAML files

**Options**:
- A) Include in distribution package
- B) Keep separate (users can modify)
- C) Split: Core manifests in package, user overrides in `uis.extend/`

**Recommendation**: Option C - Split approach
- `manifests/` - Core manifests (in distribution)
- `uis.extend/custom-manifests/` - User additions
- `uis.extend/manifest-overrides/` - Patches to core manifests

---

### 6. Ansible Playbooks Handling

**Current**: `ansible/playbooks/` with numbered playbooks

**Recommendation**: Include in distribution
- Scripts call playbooks, so they must be present
- Playbooks are part of the "product"
- User customization via Ansible variables in `uis.extend/ansible-vars/`

---

### 7. Version Numbering Scheme

**Options**:
- A) SemVer: `1.0.0`, `1.1.0`, `2.0.0`
- B) CalVer: `2026.01`, `2026.02`
- C) Simple incrementing: `1`, `2`, `3`

**Recommendation**: Option A - SemVer
- Industry standard
- Clear meaning: major.minor.patch
- Breaking changes = major bump
- `.version` file format: `VERSION=1.0.0`

---

### 8. Metadata Format (UIS-Specific Adaptations)

**DCT Metadata Fields**:
```bash
SCRIPT_ID="dev-python"
SCRIPT_NAME="Python Development Tools"
SCRIPT_DESCRIPTION="Install Python development environment"
SCRIPT_CATEGORY="LANGUAGE_DEV"
SCRIPT_CHECK_COMMAND="command -v python3"
SCRIPT_PREREQUISITES="config-identity"
```

**Proposed UIS Metadata Fields**:
```bash
# === Service Metadata (Required) ===
SCRIPT_ID="prometheus"
SCRIPT_NAME="Prometheus"
SCRIPT_DESCRIPTION="Metrics collection and storage for observability"
SCRIPT_CATEGORY="MONITORING"

# === UIS-Specific (Optional) ===
SCRIPT_PLAYBOOK="030-setup-prometheus.yml"        # Ansible playbook
SCRIPT_MANIFEST="030-prometheus.yaml"              # Primary manifest
SCRIPT_CHECK_COMMAND="kubectl get pods -n monitoring -l app=prometheus --no-headers | grep -q Running"
SCRIPT_REMOVE="01-remove-prometheus.sh"            # Removal script
SCRIPT_REQUIRES=""                                 # Dependencies (space-separated SCRIPT_IDs)

# === Website Metadata (Optional) ===
SCRIPT_ABSTRACT="Time-series database for metrics"
SCRIPT_LOGO="prometheus.svg"
SCRIPT_WEBSITE="https://prometheus.io"
SCRIPT_SUMMARY="Prometheus is an open-source systems monitoring toolkit..."
SCRIPT_TAGS="metrics monitoring alerting time-series"
SCRIPT_RELATED="grafana loki tempo"
```

---

## Open Questions (Remaining)

1. **How to handle the website/docs?**
   - **Recommendation**: Same repo but excluded from distribution
   - Website is built from metadata in scripts
   - `website/` folder excluded from `uis-kubernetes.zip`

2. **What scanner function should UIS have?**
   - DCT has: `scan_install_scripts`, `scan_service_scripts`, etc.
   - UIS needs: `scan_setup_scripts()` for `*-setup-*.sh` files
   - Follow same pattern but adapted for UIS naming

3. **Provision-host container integration?**
   - `uis.extend/` mounted into container at `/mnt/urbalurbadisk/uis.extend/`
   - Scripts read from there when running inside provision-host
   - `uis-setup.sh` on host machine calls into container

---

## Secrets Management System Analysis

### Current topsecret/ Structure
```
topsecret/
├── secrets-templates/              # Git tracked - base templates with ${VARIABLES}
│   ├── 00-common-values.env.template    # Central config (domains, passwords, API keys)
│   ├── 00-master-secrets.yml.template   # Master K8s secrets template
│   ├── 01-core-secrets.yml.template
│   ├── 02-database-secrets.yml.template
│   ├── 07-ai-secrets.yml.template
│   ├── 09-network-secrets.yml.template
│   ├── 12-auth-secrets.yml.template
│   └── ...
│
├── secrets-config/                 # Gitignored - USER EDITS THIS
│   └── (copied from templates, user fills in actual values)
│
├── secrets-generated/              # Gitignored - temp processing
├── kubernetes/                     # Gitignored - final output
│   └── kubernetes-secrets.yml      # kubectl apply this
│
└── create-kubernetes-secrets.sh    # Generates K8s secrets from templates
```

### Key Configuration Variables (00-common-values.env.template)
```bash
# Network domains
BASE_DOMAIN_LOCALHOST=localhost
BASE_DOMAIN_TAILSCALE=your-domain.ts.net
BASE_DOMAIN_CLOUDFLARE=your-domain.com

# Default credentials (cascades to all services)
DEFAULT_ADMIN_EMAIL=admin@example.com
DEFAULT_ADMIN_PASSWORD=SecretPassword123
DEFAULT_DATABASE_PASSWORD=DatabasePassword456

# External services
TAILSCALE_CLIENTID=...
TAILSCALE_CLIENTSECRET=...
CLOUDFLARE_DNS_TOKEN=...
AUTHENTIK_SECRET_KEY=...
GITHUB_ACCESS_TOKEN=...
```

### Mapping to New Structure
| Current | Container Model | Purpose |
|---------|-----------------|---------|
| `topsecret/secrets-templates/` | Baked into container | Distributed templates |
| `topsecret/secrets-config/` | User mounts their `topsecret/` | User values (gitignored) |
| `topsecret/kubernetes/` | Same path (in mounted folder) | Generated output |
| `topsecret/create-kubernetes-secrets.sh` | `uis secrets generate` command | Secrets generator |
| (new) `topsecret/config/` | User mounts their `topsecret/` | Config files (enabled-services.conf, etc.) |

---

## Future User Journey: Container Model

### Key Design Principle

> **Container-as-Deliverable**: UIS is delivered as a container image with everything baked in.
> User only needs their `topsecret/` folder locally (same structure as today, with new `config/` subfolder).
> All commands run inside the container. No OS-specific scripting needed.

### User's Local Folder
```
my-project/
├── topsecret/                      # User's folder (mounted into container)
│   ├── secrets-config/             # User-edited secret values
│   │   └── 00-common-values.env    # User's credentials
│   ├── secrets-generated/          # Temp processing
│   ├── kubernetes/                 # Generated K8s secrets
│   └── config/                     # NEW - user config files
│       ├── enabled-services.conf   # Which services to deploy
│       ├── cluster-config.sh       # Cluster type, project name, domain
│       └── service-overrides/      # Per-service customization
│
└── (user's own project files...)
```

### Installation Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ STEP 1: INSTALL                                                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│ $ curl -fsSL https://uis.sovereignsky.no/install.sh | bash                  │
│                                                                              │
│    1. Checks Docker is installed                                            │
│    2. Pulls container image:                                                │
│       docker pull ghcr.io/sovereignsky/uis-provision-host:latest            │
│    3. Creates topsecret/ folder with templates                              │
│    4. Adds topsecret/ to .gitignore                                         │
│    5. Creates 'uis' wrapper script                                          │
│    6. Prints next steps                                                     │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│ STEP 2: INITIALIZE                                                           │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│ $ ./uis init                                                                │
│                                                                              │
│    [Starts container with mounts, runs init wizard inside:]                 │
│                                                                              │
│    ? Project name: my-project                                               │
│    ? Cluster type: (use arrows)                                             │
│      > rancher-desktop  (Local laptop - recommended)                        │
│        azure-microk8s   (Azure VM)                                          │
│        raspberry-pi     (Raspberry Pi cluster)                              │
│    ? Base domain: localhost                                                 │
│    ? Admin email: admin@example.com                                         │
│    ? Admin password: ********                                               │
│                                                                              │
│    ✅ Wrote topsecret/config/cluster-config.sh                              │
│    ✅ Wrote topsecret/secrets-config/00-common-values.env                   │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│ STEP 3: CREATE CLUSTER (if needed)                                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│ $ ./uis cluster create                                                      │
│                                                                              │
│    📋 Reading cluster config from topsecret/config/cluster-config.sh        │
│    🔧 Cluster type: rancher-desktop                                         │
│    🚀 Running hosts/install-rancher-kubernetes.sh                           │
│    ✅ Cluster created and configured                                        │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│ STEP 4: GENERATE SECRETS & DEPLOY                                           │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│ $ ./uis secrets generate                                                    │
│ $ ./uis deploy                                                              │
│                                                                              │
│    📋 Reading topsecret/config/enabled-services.conf                        │
│    🚀 Deploying enabled services...                                         │
│       ✅ nginx (core)                                                       │
│       ✅ prometheus (monitoring)                                            │
│       ✅ grafana (monitoring)                                               │
│    ✅ Deployment complete                                                   │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│ STEP 5: UPDATE (later)                                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│ $ ./uis update                                                              │
│                                                                              │
│    📋 Current version: 1.2.0                                                │
│    📥 Pulling latest image...                                               │
│       docker pull ghcr.io/sovereignsky/uis-provision-host:latest            │
│    📦 New version: 1.3.0                                                    │
│    🔄 Recreating container...                                               │
│    ✅ Updated (your topsecret/ folder preserved)                            │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Command Summary

| Command | Description | Runs In |
|---------|-------------|---------|
| `uis init` | Interactive setup wizard | provision-host |
| `uis cluster create` | Create K8s cluster | provision-host |
| `uis cluster delete` | Delete K8s cluster | provision-host |
| `uis cluster status` | Show cluster status | provision-host |
| `uis secrets generate` | Generate K8s secrets | provision-host |
| `uis secrets apply` | Apply secrets to cluster | provision-host |
| `uis deploy` | Deploy enabled services | provision-host |
| `uis deploy <service>` | Deploy specific service | provision-host |
| `uis remove <service>` | Remove specific service | provision-host |
| `uis status` | Show deployment status | provision-host |
| `uis setup` | Interactive menu (like dev-setup) | provision-host |
| `uis update` | Update UIS to latest version | host machine |
| `uis shell` | Enter provision-host shell | provision-host |

### Thin Wrapper Script (./uis)

The wrapper script created by install.sh:
1. Starts container with mounts if not running
2. Executes command inside container
3. Returns output to user

```bash
#!/bin/bash
# ./uis - Thin wrapper that runs commands in provision-host container

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER_NAME="uis-provision-host"
IMAGE="ghcr.io/sovereignsky/uis-provision-host:latest"

# Start container if not running
start_container() {
    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo "Starting UIS container..."

        # Remove old container if exists
        docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

        # Start with mounts for user config/secrets
        docker run -d --name "$CONTAINER_NAME" \
            -v "$SCRIPT_DIR/topsecret:/mnt/urbalurbadisk/topsecret" \
            -v "$HOME/.kube:/home/ansible/.kube:ro" \
            "$IMAGE"
    fi
}

# Handle commands
case "$1" in
    update)
        echo "Pulling latest UIS image..."
        docker pull "$IMAGE"
        docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
        echo "✅ Updated. Run './uis init' to start."
        ;;
    *)
        start_container
        docker exec -it "$CONTAINER_NAME" /mnt/urbalurbadisk/provision-host/uis/manage/uis-cli.sh "$@"
        ;;
esac
```

### How Mounts Work (New Model)

**Current system**: Files are **copied** into container using `docker cp` (see `copy2provisionhost.sh`)

**New container model**: User's `topsecret/` folder is **mounted** into the container:

| Local Path | Container Path | Method |
|------------|----------------|--------|
| `./topsecret/` | `/mnt/urbalurbadisk/topsecret/` | Mount (overlays baked-in templates) |
| `~/.kube/` | `/home/ansible/.kube/` (ro) | Mount (read-only) |

**Note**: UIS product files (ansible, manifests, etc.) are baked into the container at `/mnt/urbalurbadisk/` - same path as today. User's mounted `topsecret/` folder overlays the baked-in templates.

---

## Container Size Optimization

### Current Size Analysis

The current provision-host container is **~2.7GB** (virtual size). Major space consumers:

| Component | Size | Required for Local Dev? |
|-----------|------|------------------------|
| **Azure CLI** | **637MB** | ❌ No (only for Azure deployments) |
| Ansible collections (enterprise) | ~250MB | ❌ No (Cisco, Fortinet, F5, Dell, NetApp) |
| k9s | 116MB | ✅ Yes (useful for debugging) |
| Helm | 56MB | ✅ Yes |
| kubectl | 53MB | ✅ Yes |
| cloudflared | 38MB | ⚠️ Only for Cloudflare tunnels |
| Tailscale | 24MB | ⚠️ Only for Tailscale access |

**Potential savings**: ~925MB by removing Azure CLI + unused Ansible collections + cloudflared

### Current Problem: No Way to Skip Cloud Providers

The installation chain:
```
install-rancher.sh [cloud-provider]  (default: az)
    ↓
provision-host-container-create.sh "$CLOUD_PROVIDER"
    ↓
provision-host-provision.sh "$CLOUD_PROVIDER"
    ↓
provision-host-01-cloudproviders.sh "$CLOUD_PROVIDER"
```

**Valid options** in `provision-host-01-cloudproviders.sh`:
- `az/azure` (default) - Azure CLI (637MB)
- `aws` - AWS CLI
- `gcp/google` - Google Cloud SDK
- `oci/oracle` - Oracle Cloud CLI
- `tf/terraform` - Terraform
- `all` - All of the above

**Missing**: A `none` or `skip` option to not install any cloud provider tools.

### Provision Scripts Need Revision

The `provision-host/provision-host-*.sh` scripts install several tools that may no longer be needed:

| Script | Installs | Status |
|--------|----------|--------|
| `provision-host-00-coresw.sh` | MkDocs + Material theme | ❌ **Unused** - migrated to Docusaurus |
| `provision-host-00-coresw.sh` | psycopg2-binary | ✅ Needed for Ansible PostgreSQL |
| `provision-host-00-coresw.sh` | GitHub CLI | ⚠️ Review if needed |
| `provision-host-01-cloudproviders.sh` | Azure/AWS/GCP/OCI CLI | ⚠️ Should be optional |
| `provision-host-02-kubetools.sh` | kubectl, helm, k9s | ✅ Needed |
| `provision-host-03-net.sh` | Tailscale, cloudflared | ⚠️ Should be optional |
| `provision-host-04-helmrepo.sh` | Helm repos | ✅ Needed |
| `provision-host-05-builddocs.sh` | Builds MkDocs | ❌ **Unused** - remove entire script |

**Action needed**: Review and clean up these scripts to remove unused tools (MkDocs) and make optional tools configurable.

### Future UIS Setup System Requirements

The new UIS orchestration system (`provision-host/uis/`) should:

1. **Read options from existing scripts** - Parse `provision-host-01-cloudproviders.sh` to discover available cloud provider options dynamically
2. **Add `none` option** - Allow users to skip cloud provider installation entirely
3. **Config-driven selection** - User specifies in `topsecret/config/container-options.conf`:
   ```bash
   # Container tool options
   CLOUD_PROVIDER=none          # none, az, aws, gcp, oci, tf, all
   INSTALL_K9S=true             # Kubernetes TUI
   INSTALL_CLOUDFLARED=false    # Cloudflare tunnel client
   INSTALL_TAILSCALE=true       # Tailscale VPN
   ```
4. **Multiple container variants** (optional):
   - `uis-provision-host:latest` - Full (~2.7GB, all cloud providers)
   - `uis-provision-host:local` - Slim (~1.8GB, no cloud providers)
   - `uis-provision-host:azure` - Azure only (~2.4GB)

### Implementation Notes

- The `uis init` wizard should ask which cloud providers the user needs
- Container build can be parameterized via build args
- Or: Single image with all tools, but lazy-load/download cloud CLIs on first use

---

## Minimal First Delivery Plan

> **Goal**: Create a working container-as-deliverable with minimal changes to prove the concept.
> Target: Local development with Rancher Desktop (no cloud providers needed).

### What We Build

A slim container image (~1.8GB instead of ~2.7GB) that:
- Has UIS product baked in at `/mnt/urbalurbadisk/`
- Skips Azure CLI, MkDocs, and other unused tools
- Works with existing `provision-host/kubernetes/` scripts (no changes to them)
- User mounts their `topsecret/` folder

### Minimal Changes Required

#### 1. Add `none` option to cloud providers script
**File**: `provision-host/provision-host-01-cloudproviders.sh`

Add case for `none`:
```bash
case "${1:-az}" in
    "none"|"skip")
        echo "Skipping cloud provider installation"
        add_status "Cloud Providers" "Status" "Skipped (none selected)"
        ;;
    "az"|"azure")
        # ... existing code
```

#### 2. Remove MkDocs installation
**File**: `provision-host/provision-host-00-coresw.sh`

Remove or comment out:
```bash
# Remove these lines:
# echo "Installing MkDocs and Material theme for documentation"
# sudo pip3 install mkdocs-material
```

#### 3. Skip MkDocs build script
**File**: `provision-host/provision-host-provision.sh`

Remove `provision-host-05-builddocs.sh` from the PROVISION_SCRIPTS array:
```bash
PROVISION_SCRIPTS=(
    "provision-host-00-coresw.sh"
    "provision-host-01-cloudproviders.sh"
    "provision-host-02-kubetools.sh"
    "provision-host-03-net.sh"
    "provision-host-04-helmrepo.sh"
    # "provision-host-05-builddocs.sh"  # Removed - using Docusaurus now
)
```

#### 4. Create Dockerfile for container image
**File**: `Dockerfile.uis-provision-host` (new file in repo root)

```dockerfile
# Build from existing provision-host base
FROM provision-host-rancher-provision-host:latest as base

# Or build fresh from Ubuntu
FROM ubuntu:22.04

# ... base setup from existing Dockerfile ...

# Copy UIS product files (baked in)
COPY ansible/ /mnt/urbalurbadisk/ansible/
COPY manifests/ /mnt/urbalurbadisk/manifests/
COPY hosts/ /mnt/urbalurbadisk/hosts/
COPY cloud-init/ /mnt/urbalurbadisk/cloud-init/
COPY networking/ /mnt/urbalurbadisk/networking/
COPY provision-host/ /mnt/urbalurbadisk/provision-host/
COPY scripts/ /mnt/urbalurbadisk/scripts/
COPY topsecret/secrets-templates/ /mnt/urbalurbadisk/topsecret/secrets-templates/

# Run provisioning with CLOUD_PROVIDER=none
RUN cd /mnt/urbalurbadisk/provision-host && \
    ./provision-host-provision.sh none

# Create mount points
RUN mkdir -p /mnt/urbalurbadisk/topsecret/config \
             /mnt/urbalurbadisk/topsecret/secrets-config

WORKDIR /mnt/urbalurbadisk
```

#### 5. Create thin wrapper script
**File**: `uis` (new file in repo root)

```bash
#!/bin/bash
# UIS - Urbalurba Infrastructure Stack CLI wrapper

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER_NAME="uis-provision-host"
IMAGE="ghcr.io/sovereignsky/uis-provision-host:local"

start_container() {
    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo "Starting UIS container..."
        docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
        docker run -d --name "$CONTAINER_NAME" \
            -v "$SCRIPT_DIR/topsecret:/mnt/urbalurbadisk/topsecret" \
            -v "$HOME/.kube:/home/ansible/.kube:ro" \
            "$IMAGE"
        sleep 2
    fi
}

case "$1" in
    start)
        start_container
        echo "✅ UIS container started"
        ;;
    stop)
        docker stop "$CONTAINER_NAME" 2>/dev/null
        echo "✅ UIS container stopped"
        ;;
    shell)
        start_container
        docker exec -it "$CONTAINER_NAME" bash
        ;;
    provision)
        start_container
        docker exec -it "$CONTAINER_NAME" bash -c \
            "cd /mnt/urbalurbadisk/provision-host/kubernetes && ./provision-kubernetes.sh rancher-desktop"
        ;;
    *)
        start_container
        docker exec -it "$CONTAINER_NAME" "$@"
        ;;
esac
```

### Testing the Minimal Delivery

```bash
# 1. Build the slim container locally
docker build -f Dockerfile.uis-provision-host -t uis-provision-host:local .

# 2. Check size (should be ~1.8GB, not ~2.7GB)
docker images uis-provision-host:local

# 3. Create topsecret folder with config
mkdir -p topsecret/config topsecret/secrets-config
cp topsecret/secrets-templates/* topsecret/secrets-config/

# 4. Test the wrapper
./uis shell                    # Enter container
./uis provision                # Run kubernetes provisioning

# 5. Verify services deployed
kubectl get pods -A
```

### Success Criteria

- [ ] Container builds successfully
- [ ] Container size is ~1.8GB (not ~2.7GB)
- [ ] `./uis shell` enters the container
- [ ] `./uis provision` deploys services to rancher-desktop
- [ ] Existing `provision-host/kubernetes/` scripts work unchanged
- [ ] User's `topsecret/` changes are visible in container (mount works)

### What We DON'T Do Yet

- ❌ New `provision-host/uis/` orchestration system
- ❌ `enabled-services.conf` config-driven deployment
- ❌ `uis init` wizard
- ❌ CI/CD pipeline to publish container
- ❌ Install script (`curl ... | bash`)

These come in later phases after the minimal delivery is proven.

---

## Next Steps

1. ~~Complete research tasks above~~ ✅
2. ~~Design user journey~~ ✅
3. ~~Get user feedback on proposed design~~ ✅ (Container-as-Deliverable model approved)
4. ~~Create detailed implementation plan (PLAN-003)~~ ✅
5. ~~Implement minimal container delivery (PLAN-003)~~ ✅
6. ~~Create PLAN-004: Full UIS orchestration system~~ ✅
7. **Implement PLAN-004** ← Next
   - See [PLAN-004-uis-orchestration-system.md](PLAN-004-uis-orchestration-system.md)
   - Phase 1: Foundation - Library and Scanner
   - Phase 2: Service Scripts with Metadata
   - Phase 3: Config System - enabled-services.conf
   - Phase 4: CLI Entry Point
   - Phase 5: Interactive Menu
   - Phase 6: Init Wizard
   - Phase 7: Install Script
   - Phase 8: Platform Support
8. Test end-to-end and iterate
9. Document migration path for existing users

---

## Implementation Phases (Container-as-Deliverable)

> **CRITICAL**: Do NOT modify `provision-host/kubernetes/` or anything below it.
> Build the new system in a completely separate location so existing system continues working.

### Phase 1: Create New Orchestration Layer
1. Create `provision-host/uis/` folder structure (parallel to existing `kubernetes/`)
2. Create `lib/service-scanner.sh` based on DCT pattern
3. Create new scripts WITH metadata from scratch (copy logic from existing scripts)
4. Create `manage/uis-cli.sh` - CLI entry point called by wrapper
5. Existing `provision-host/kubernetes/` remains untouched

### Phase 2: Container Image Build
1. Create `Dockerfile.uis-provision-host` that:
   - Starts from existing provision-host base image
   - Copies repo content to `/mnt/urbalurbadisk/` (same path as today)
   - Excludes: website/, docs/, .devcontainer/, .git/
   - Includes: ansible/, manifests/, hosts/, cloud-init/, provision-host/, networking/, topsecret/
2. Set up CI/CD workflow (`.github/workflows/build-uis-container.yml`)
3. Push to `ghcr.io/sovereignsky/uis-provision-host:latest` and versioned tags

### Phase 3: Install Script & Wrapper
1. Create `install.sh` (hosted at `uis.sovereignsky.no/install.sh`)
   - Validates Docker is installed
   - Pulls container image
   - Creates `topsecret/` folder with templates (config/ and secrets-config/ subfolders)
   - Adds `topsecret/` to .gitignore
   - Creates `./uis` wrapper script
2. Create `./uis` thin wrapper script
   - Starts container with mounts if not running
   - Passes commands to `uis-cli.sh` inside container
   - Handles `update` command locally (docker pull)

### Phase 4: User Configuration System
1. Create `topsecret/config/` template structure:
   - `cluster-config.sh` - Cluster type, project name, domain
   - `enabled-services.conf` - Services to deploy
   - `service-overrides/` - Per-service customization
2. Create `enabled-services.conf` processor in `uis-cli.sh`
3. Create init wizard (`uis init`)
4. Test config-driven deployment

### Phase 5: Secrets Management
1. Adapt current topsecret system for container model:
   - Templates baked in at `/mnt/urbalurbadisk/topsecret/secrets-templates/` (same as today)
   - User values at `/mnt/urbalurbadisk/uis.secrets/config/` (mounted)
   - Generated output at `/mnt/urbalurbadisk/uis.secrets/generated/` (mounted)
2. Create `uis secrets generate` command
3. Create `uis secrets apply` command

### Phase 6: Validation & Documentation
1. Test complete flow: install → init → cluster create → deploy
2. Test update flow: `./uis update` pulls new image, preserves user config
3. Create migration guide for existing fork users
4. Document all commands and configuration options

---

## Repository vs Container Structure

### Repository Structure (Unchanged)
```
urbalurba-infrastructure/               # Repository (source code)
│
├── ansible/                            # Playbooks
│   └── playbooks/
│
├── manifests/                          # K8s manifests
│
├── hosts/                              # Cluster setup scripts
│   ├── install-rancher-kubernetes.sh
│   ├── install-azure-microk8s.sh
│   └── ...
│
├── cloud-init/                         # VM templates
│
├── provision-host/
│   ├── kubernetes/                     # EXISTING - DO NOT TOUCH
│   │   ├── 01-core/
│   │   ├── 11-monitoring/
│   │   └── provision-kubernetes.sh
│   │
│   └── uis/                            # NEW - Build from scratch
│       ├── lib/
│       │   └── service-scanner.sh
│       ├── manage/
│       │   └── uis-cli.sh              # Entry point for ./uis wrapper
│       ├── services/                   # New scripts with metadata
│       │   ├── core/
│       │   ├── monitoring/
│       │   └── ...
│       └── .version
│
├── topsecret/
│   └── secrets-templates/              # Base templates (baked into container)
│
├── website/                            # NOT in container
├── docs/                               # NOT in container
├── .devcontainer/                      # NOT in container
└── .github/workflows/                  # Builds the container
```

### Container Image Contents
```
ghcr.io/sovereignsky/uis-provision-host:1.0.0
│
├── /mnt/urbalurbadisk/                 # UIS product (baked in) - SAME PATH AS TODAY
│   ├── ansible/
│   ├── manifests/
│   ├── hosts/
│   ├── cloud-init/
│   ├── networking/
│   ├── provision-host/
│   │   ├── kubernetes/                 # Old system (for backwards compat)
│   │   └── uis/                        # New orchestration
│   ├── topsecret/                      # Overlaid by user's mounted folder
│   │   └── secrets-templates/          # Base templates (baked in)
│   └── .version
│
└── (tools: ansible, kubectl, helm, az, tailscale, etc.)
```

### What's Shared
- `ansible/playbooks/` - Both old and new orchestration call the same playbooks
- `manifests/` - Both systems use the same manifests
- Container image includes both old `kubernetes/` and new `uis/` systems

### What's Separate
- `provision-host/kubernetes/` - Old orchestration (DO NOT TOUCH)
- `provision-host/uis/` - New orchestration with metadata
- User's local `topsecret/` folder (config + secrets, mounted into container)
