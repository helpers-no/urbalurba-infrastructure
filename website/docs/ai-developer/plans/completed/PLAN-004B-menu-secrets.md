# PLAN-004B: Interactive Menu & Secrets Management

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed

**Goal**: Add interactive TUI menu, init wizard, and secrets management to UIS.

**Last Updated**: 2026-01-22

**Part of**: [PLAN-004-uis-orchestration-system.md](./PLAN-004-uis-orchestration-system.md) (Epic)

**Prerequisites**: [PLAN-004A-core-cli.md](../completed/PLAN-004A-core-cli.md) - Core CLI system ✅ Complete

**Priority**: Medium

**Delivers**:
- `uis setup` - Interactive TUI menu with dialog
- `uis init` - First-time configuration wizard
- `uis secrets init/generate/apply` - Full secrets management
- `uis tools list/install` - Optional tool installation

---

## Overview

This plan enhances the UIS experience with:
1. **Interactive menu** (`uis setup`) for visual service management
2. **Init wizard** (`uis init`) for guided first-time configuration
3. **Secrets management** for customizing deployments beyond defaults
4. **Tool installation** for optional CLIs (azure-cli, aws-cli, etc.)

**Philosophy**: These are all OPTIONAL - the system works without them (zero-config start).

---

## Phase 5: Interactive Menu — MOSTLY COMPLETE

Create dialog-based menu like DCT's dev-setup.

**Status**: Tasks 5.1-5.5, 5.7 complete. Task 5.6 deferred to Phase 6.1.

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

- [x] 5.1 Implement `uis setup` command ✅
  - Uses `dialog` for TUI menu
  - Main menu with: Services, Tools, Config, Secrets, Status
  - Pattern: Based on DCT dev-setup.sh
  - Graceful fallback if `dialog` not installed

- [x] 5.2 Create service selection menu ✅
  - Lists services by category (Core, Monitoring, AI, Databases, etc.)
  - Shows status: ✅ deployed, ❌ not deployed, ⏸️ enabled but not deployed
  - Toggle enable/disable updates enabled-services.conf
  - Option to deploy immediately or just save config

  ```
  ┌─────────────────────────────────────────┐
  │       Services: Monitoring              │
  ├─────────────────────────────────────────┤
  │  [✅] prometheus    Metrics collection  │
  │  [❌] grafana       Dashboards          │
  │  [❌] loki          Log aggregation     │
  │  [❌] tempo         Distributed tracing │
  ├─────────────────────────────────────────┤
  │  [Deploy Selected]  [Back]  [Cancel]    │
  └─────────────────────────────────────────┘
  ```

- [x] 5.3 Create tool installation menu (DCT-style) ✅
  - **File**: `provision-host/uis/lib/tool-installation.sh`
  - Lists optional tools with install status
  - Shows: ✅ installed, ❌ not installed
  - Selecting a tool runs its install script
  - Updates `enabled-tools.conf` after successful install

  ```
  ┌─────────────────────────────────────────┐
  │       Install Optional Tools            │
  ├─────────────────────────────────────────┤
  │  [❌] Azure CLI      Cloud management   │
  │  [❌] AWS CLI        Cloud management   │
  │  [❌] GCP CLI        Cloud management   │
  │  [✅] kubectl        Always installed   │
  │  [✅] k9s            Always installed   │
  └─────────────────────────────────────────┘
  ```

- [x] 5.4 Create tool install scripts with metadata ✅
  - **Files**: `provision-host/uis/tools/install-*.sh`
  - Pattern: Same metadata format as service scripts
  - Created: install-azure-cli.sh, install-aws-cli.sh, install-gcp-cli.sh

- [x] 5.5 Implement CLI tool commands ✅
  ```bash
  uis tools list              # List all tools with status
  uis tools install <tool>    # Install specific tool
  ```

- [ ] 5.6 Create cluster configuration menu (deferred to Phase 6.1)
  - Shows current cluster-config.sh values
  - Allows editing key settings
  - Writes back to `.uis.extend/cluster-config.sh`

- [x] 5.7 Create system status screen ✅
  - Shows: Cluster connection, deployed services, resource usage
  - Quick health overview via `uis setup` → "System Status"

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

## Phase 6: Init Wizard & Secrets Management — COMPLETE

Create configuration wizard and secrets commands.

**Status**: All Phase 6 tasks complete.

### Tasks

- [x] 6.1 Implement `uis init` command ✅
  - Interactive wizard for customizing configuration
  - Updates `.uis.extend/cluster-config.sh` with user choices
  - Prompts for:
    - Project name
    - Cluster type (shows available options from hosts/)
    - Base domain
  - Optional: Admin email/password for Authentik

  ```bash
  ./uis init
  #
  # Welcome to UIS Setup!
  #
  # Project name [uis]: myproject
  #
  # Select cluster type:
  #   1. rancher-desktop (Local laptop - default)
  #   2. azure-aks (Azure Kubernetes Service)
  #   3. azure-microk8s (MicroK8s on Azure VM)
  #   4. multipass-microk8s (MicroK8s on local VM)
  # Choice [1]: 1
  #
  # Base domain [localhost]: localhost
  #
  # ✓ Configuration saved to .uis.extend/cluster-config.sh
  ```

- [x] 6.2 Implement `uis cluster types` command ✅
  - Lists available cluster types from hosts/ folder
  - Shows description and requirements for each

- [x] 6.3 Create `uis secrets` subcommands ✅
  - **File**: `provision-host/uis/lib/secrets-management.sh`
  - **Based on**: Existing [Secrets Management System](../../../contributors/architecture/secrets.md)

  **Commands:**
  ```bash
  uis secrets init      # Create .uis.secrets/ structure and copy templates
  uis secrets edit      # Open 00-common-values.env.template in editor
  uis secrets generate  # Generate kubernetes-secrets.yml from templates
  uis secrets apply     # Apply generated secrets to Kubernetes cluster
  uis secrets status    # Show which secrets are configured vs missing
  uis secrets validate  # Check templates for required variables
  ```

- [x] 6.4 Implement `uis secrets init` ✅
  - Creates `.uis.secrets/secrets-config/` structure
  - Copies `00-common-values.env.template` with working defaults
  - User can then edit to customize

  ```bash
  ./uis secrets init
  # ✓ Created .uis.secrets/secrets-config/
  # ✓ Created .uis.secrets/kubernetes/
  # ✓ Copied defaults to 00-common-values.env.template
  #
  # Edit .uis.secrets/secrets-config/00-common-values.env.template to customize
  # Then run: uis secrets generate && uis secrets apply
  ```

- [x] 6.5 Implement `uis secrets status` ✅
  - Shows which variables are configured vs using defaults
  - Indicates which are required for external access

  ```bash
  ./uis secrets status
  #
  # Secrets Source: Built-in defaults (no .uis.secrets/ found)
  #
  # Core (have working defaults):
  # ✅ DEFAULT_ADMIN_EMAIL: admin@localhost
  # ✅ DEFAULT_ADMIN_PASSWORD: LocalDev123!
  # ✅ DEFAULT_DATABASE_PASSWORD: LocalDevDB456!
  #
  # External Services (configure when needed):
  # ⚪ TAILSCALE_SECRET: not set (for Tailscale access)
  # ⚪ CLOUDFLARE_DNS_TOKEN: not set (for Cloudflare access)
  # ⚪ OPENAI_API_KEY: not set (for OpenAI models)
  ```

- [x] 6.6 Implement `uis secrets generate` ✅
  - Reads `.uis.secrets/secrets-config/00-common-values.env.template`
  - Sources templates from container: `/mnt/urbalurbadisk/topsecret/secrets-templates/`
  - Generates `.uis.secrets/kubernetes/kubernetes-secrets.yml`
  - Uses `envsubst` for variable substitution

- [x] 6.7 Implement `uis secrets apply` ✅
  - Runs `kubectl apply -f .uis.secrets/kubernetes/kubernetes-secrets.yml`
  - Shows created/updated resources

- [x] 6.8 Implement `uis secrets validate` ✅
  - Checks that required variables are set
  - Warns about empty optional variables

- [ ] 6.9 Handle migration from existing `topsecret/` (deferred)
  - If user has existing `topsecret/secrets-config/`, offer to migrate
  - Copy `00-common-values.env.template` → `.uis.secrets/secrets-config/`
  - Copy any custom configmaps

### Key Variables

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

### Validation

```bash
./uis cluster types
# Output:
# rancher-desktop    Local laptop (default)
# azure-aks          Azure Kubernetes Service
# azure-microk8s     MicroK8s on Azure VM
# multipass-microk8s MicroK8s on local VM
# raspberry-microk8s MicroK8s on Raspberry Pi

./uis init
# Wizard walks through configuration

./uis secrets init
# Creates .uis.secrets/ structure with working defaults

./uis secrets status
# Shows configured vs missing secrets

./uis secrets generate
# ✓ Generated .uis.secrets/kubernetes/kubernetes-secrets.yml (520 lines)

./uis secrets apply
# ✓ namespace/ai created
# ✓ secret/urbalurba-secrets created
```

---

## Acceptance Criteria

- [ ] `./uis setup` shows interactive menu (services, tools, config)
- [ ] `./uis setup` → "Browse Services" shows categorized service list
- [ ] `./uis setup` → "Install Optional Tools" shows available CLIs
- [ ] `./uis tools list` shows all tools with install status
- [ ] `./uis tools install azure-cli` installs Azure CLI in container
- [ ] `./uis init` walks through configuration wizard
- [ ] `./uis cluster types` lists available cluster types
- [ ] `./uis secrets init` creates `.uis.secrets/` structure with templates
- [ ] `./uis secrets status` shows configured vs missing secrets
- [ ] `./uis secrets validate` checks required variables are set
- [ ] `./uis secrets generate` generates Kubernetes secrets from templates
- [ ] `./uis secrets apply` applies secrets to Kubernetes cluster
- [ ] Migration from `topsecret/` works if user has existing config

---

## Files to Create

| File | Description |
|------|-------------|
| **Libraries** | |
| `provision-host/uis/lib/tool-installation.sh` | Tool install logic |
| `provision-host/uis/lib/secrets-management.sh` | Secrets init/generate/apply |
| `provision-host/uis/lib/menu-helpers.sh` | Dialog menu utilities |
| **Tool Scripts** | |
| `provision-host/uis/tools/install-azure-cli.sh` | Azure CLI installer |
| `provision-host/uis/tools/install-aws-cli.sh` | AWS CLI installer |
| `provision-host/uis/tools/install-gcp-cli.sh` | Google Cloud CLI installer |

## Files to Modify

| File | Change |
|------|--------|
| `provision-host/uis/manage/uis-cli.sh` | Add setup, init, secrets, tools commands |

---

## Gaps Identified

1. **Editor selection** - `uis secrets edit` should respect `$EDITOR` environment variable

2. **Secrets backup** - Should `uis secrets generate` backup existing secrets first?

3. **Partial secrets** - What if user only wants to customize some variables, not all?

4. **Menu without dialog** - Need fallback if `dialog` is not installed (text-based menu)

5. **Tool removal** - Some tools (like azure-cli) can be removed, others can't. Need to handle gracefully.

6. **Secrets diff** - `uis secrets diff` to show what would change before applying

7. **Secrets encryption** - Should `.uis.secrets/` be encrypted at rest? (Future consideration)

---

## Next Plan

After completing this plan, proceed to:
- [PLAN-004C-distribution.md](./PLAN-004C-distribution.md) - Install script and Windows support
