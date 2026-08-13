# INVESTIGATE: Secrets Management Consolidation

**Status:** Investigation Complete — PLAN-004 ready for implementation
**Created:** 2025-01-23
**Updated:** 2026-02-19 — Added cleanup readiness audit
**Related to:** [PLAN-004-uis-orchestration-system](../completed/PLAN-004-uis-orchestration-system.md)

> The investigation is complete with all design decisions made. The proposed
> `.uis.extend/` and `.uis.secrets/` folder structure has been implemented as part
> of the UIS orchestration system. The cleanup audit (2026-02-19) confirmed all
> prerequisites are met — backwards compatibility code can now be safely removed.
> See [PLAN-004-secrets-cleanup](../completed/PLAN-004-secrets-cleanup.md) for the implementation plan.

## Problem Statement

Secrets are currently scattered across multiple folders with inconsistent naming and unclear responsibilities. This makes it confusing for users and complicates container mounting.

## Related Documentation

- [Cloud-Init Documentation](../../../platforms/cloud-init/index.md) - Main cloud-init overview
- [SSH Key Setup Guide](../../../platforms/cloud-init/secrets.md) - SSH key generation for Ansible
- [Hosts Overview](../../../platforms/index.md) - All supported host types

## Current State Analysis

### Folder Structure
```
urbalurba-infrastructure/
├── .uis.extend/                        # User config (committed to user's repo)
│   └── enabled-services.conf           # Which services to deploy
│
├── topsecret/                          # Main secrets folder (gitignored)
│   ├── secrets-templates/              # Base templates with ${VARIABLES}
│   ├── secrets-config/                 # User-edited values (copied from templates)
│   ├── secrets-generated/              # Temp processing
│   ├── kubernetes/                     # Generated K8s secrets YAML
│   ├── config/                         # User config (enabled-services.conf)
│   ├── create-kubernetes-secrets.sh    # Secret generation script
│   ├── copy-secrets2host.sh            # Copy to provision-host
│   └── kubeconf-copy2local.sh          # Kubeconfig management
│
├── secrets/                            # SSH keys for Ansible (gitignored)
│   ├── id_rsa_ansible
│   ├── id_rsa_ansible.pub
│   └── create-secrets.sh
│
├── cloud-init/                         # Cloud-init configuration
│   ├── *-cloud-init-template.yml       # Templates (tracked in git)
│   ├── *-cloud-init.yml                # Generated files (gitignored)
│   └── create-cloud-init.sh            # Reads from topsecret & secrets
│
├── .uis.secrets/                       # NEW - empty, created by uis wrapper
│
└── hosts/                              # Host-specific scripts
    ├── azure-aks/
    │   ├── *.sh                        # Setup/cleanup scripts
    │   └── azure-aks-config.sh         # Azure config (gitignored)
    ├── azure-microk8s/
    │   ├── *.sh                        # Setup/cleanup scripts
    │   └── azure-vm-config-*.sh        # Azure VM config (gitignored)
    ├── multipass-microk8s/             # Scripts only (no config files)
    ├── rancher-kubernetes/             # Scripts only (no config files)
    └── raspberry-microk8s/             # Scripts only (no config files)
```

### Host Config Files (Scattered)

Config files in `hosts/` contain sensitive Azure configuration:

**hosts/azure-aks/azure-aks-config.sh:** (gitignored)
- `TENANT_ID` - Azure tenant
- `SUBSCRIPTION_ID` - Azure subscription
- Resource group, cluster name, tags with email addresses

**hosts/azure-microk8s/azure-vm-config-redcross-sandbox.sh:** (gitignored)
- Same Azure IDs
- VM sizes, network config, disk settings
- Organization-specific naming conventions

**Other host types** (multipass, rancher, raspberry) currently have no separate config files - settings are hardcoded in scripts or use cloud-init.

### Cloud-Init Dependencies

The `cloud-init/create-cloud-init.sh` script reads from:
- `../topsecret/kubernetes/kubernetes-secrets.yml` - for secrets (tailscale, wifi, passwords)
- `../secrets/id_rsa_ansible.pub` - for SSH public key

**Placeholders in templates:**
- `URB_SSH_AUTHORIZED_KEY_VARIABLE` - SSH public key
- `URB_TAILSCALE_SECRET_VARIABLE` - Tailscale auth key
- `URB_WIFI_SSID_VARIABLE` - WiFi network name
- `URB_WIFI_PASSWORD_VARIABLE` - WiFi password
- `URB_TEC_PASSWORD_VARIABLE` - VM user password
- `URB_TEC_USER_VARIABLE` - VM username

### Dependency Chain

The folders have a specific order of operations:

```
1. secrets/create-secrets.sh
   └── Creates: id_rsa_ansible, id_rsa_ansible.pub
       │
       ▼
2. cloud-init/create-cloud-init.sh
   └── Reads: secrets/id_rsa_ansible.pub (SSH public key)
   └── Reads: topsecret/kubernetes/kubernetes-secrets.yml (Tailscale key, etc.)
   └── Creates: *-cloud-init.yml (with SSH key + Tailscale key embedded)
       │
       ▼
3. VM Creation (Azure MicroK8s, GCP, AWS, Raspberry Pi)
   └── Uses: cloud-init.yml to bootstrap VM
   └── Injects: SSH public key for ansible user
   └── Installs: Tailscale and auto-joins network
       │
       ▼
4. VM is now reachable via Tailscale network
   └── Cloud VMs have no public IP - Tailscale provides connectivity
   └── Raspberry Pi on home network - also uses Tailscale
       │
       ▼
5. Ansible Provisioning (via Tailscale)
   └── Uses: secrets/id_rsa_ansible (private key)
   └── Connects: to VM via Tailscale IP as ansible user
```

**Key insight:** For cloud VMs (Azure/GCP/AWS), Tailscale is required for network connectivity. The VM has no public IP - cloud-init sets up Tailscale so the VM auto-joins the network, then UIS can SSH to it.

**Note:** Managed services (Rancher Desktop, Azure AKS) do NOT use cloud-init - they have their own provisioning mechanisms.

### Identified Problems

1. **Multiple locations**: Secrets split across `topsecret/`, `secrets/`, `cloud-init/`, and `hosts/`
2. **Confusing naming**: `topsecret/` contains both secrets AND config
3. **Scripts mixed with data**: Generation scripts in same folder as secrets
4. **Container mount complexity**: Multiple folders need mounting
5. **Cloud-init generated files**: Mixed with templates in same folder
6. **Cross-folder dependencies**: `cloud-init/create-cloud-init.sh` reads from both `topsecret/` and `secrets/`
7. **Host configs scattered**: Azure config files in `hosts/azure-*/` instead of central location
8. **No single source of truth**: User must edit multiple files in different locations

---

## Proposed Structure

Two folders with clear purposes:

### `.uis.extend/` - Committed to user's repo

Non-sensitive configuration that users want to track in version control:

```
.uis.extend/
├── enabled-services.conf               # Which services to deploy (already exists)
├── hosts/                              # Kubernetes cluster configurations
│   ├── README.md                       # Explains the host types
│   │
│   ├── managed/                        # Managed K8s services (provider handles infrastructure)
│   │   ├── personal-azure-aks.conf     # My personal AKS cluster
│   │   ├── company-azure-aks.conf      # Company AKS cluster
│   │   ├── client-gcp-gke.conf         # Client's GKE cluster
│   │   └── ...
│   │
│   ├── cloud-vm/                       # VMs in cloud running K8s
│   │   ├── dev-azure-microk8s.conf     # Dev cluster on Azure
│   │   ├── prod-azure-talos.conf       # Prod cluster with Talos
│   │   ├── test-gcp-microk8s.conf      # Test cluster on GCP
│   │   └── ...
│   │
│   ├── physical/                       # Physical devices running K8s
│   │   ├── home-raspberry-pi.conf      # Home Raspberry Pi
│   │   ├── office-bare-metal.conf      # Office server
│   │   └── ...
│   │
│   └── local/                          # Local development K8s
│       └── my-rancher-desktop.conf     # Local dev environment
│
└── services/                           # Per-service customization
    └── overrides/                      # Custom values per service
        └── grafana.conf                # Example: dashboard config
```

**Host Types Explained:**

| Type | Creates VM? | Bootstrap Method | Examples |
|------|-------------|------------------|----------|
| **managed/** | No (provider does) | Provider API | AKS, GKE, EKS |
| **cloud-vm/** | Yes | cloud-init or Talos config | Azure/GCP/AWS + MicroK8s/Talos |
| **physical/** | No (existing HW) | cloud-init or Talos config | Raspberry Pi, bare metal |
| **local/** | No | Desktop app | Rancher Desktop, Docker Desktop |

**Naming convention:** `<name>-<cloud-provider>-<k8s-distro>.conf`
- Name: user-chosen identifier (`personal`, `company`, `dev`, `prod`, `home`, etc.)
- Cloud providers: `azure`, `gcp`, `aws`, `raspberry`, `bare-metal`, `rancher`, `docker`
- K8s distros: `aks`, `gke`, `eks`, `microk8s`, `talos`, `k3s`, `desktop`

**Example host config** (`.uis.extend/hosts/managed/company-azure-aks.conf`):
```bash
# Which credentials to use (references file in .uis.secrets/cloud-accounts/)
CREDENTIALS="azure-company"

# Non-sensitive settings (safe to commit)
RESOURCE_GROUP="rg-urbalurba-aks-weu"
CLUSTER_NAME="prod-aks"
LOCATION="westeurope"
NODE_COUNT=3
NODE_SIZE="Standard_B2ms"
```

**Example credentials file** (`.uis.secrets/cloud-accounts/azure-company.env`):
```bash
# Sensitive values - NEVER commit this file
AZURE_TENANT_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
AZURE_SUBSCRIPTION_ID="yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy"
```

**How it works:**
```
.uis.extend/hosts/managed/azure-aks.conf     (committed, safe)
    │
    │  CREDENTIALS="azure-company"
    │
    └──► .uis.secrets/cloud-accounts/azure-company.env  (gitignored, secrets)
```

- Host config in `.uis.extend/` references credentials by name
- Credential file in `.uis.secrets/` contains only the sensitive values
- Same credentials can be reused across multiple clusters

### `.uis.secrets/` - Gitignored (never committed)

Sensitive credentials and generated files:

```
.uis.secrets/
├── ssh/                                # SSH keys for remote access
│   ├── id_rsa_ansible                  # Private key - used by UIS container to connect to VMs
│   └── id_rsa_ansible.pub              # Public key - injected into VMs via cloud-init
│   #
│   # The UIS container runs as user "ansible". This key pair allows the
│   # container to SSH into remote machines (bare metal/VMs) that were
│   # provisioned with the public key via cloud-init.
│   #
│   # For cloud VMs (Azure/GCP/AWS): Tailscale provides network connectivity.
│   # cloud-init sets up Tailscale so the VM auto-joins the network,
│   # then UIS can SSH to it via Tailscale IP.
│
├── cloud-accounts/                     # Cloud provider authentication (one file per account)
│   ├── azure-personal.env              # Personal Azure subscription
│   ├── azure-company.env               # Company Azure subscription
│   ├── gcp-personal.env                # Personal GCP project
│   ├── gcp-work.env                    # Work GCP project
│   └── aws-myaccount.env               # AWS account
│
├── service-keys/                       # External service API keys
│   ├── openai.env                      # OpenAI API key
│   ├── cloudflare.env                  # Cloudflare API token
│   └── tailscale.env                   # Tailscale auth key
│
├── network/                            # Network access credentials
│   └── wifi.env                        # WiFi SSID and password (for Raspberry Pi)
│
├── defaults.env                        # Common default values (VM username, password)
│
└── generated/                          # Output files (auto-generated, never edit)
    ├── kubernetes/                     # K8s secrets YAML
    │   └── kubernetes-secrets.yml
    ├── ubuntu-cloud-init/              # Generated cloud-init for Ubuntu VMs
    │   ├── azure-microk8s-cloud-init.yml
    │   ├── gcp-microk8s-cloud-init.yml
    │   ├── raspberry-microk8s-cloud-init.yml
    │   └── ...
    ├── talos/                          # Generated Talos configs
    │   ├── azure-talos-controlplane.yaml
    │   ├── azure-talos-worker.yaml
    │   └── ...
    └── kubeconfig/                     # Cluster access configs
        ├── rancher-desktop-kubeconf    # Individual cluster configs
        ├── my-azure-aks-kubeconf
        ├── ...
        └── kubeconf-all                # Merged config (auto-generated)
```

### User Workflow

See detailed user journeys in Gap 4 below. Summary:

1. **Get uis:** `curl -O https://uis.sovereignsky.no/uis && chmod +x uis`
2. **First run:** `./uis` - pulls container, creates folders, shows welcome
3. **Add host:** `./uis host add <template>` - copies defaults, tells user what to edit
4. **Edit config:** User edits files in `.uis.extend/` and `.uis.secrets/`
5. **Create/Generate:** `./uis host create` or `./uis host generate`
6. **Deploy:** `./uis deploy [host]`

### Key Principles

1. **Committed vs gitignored** - Clear split between `.uis.extend/` and `.uis.secrets/`
2. **Never edit generated/** - Only edit source files
3. **Sensitive data isolated** - All secrets in `.uis.secrets/`
4. **User config portable** - `.uis.extend/` can be shared/versioned
5. **Only create what's needed** - SSH keys, WiFi config, etc. created only when host requires them

---

## Design Decisions

### Q1: How to handle backwards compatibility?

**Decision:** Support both paths during transition period.

**Migration approach:**
1. Implement new `.uis.secrets/` structure
2. Keep `topsecret/` working in parallel
3. Test and validate new system works
4. Only after confirmation: remove `topsecret/` support

This allows gradual migration without breaking existing setups.

### Q2: What about the `uis` wrapper mounts?

**Current mounts in `uis` wrapper:**
```bash
-v "$SCRIPT_DIR/topsecret:/mnt/urbalurbadisk/topsecret"
-v "$SCRIPT_DIR/.uis.extend:/mnt/urbalurbadisk/.uis.extend"
-v "$SCRIPT_DIR/.uis.secrets:/mnt/urbalurbadisk/.uis.secrets"
-v "$KUBECONFIG_DIR:/home/ansible/.kube:ro"
```

**Note:** The `secrets/` folder (SSH keys) is NOT currently mounted!

**After consolidation:**
```bash
-v "$SCRIPT_DIR/.uis.extend:/mnt/urbalurbadisk/.uis.extend"
-v "$SCRIPT_DIR/.uis.secrets:/mnt/urbalurbadisk/.uis.secrets"
```

- Remove `topsecret` mount (no longer needed)
- Remove separate kubeconfig mount (now in `.uis.secrets/generated/kubeconfig/`)
- `.uis.secrets/ssh/` provides SSH keys
- Scripts inside container need path updates

### Q3: Generation scripts - where do they live?

**Decision:** Move to `provision-host/uis/manage/uis-secrets.sh`

Scripts live in the codebase, not mixed with user data.

### Q4: Templates - in repo or container?

**Decision:** Bake templates into container image.

- Templates are part of the container (in `provision-host/uis/templates/`)
- User only sees their config files in `.uis.extend/` and `.uis.secrets/`
- Keeps host filesystem clean - no extra template files
- `./uis` on first run creates folder structure
- `./uis host add <template>` copies needed templates from container

---

## Implementation Details

### Gap 1: SSH key generation ✅

**Decision:** Create SSH keys automatically when needed.

- `./uis` on first run creates folder structure but NOT SSH keys
- SSH keys only needed for `physical/` and `cloud-vm/` hosts
- NOT needed for `managed/` (AKS, GKE, EKS) or `local/` (Rancher Desktop)
- `./uis host add <template>` auto-generates SSH keys if template needs them and they don't exist

**Principle:** Don't create stuff the user doesn't need, but auto-create when they do.

### Gap 2: cloud-init templates location ✅

**Decision:** Move into container.

- Templates move to `provision-host/uis/templates/ubuntu-cloud-init/`
- Baked into container image (same as other templates)
- Generated output goes to `.uis.secrets/generated/ubuntu-cloud-init/`
- `cloud-init/` folder in repo can be removed after migration

### Gap 3: What goes in `common.env`? ✅

**Decision:** Reorganize for clarity:

```
.uis.secrets/
├── ssh/                        # SSH keys for VM access
├── cloud-accounts/             # Cloud provider authentication (Azure, GCP, AWS)
├── service-keys/               # External service API keys (OpenAI, Tailscale, Cloudflare)
├── network/                    # Network access (WiFi)
└── defaults.env                # Common default values (VM username, password)
```

Clear categories:
- **cloud-accounts/** = Login to cloud providers
- **service-keys/** = API keys for services we use
- **network/** = Network access credentials
- **defaults.env** = Shared default values

### Gap 4: CLI commands detail ✅

**Decision:** Define commands based on user journeys.

---

#### User Journey: Scenario 1 - Local Development (Rancher Desktop)

```
Step 1: User gets the uis command
$ curl -O https://uis.sovereignsky.no/uis && chmod +x uis

Step 2: User runs ./uis for first time
$ ./uis
- Pulls the UIS container image
- Creates .uis.extend/ folder
- Creates .uis.secrets/ folder
- Copies default config from container to .uis.extend/enabled-services.conf
- Shows welcome/help message
- Tells user: "You can deploy. Defaults are in .uis.extend/*.conf"

Step 3: User deploys to local Rancher Desktop
$ ./uis deploy
- Checks if Rancher Desktop is running (fail with helpful message if not)
- Reads .uis.extend/enabled-services.conf
- Deploys enabled services to local cluster
- No secrets needed for basic local deployment
```

**Key points for Scenario 1:**
- Zero configuration needed for basic local dev
- Defaults come from container, copied to `.uis.extend/`
- Just: get uis → run → deploy

**Welcome message should tell user:**
- "Deploying with default settings from .uis.extend/"
- "To customize service settings, edit .uis.secrets/defaults.env"
- Example: database passwords, admin credentials, etc.

---

#### User Journey: Scenario 2 - Adding Azure AKS (managed K8s)

```
Step 1: User wants to add a managed AKS cluster
$ ./uis host add
- Lists available templates:
  managed/azure-aks, managed/gcp-gke, managed/aws-eks,
  cloud-vm/azure-microk8s, physical/raspberry-pi, ...

Step 2: User adds the template
$ ./uis host add azure-aks

Output:
  Created: .uis.extend/hosts/managed/my-azure-aks.conf
  Created: .uis.secrets/cloud-accounts/azure-default.env (if not exists)

  Next steps:
  1. Edit .uis.secrets/cloud-accounts/azure-default.env with your Azure credentials
  2. Edit .uis.extend/hosts/managed/my-azure-aks.conf with your settings
  3. Run: ./uis host create my-azure-aks

Step 3: User edits files manually
- .uis.secrets/cloud-accounts/azure-default.env → add tenant ID, subscription ID
- .uis.extend/hosts/managed/my-azure-aks.conf → change resource group, cluster name, etc.

Step 4: Create the cluster
$ ./uis host create my-azure-aks
- Validates credentials exist and are valid
- Creates AKS cluster in Azure
- Fetches kubeconfig
- Adds to available contexts

Step 5: Deploy services
$ ./uis deploy my-azure-aks
```

**Key points for Scenario 2:**
- `./uis host add` lists templates
- `./uis host add <template>` copies default files, tells user what to edit
- No interactive prompts - user edits files manually
- `./uis host create <name>` provisions the cluster

---

#### User Journey: Scenario 3 - Azure VM with MicroK8s (needs SSH + Tailscale)

```
Step 1: User adds the template
$ ./uis host add azure-microk8s

Output:
  Created: .uis.extend/hosts/cloud-vm/my-azure-microk8s.conf
  Created: .uis.secrets/cloud-accounts/azure-default.env (if not exists)
  Created: .uis.secrets/service-keys/tailscale.env (if not exists)
  Created: .uis.secrets/ssh/id_rsa_ansible (AUTO-GENERATED - keys didn't exist)
  Created: .uis.secrets/ssh/id_rsa_ansible.pub

  Next steps:
  1. Edit .uis.secrets/cloud-accounts/azure-default.env with your Azure credentials
  2. Edit .uis.secrets/service-keys/tailscale.env with your Tailscale auth key
  3. Edit .uis.extend/hosts/cloud-vm/my-azure-microk8s.conf with your settings
  4. Run: ./uis host create my-azure-microk8s

Step 2: User edits files manually
- .uis.secrets/cloud-accounts/azure-default.env → Azure tenant/subscription
- .uis.secrets/service-keys/tailscale.env → Tailscale auth key
- .uis.extend/hosts/cloud-vm/my-azure-microk8s.conf → VM size, resource group, etc.

Step 3: Create the VM
$ ./uis host create my-azure-microk8s
- Validates credentials
- Generates cloud-init.yml (with SSH key + Tailscale key embedded)
- Creates VM in Azure with cloud-init
- VM boots, joins Tailscale network
- UIS can now SSH to VM via Tailscale

Step 4: Deploy services
$ ./uis deploy my-azure-microk8s
```

**Key points for Scenario 3:**
- SSH keys auto-generated if they don't exist
- Tailscale key needed for network access
- cloud-init generated automatically during `host create`
- Same pattern: copy defaults → tell user what to edit → create

---

#### User Journey: Scenario 4 - Raspberry Pi

```
Step 1: User adds the template
$ ./uis host add raspberry-pi

Output:
  Created: .uis.extend/hosts/physical/my-raspberry-pi.conf
  Created: .uis.secrets/service-keys/tailscale.env (if not exists)
  Created: .uis.secrets/network/wifi.env (if not exists)
  Created: .uis.secrets/ssh/id_rsa_ansible (AUTO-GENERATED if not exists)
  Created: .uis.secrets/ssh/id_rsa_ansible.pub

  Next steps:
  1. Edit .uis.secrets/service-keys/tailscale.env with your Tailscale auth key
  2. (Optional) Edit .uis.secrets/network/wifi.env if using WiFi
  3. Edit .uis.extend/hosts/physical/my-raspberry-pi.conf with your settings
  4. Run: ./uis host generate my-raspberry-pi

Step 2: User edits files
- .uis.secrets/service-keys/tailscale.env → Tailscale auth key
- .uis.secrets/network/wifi.env → WiFi SSID/password (optional, skip if using ethernet)
- .uis.extend/hosts/physical/my-raspberry-pi.conf → hostname, etc.

Step 3: Generate cloud-init (no VM to create - it's physical hardware)
$ ./uis host generate my-raspberry-pi

Output:
  Generated: .uis.secrets/generated/ubuntu-cloud-init/my-raspberry-pi-cloud-init.yml

  Next steps:
  1. Flash Raspberry Pi OS to SD card
  2. Copy cloud-init file to SD card boot partition
  3. Boot Raspberry Pi - it will auto-configure and join Tailscale

Step 4: Deploy services (after Pi is online)
$ ./uis deploy my-raspberry-pi
```

**Key points for Scenario 4:**
- SSH keys auto-generated
- WiFi credentials optional (some use ethernet)
- No `host create` - physical hardware already exists
- `host generate` creates cloud-init file for SD card
- User manually flashes SD card and boots device

---

#### Summary: CLI Commands

| Command | Purpose |
|---------|---------|
| `./uis` | Start container, show help/welcome |
| `./uis deploy [host]` | Deploy services (default: local Rancher Desktop) |
| `./uis host add` | List available host templates |
| `./uis host add <template>` | Copy template, auto-create SSH keys if needed, tell user what to edit |
| `./uis host create <name>` | Create cloud resources (VM, managed K8s) |
| `./uis host generate <name>` | Generate cloud-init for physical devices |
| `./uis host list` | List configured hosts |
| `./uis secrets status` | Show what's configured, what's missing |
| `./uis secrets validate` | Validate configuration before deploy |

### Gap 5: Scripts that need updating ✅

**Found 24 scripts referencing `topsecret/` or `secrets/`:**

**cloud-init:**
- `cloud-init/create-cloud-init.sh`

**hosts:**
- `hosts/azure-aks/02-azure-aks-setup.sh`
- `hosts/azure-microk8s/01-azure-vm-create-redcross-v2.sh`
- `hosts/azure-microk8s/02-azure-ansible-inventory-v2.sh`
- `hosts/raspberry-microk8s/install-raspberry.sh`
- `hosts/install-azure-aks.sh`
- `hosts/install-azure-microk8s-v2.sh`
- `hosts/install-multipass-microk8s.sh`
- `hosts/install-rancher-kubernetes.sh`

**topsecret/ (will be removed):**
- `topsecret/update-kubernetes-secrets-rancher.sh`
- `topsecret/kubeconf-copy2local.sh`
- `topsecret/copy-secrets2host.sh`

**networking:**
- `networking/tailscale/802-tailscale-tunnel-deploy.sh`
- `networking/cloudflare/820-cloudflare-tunnel-setup.sh`
- `networking/cloudflare/821-cloudflare-tunnel-deploy.sh`
- `networking/cloudflare/822-cloudflare-tunnel-delete.sh`

**provision-host:**
- `provision-host/provision-host-02-kubetools.sh`
- `provision-host/provision-host-vm-create.sh`
- `provision-host/provision-host-sshconf.sh`
- `provision-host/uis/lib/secrets-management.sh`
- `provision-host/uis/tests/unit/test-phase6-secrets.sh`

**other:**
- `copy2provisionhost.sh`
- `install-rancher.sh`
- `provision-host-rancher/provision-host-container-create.sh`

**Decision:** These will be updated during migration to use new paths. Scripts in `topsecret/` will be replaced by `./uis secrets` commands.

### Gap 6: kubeconfig handling ✅

**Current flow:**
1. Each cluster creates `*-kubeconf` file in `/mnt/urbalurbadisk/kubeconfig/`
2. `ansible/playbooks/04-merge-kubeconf.yml` merges all into `kubeconf-all`
3. Multi-cluster access via merged config

**Current mount:** `$KUBECONFIG_DIR:/home/ansible/.kube`

**Question:** Keep separate or move to `.uis.secrets/`?

**Decision:** Move to `.uis.secrets/generated/kubeconfig/`

```
.uis.secrets/generated/kubeconfig/
├── rancher-desktop-kubeconf    # Individual cluster configs
├── my-azure-aks-kubeconf
├── my-azure-microk8s-kubeconf
└── kubeconf-all                # Merged config (auto-generated)
```

- kubeconfig is generated by cluster creation, not user-edited
- Contains sensitive cluster access credentials
- Merge playbook updated to use new path
- Fits with "generated = auto-created, don't edit" principle

---

## Cleanup Readiness Audit (2026-02-19)

Detailed code audit to determine what backwards compatibility code remains and whether it can be safely removed.

### Prerequisites Verified

All old path references in Ansible playbooks were fixed in PR #35 (merged, verified by tester):

| Playbook | What was fixed |
|----------|---------------|
| `01-configure_provision-host.yml` | SSH key path `ansible/secrets/` → `.uis.secrets/ssh/` |
| `350-setup-jupyterhub.yml` | Hardcoded `topsecret/kubernetes/kubernetes-secrets.yml` → new path |
| `802-deploy-network-tailscale-tunnel.yml` | Error message text updated |
| `ansible/ansible.cfg` | `private_key_file` updated |
| `provision-host/provision-host-vm-create.sh` | SSH key copy destination updated |

### Backwards Compatibility Code Inventory

#### `provision-host/uis/lib/paths.sh` — 7 fallback functions

The file has two sections: core path functions (clean, no legacy) and backwards-compatible functions (lines 166-416). The backwards-compat section contains:

| Item | Lines | Description |
|------|-------|-------------|
| `OLD_SECRETS_BASE` constant | 176 | `/mnt/urbalurbadisk/topsecret` |
| `OLD_SSH_BASE` constant | 177 | `/mnt/urbalurbadisk/secrets` |
| `_DEPRECATION_WARNING_SHOWN` | 180 | Session-scoped warning flag |
| `warn_deprecated_path()` | 188-200 | Shows deprecation warning once per session |
| `get_secrets_base_path()` | 210-219 | Falls back to `OLD_SECRETS_BASE` |
| `get_ssh_key_path()` | 224-247 | Falls back to `OLD_SSH_BASE` and `OLD_SECRETS_BASE/ssh` |
| `get_kubernetes_secrets_path()` | 252-274 | Falls back to `OLD_SECRETS_BASE/kubernetes` |
| `get_cloud_init_output_path()` | 279-301 | Falls back to `/mnt/urbalurbadisk/cloud-init` |
| `get_kubeconfig_path()` | 306-328 | Falls back to `OLD_SECRETS_BASE` |
| `get_tailscale_key_path()` | 333-352 | Falls back to `OLD_SECRETS_BASE/kubernetes/kubernetes-secrets.yml` |
| `get_cloudflare_token_path()` | 357-375 | Falls back to `OLD_SECRETS_BASE/cloudflare` |
| `is_using_legacy_paths()` | 406-408 | Detection function |

**Action:** Simplify all 7 `get_*` functions to one-liners returning only new paths. Remove constants, warning function, and `is_using_legacy_paths()`. Keep `is_using_new_paths()`, `ensure_path_exists()`, `get_cloud_credentials_path()`.

#### `provision-host/uis/lib/secrets-management.sh` — 3 legacy items

| Item | Lines | Description |
|------|-------|-------------|
| Comment | 5 | References `topsecret/` structure |
| `get_secrets_templates_dir()` fallback | 48-51 | Falls back to `topsecret/secrets-templates` |
| `has_topsecret_config()` | 70-80 | Checks if `topsecret/secrets-config` exists |

**Action:** Update comment, remove fallback, remove `has_topsecret_config()`.

#### `uis` (root wrapper) — 4 legacy items

| Item | Lines | Description |
|------|-------|-------------|
| `check_topsecret()` | 32-39 | Function to check if topsecret/ exists |
| topsecret volume mount | 130-133 | Mounts `topsecret/` read-only if present |
| secrets/ volume mount | 136-138 | Mounts `secrets/` read-only if present |
| kubeconfig symlink | 159-174 | Creates legacy `/mnt/urbalurbadisk/kubeconfig` symlink |

**Action:** Remove `check_topsecret()`, both legacy mounts, and the legacy kubeconfig symlink (keep the new `.uis.secrets/generated/kubeconfig` symlink).

#### `Dockerfile.uis-provision-host` — 2 legacy items

| Item | Lines | Description |
|------|-------|-------------|
| COPY secrets-templates | 64 | `COPY topsecret/secrets-templates/ ...` (templates already in `provision-host/uis/templates/`) |
| mkdir topsecret | 85-87 | Creates mount points for topsecret dirs |

**Action:** Remove both. Templates are already in `provision-host/uis/templates/secrets-templates/`.

#### `ansible/playbooks/04-merge-kubeconf.yml` — dual path support

| Item | Lines | Description |
|------|-------|-------------|
| `legacy_kubernetes_files_path` var | 36 | Fallback path `/mnt/urbalurbadisk/kubeconfig/` |
| Dynamic path selection | 38 | Jinja2 conditional choosing new vs legacy |
| `pre_tasks` block | 57-79 | stat check, set_fact, deprecation warning |

**Action:** Remove legacy var, simplify to single new path, remove all pre_tasks.

#### `provision-host/provision-host-vm-create.sh` — 1 legacy item

| Item | Lines | Description |
|------|-------|-------------|
| topsecret rsync | 152-154 | `rsync ../topsecret/ $VM_NAME:/mnt/urbalurbadisk/topsecret/` |

**Action:** Remove the topsecret rsync block (new path rsync on line 150 already handles it).

#### `provision-host/uis/lib/first-run.sh` — 1 comment reference

| Item | Lines | Description |
|------|-------|-------------|
| Comment | 241 | References `topsecret` in workflow description |

**Action:** Update comment to describe the workflow without referencing topsecret.

#### Test files — 1 file to delete, 2 to update

| File | Action | Description |
|------|--------|-------------|
| `test-backwards-compat-paths.sh` | **Delete** | 358-line test suite for backwards compat (~20 tests) |
| `test-paths.sh` | Update | Remove OLD_* constant tests and backwards-compat function tests (lines 151-273) |
| `test-phase6-secrets.sh` | Update | Remove `has_topsecret_config` from function existence check loop (line 43) |

### Git-Tracked Files to Remove

#### `secrets/` folder — 1 tracked file

```
secrets/create-secrets.sh    # Only tracked file (SSH keys are gitignored)
```

#### `topsecret/` folder — 24 tracked files

```
topsecret/DEPRECATED.md
topsecret/copy-secrets2host.sh
topsecret/create-kubernetes-secrets.sh
topsecret/kubeconf-copy2local.sh
topsecret/update-kubernetes-secrets-rancher.sh
topsecret/update-kubernetes-secrets-v2.sh
topsecret/kubernetes/argocd-secret-correct.yml
topsecret/kubernetes/argocd-secret-fix.yml
topsecret/kubernetes/argocd-secret-fixed.yml
topsecret/kubernetes/argocd-urbalurba-secrets.yml
topsecret/secrets-templates/00-common-values.env.template
topsecret/secrets-templates/00-master-secrets.yml.template
topsecret/secrets-templates/configmaps/ai/models/litellm.yaml.template
topsecret/secrets-templates/configmaps/monitoring/configs/test-config.yaml.template
topsecret/secrets-templates/configmaps/monitoring/dashboards/*.json.template (8 files)
```

### `.gitignore` entries to clean up

7 entries referencing `topsecret/` paths (lines 8-11, 20-21, 45) can be removed.

### Deferred Items (NOT part of PLAN-004)

These have active hard dependencies and need separate work:

| Item | Why deferred |
|------|-------------|
| `cloud-init/` folder | Still referenced by `provision-host-vm-create.sh` and host scripts |
| `hosts/` folder configs | Azure scripts actively used, scripts copied to VMs |
| Documentation updates | 17+ user-facing docs reference `topsecret/` — large scope, separate PR |

---

## Next Steps

1. [x] Document current folder structure ✓
2. [x] Analyze cloud-init dependencies ✓
3. [x] Audit hosts/ folder ✓
4. [x] Propose target structure ✓
5. [x] Audit current `uis` wrapper volume mounts ✓
6. [x] List all scripts that reference `topsecret/` or `secrets/` ✓
7. [x] Review proposed structure with user ✓
8. [x] Define user journeys and CLI commands ✓
9. [x] Resolve all gaps ✓
10. [x] Cleanup readiness audit ✓ (2026-02-19)
11. [x] **Implementation PLAN updated and moved to active/** ✓ (2026-02-19)

---

## Notes

- The `.uis.secrets/` prefix with dot keeps it hidden and clearly separate
- Matches the `.uis.extend/` pattern already in use
- Existing `.uis.secrets/` folder is already gitignored
