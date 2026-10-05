# platforms/aks

OpenTofu-based provisioning for Azure Kubernetes Service (AKS).

This is the **platform layer** — it creates everything needed before services
(PostgreSQL, Redis, etc.) are deployed via UIS. It replaces the old `hosts-to-be-deleted/azure-aks/` scripts (renamed from `hosts/` 2026-10-05, pending deletion).

## What this provisions (Step 1)

- Azure Resource Group
- AKS cluster with:
  - System-assigned managed identity
  - Azure CNI + Azure network policy
  - Cluster autoscaler (min/max nodes)
  - Log Analytics monitoring addon
- Storage class aliases (`local-path`, `microk8s-hostpath` → Azure Disk)
- Traefik ingress controller

ACR, Key Vault, Workload Identity, and VNet come in later steps.

## Prerequisites

- Running inside the `provision-host` container
- `azure-cli` installed: `./uis tools install azure-cli`
- `opentofu` installed: `./uis tools install opentofu`
- `helm` installed in the container (built-in)
- Azure CLI logged in: `az login --use-device-code` (no `--tenant` flag — see manual-setup runbook)

## First-time setup

```bash
# 1. Copy the template and fill in your values
cp provision-host/uis/templates/uis.secrets/cloud-accounts/azure.env.template \
   .uis.secrets/cloud-accounts/azure-default.env
# Edit .uis.secrets/cloud-accounts/azure-default.env — fill in
# AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID, AZURE_STATE_STORAGE_ACCOUNT.
# All AZURE_AKS_* cluster-shape values are optional (defaults applied if commented).

# 2. Bootstrap the state storage (one-time, survives cluster destroy/recreate)
./platforms/azure-aks/scripts/00-bootstrap-state.sh

# 3. Create the cluster
./platforms/azure-aks/scripts/01-apply.sh

# 4. Configure the cluster (storage classes, Traefik)
./platforms/azure-aks/scripts/02-post-apply.sh
```

For a step-by-step walkthrough including how to discover your Azure values, see
[PLAN-platform-aks-001b-manual-setup.md](../../website/docs/ai-developer/plans/backlog/PLAN-platform-aks-001b-manual-setup.md).

## Daily operations

```bash
# Switch kubectl context to AKS
kubectl config use-context azure-aks

# Deploy services
./uis deploy <service>
./uis stack install <stack>

# Tear down cluster (saves ~$5/day)
./platforms/azure-aks/scripts/03-destroy.sh

# Recreate from state
./platforms/azure-aks/scripts/01-apply.sh
```

## File structure

```
platforms/azure-aks/
├── README.md
├── tofu/
│   ├── backend.tf                 # Remote state in Azure Blob Storage
│   ├── main.tf                    # Resource group + AKS cluster
│   ├── variables.tf
│   ├── outputs.tf
│   └── terraform.tfvars.example   # Documents what 01-apply.sh generates
├── manifests/
│   └── 000-storage-class-azure-alias.yaml
└── scripts/
    ├── 00-bootstrap-state.sh      # One-time: create state storage account
    ├── 01-apply.sh                # tofu init → plan → apply → write kubeconfig
    ├── 02-post-apply.sh           # Storage classes + Traefik
    └── 03-destroy.sh              # tofu destroy + kubeconfig cleanup
```

Configuration lives outside `platforms/azure-aks/` (per the secrets architecture):

- **Template**: `provision-host/uis/templates/uis.secrets/cloud-accounts/azure.env.template` (committed)
- **Your values**: `.uis.secrets/cloud-accounts/azure-default.env` (gitignored)

## State backend

OpenTofu state is stored in Azure Blob Storage (default: `rg-urbalurba-tfstate`,
overridable via `AZURE_AKS_STATE_RESOURCE_GROUP`). This resource group is **not**
managed by OpenTofu and survives cluster destroy/recreate. Blob versioning is
enabled — previous state versions are recoverable.

## .gitignore

`.uis.secrets/` is already covered by the top-level `.gitignore`. AKS-specific
generated files inside `platforms/azure-aks/tofu/` to keep ignored:

```
platforms/azure-aks/tofu/terraform.tfvars
platforms/azure-aks/tofu/tfplan
platforms/azure-aks/tofu/.terraform/
```
