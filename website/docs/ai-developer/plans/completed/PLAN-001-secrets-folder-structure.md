# PLAN-001: Secrets Templates & Initialization Code

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed

**Goal**: Create the templates and initialization code that will generate `.uis.extend/` and `.uis.secrets/` folders when users run the UIS system.

**Completed**: 2025-01-23

**Last Updated**: 2025-01-23

**Branch**: `feature/secrets-migration`

**Related**: [INVESTIGATE-secrets-consolidation.md](./INVESTIGATE-secrets-consolidation.md)

---

## Context: Contributor vs User

**We are contributors** to the urbalurba-infrastructure repo. We build:
- Templates (baked into the container image)
- Initialization code (runs when user first uses UIS)
- Scripts that read from user folders

**Users create** these folders when they run `./uis`:
- `.uis.extend/` - User's committed configuration
- `.uis.secrets/` - User's gitignored secrets

These folders do NOT exist in this repo - they are created at runtime in the user's working directory.

---

## Overview

This plan creates:
1. Template files in `provision-host/uis/templates/` (baked into container)
2. Initialization script that creates user folders on first run
3. Updated `uis` wrapper to handle first-run and mounting

**Blocks**: PLAN-002, PLAN-003, PLAN-004 depend on this being complete.

---

## Phase 1: Create Template Directory Structure — ✅ DONE

Templates live in the repo and get baked into the container image.

### Tasks

- [x] 1.1 Create template directory structure (merged with existing):
  ```
  provision-host/uis/templates/
  ├── uis.secrets/                # Templates for .uis.secrets/
  │   ├── cloud-accounts/         #   Cloud provider credentials
  │   ├── service-keys/           #   Service API keys
  │   ├── network/                #   Network config (WiFi, etc.)
  │   ├── ssh/                    #   SSH keys (generated)
  │   └── generated/              #   Generated files output
  ├── uis.extend/                 # Templates for .uis.extend/
  │   ├── hosts/                  #   Host configurations
  │   │   ├── managed/            #     AKS, GKE, EKS
  │   │   ├── cloud-vm/           #     Azure VMs, GCP VMs
  │   │   ├── physical/           #     Raspberry Pi
  │   │   └── local/              #     Rancher Desktop
  │   ├── enabled-services.conf.default
  │   ├── enabled-tools.conf.default
  │   └── cluster-config.sh.default
  └── ubuntu-cloud-init/          # Cloud-init templates
  ```

- [x] 1.2 Create folder README files explaining each template category

### Validation

User confirms directory structure is correct.

---

## Phase 2: Create Secret Templates — ✅ DONE

These templates are copied to user's `.uis.secrets/` when they add hosts that need them.

### Tasks

- [x] 2.1 Create `provision-host/uis/templates/uis.secrets/defaults.env.template`:
  ```bash
  # Default values for VM provisioning
  # This file is copied to .uis.secrets/defaults.env

  # VM user account
  VM_USERNAME="ansible"
  VM_PASSWORD="changeme"
  ```

- [x] 2.2 Create `provision-host/uis/templates/uis.secrets/cloud-accounts/azure.env.template` ✓

- [x] 2.3 Create `provision-host/uis/templates/uis.secrets/cloud-accounts/gcp.env.template` ✓

- [x] 2.4 Create `provision-host/uis/templates/uis.secrets/service-keys/tailscale.env.template` ✓

- [x] 2.5 Create `provision-host/uis/templates/uis.secrets/service-keys/openai.env.template` ✓

- [x] 2.6 Create `provision-host/uis/templates/uis.secrets/service-keys/cloudflare.env.template` ✓

- [x] 2.7 Create `provision-host/uis/templates/uis.secrets/network/wifi.env.template` ✓

### Validation

User confirms templates are correct and complete.

---

## Phase 3: Create Host Config Templates — ✅ DONE

Templates for `.uis.extend/hosts/` configurations.

### Tasks

- [x] 3.1 Create `provision-host/uis/templates/uis.extend/hosts/managed/azure-aks.conf.template`:
  ```bash
  # Azure AKS Cluster Configuration
  # Non-sensitive settings (safe to commit)

  # Which credentials to use (references file in .uis.secrets/cloud-accounts/)
  CREDENTIALS="azure-default"

  # Cluster settings
  RESOURCE_GROUP="rg-urbalurba-aks"
  CLUSTER_NAME="my-aks-cluster"
  LOCATION="westeurope"
  NODE_COUNT=3
  NODE_SIZE="Standard_B2ms"
  KUBERNETES_VERSION="1.28"
  ```

- [x] 3.2 Create `provision-host/uis/templates/uis.extend/hosts/cloud-vm/azure-microk8s.conf.template` ✓

- [x] 3.3 Create `provision-host/uis/templates/uis.extend/hosts/physical/raspberry-pi.conf.template` ✓

- [x] 3.4 Create `provision-host/uis/templates/uis.extend/hosts/local/rancher-desktop.conf.template` ✓

- [x] 3.5 Create README in `provision-host/uis/templates/uis.extend/hosts/` explaining host types ✓

### Validation

User confirms host templates cover the main use cases.

---

## Phase 4: Create Default Config Templates — ✅ DONE

Templates for `.uis.extend/` root configuration files.

**Note:** These already exist in `templates/uis.extend/` with the existing UIS structure.

### Tasks

- [x] 4.1 Config templates exist in `provision-host/uis/templates/uis.extend/`:
  - `enabled-services.conf.default`
  - `enabled-tools.conf.default`
  - `cluster-config.sh.default`

- [x] 4.2 README.md exists documenting the config options

### Validation

User confirms default config is appropriate for first-run.

---

## Phase 5: Move Cloud-Init Templates — ✅ DONE

Move existing cloud-init templates into the new structure.

### Tasks

- [x] 5.1 Copy existing cloud-init templates to new location:
  - `azure-cloud-init-template.yml`
  - `gcp-cloud-init-template.yml`
  - `multipass-cloud-init-template.yml`
  - `raspberry-cloud-init-template.yml`
  - `provision-cloud-init-template.yml`

- [x] 5.2 Templates already use consistent `URB_` variable naming

- [x] 5.3 Add README documenting the templates ✓

### Validation

User confirms cloud-init templates are in place.

---

## Phase 6: Update Initialization Script — ✅ DONE

Updated existing `first-run.sh` to create new folder structure.

### Tasks

- [x] 6.1 Updated `provision-host/uis/lib/first-run.sh` with:
  ```bash
  # Initialize user's .uis.extend/ folder
  init_uis_extend() {
    local user_dir="$1"  # Path where user folders should be created
    # Create folder structure
    # Copy default enabled-services.conf
    # Create hosts/ subfolders
  }

  # Initialize user's .uis.secrets/ folder
  init_uis_secrets() {
    local user_dir="$1"
    # Create folder structure only (no templates copied yet)
    # Templates copied on-demand when user runs 'uis host add'
  }

  # Check if first run
  is_first_run() {
    # Returns true if .uis.extend/ doesn't exist
  }

  # Generate SSH keys (called when needed)
  generate_ssh_keys() {
    local secrets_dir="$1"
    # Generate id_rsa_ansible and id_rsa_ansible.pub
  }
  ```

- [x] 6.2 Create welcome message content in `provision-host/uis/templates/welcome.txt` ✓

- [ ] 6.3 Add unit tests for init functions (deferred to PLAN-002)

### Validation

Init script correctly creates folder structure when tested.

---

## Phase 7: Update UIS Wrapper — ✅ DONE

Update the `uis` wrapper script to handle first-run and new mounts.

### Tasks

- [x] 7.1 Update `uis` wrapper to detect first-run:
  - Creates `.uis.extend/` and `.uis.secrets/` if missing
  - Shows welcome message on first run

- [x] 7.2 Update volume mounts for new structure:
  - Always mounts `.uis.extend/` and `.uis.secrets/`
  - `topsecret/` mounted read-only only if it exists (backwards compatibility)

- [x] 7.3 `topsecret/` no longer required:
  - New users don't need topsecret folder
  - Old users with topsecret still work (mounted read-only)

- [x] 7.4 `.uis.secrets/` automatically added to user's `.gitignore`

### Validation

User confirms `./uis` first-run creates folders and shows welcome message.

---

## Acceptance Criteria

- [x] All templates created in `provision-host/uis/templates/`
- [x] Initialization script handles first-run folder creation
- [x] SSH key generation function added to `first-run.sh`
- [x] `uis` wrapper detects first-run and initializes
- [x] `.uis.secrets/` automatically added to user's `.gitignore`
- [x] Welcome message is helpful and accurate
- [x] Cloud-init templates moved to new location
- [ ] Unit tests pass for init functions (deferred to PLAN-002)

---

## Files to Create

**Templates (in existing structure):**
- `provision-host/uis/templates/uis.secrets/*.env.template`
- `provision-host/uis/templates/uis.secrets/cloud-accounts/*.env.template`
- `provision-host/uis/templates/uis.secrets/service-keys/*.env.template`
- `provision-host/uis/templates/uis.secrets/network/*.env.template`
- `provision-host/uis/templates/uis.extend/hosts/*/*.conf.template`
- `provision-host/uis/templates/ubuntu-cloud-init/*.yml`
- `provision-host/uis/templates/welcome.txt`

**Code:**
- `provision-host/uis/tests/unit/test-uis-init.sh` (deferred to PLAN-002)

**Tests:**
- `provision-host/uis/tests/static/test-templates-structure.sh` (temporary test for development)

**Modified:**
- `uis` (wrapper script)
- `provision-host/uis/lib/first-run.sh` (existing file updated)
