# Plan: AKS Manual Setup — variable-by-variable runbook for first-run provisioning

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

**Goal**: Provide a self-contained runbook for the first manual run-through of `platforms/azure-aks/` against an Azure subscription. Explains every config variable (what it is, where to find it, what changes if you change it), every authentication step, and every script in the order it must run. Companion to [PLAN-001-aks-step1-verification.md](../completed/PLAN-001-aks-step1-verification.md) — that plan's Phase 2 lists the eight scripts to run; this plan is the detailed *how* and *why* for someone doing it for the first time.

**Last Updated**: 2026-05-08

**Investigation**: [INVESTIGATE-system-platform-provisioning-layer.md](./INVESTIGATE-system-platform-provisioning-layer.md) — Step 1 scope and verification bar.

**Companion**: [PLAN-001-aks-step1-verification.md](../completed/PLAN-001-aks-step1-verification.md) — drives Phase 1 (OpenTofu installer, shipped) and Phase 2 (this manual run-through). When PLAN-001 Phase 2 is in flight, the operator follows this document.

**Note on the "b" suffix**: this is a runbook companion to PLAN-001, not the next ordered PLAN in the sequence. PLAN-002 (secrets-apply parity) is a separate scope. Future ordered plans (PLAN-003+) will continue the numbering.

---

## Problem Summary

PLAN-001's Phase 2 lists the commands to run, but a first-time operator needs more: *what each variable means, where to find its value, what every command actually does, and what the failure modes look like*. Spreading that detail across PLAN-001 would bloat it. Keeping it here lets PLAN-001 stay tight while the operator has a real runbook to lean on.

This plan is intended to be read top-to-bottom by the operator the first time, then referenced by section on subsequent runs.

---

## Phase 1: Prerequisites

What you need before starting. None of these are AKS-specific — they're the platform-of-platforms baseline.

### Local environment

- **Rancher Desktop** running on your laptop (the Docker engine that hosts `uis-provision-host`).
- **The UIS git repo** cloned locally, on a recent `main` (`git pull` first).
- **The provision-host container built and running**: `./uis build` then `./uis start`. Confirm with `docker ps --filter name=uis-provision-host`.

### Azure access

- **An Azure subscription** you have at least Contributor role on. For helpers.no this is the Microsoft nonprofit grant subscription.
- **A Microsoft work/school account** that can sign in to that tenant interactively (device-code flow used; no service principals required for Step 1).
- **PIM activation** if your Contributor role is just-in-time. Activate at <https://portal.azure.com> → Microsoft Entra Privileged Identity Management → My Roles → Activate "Contributor" for the target subscription before running `01-apply.sh`. Activation usually takes 1–2 minutes to propagate.
- **vCPU quota** in the chosen region for the chosen VM size. Default is `Standard_B2ms` (2 vCPUs); 1 node ≈ 2 vCPUs needed, autoscaler max 3 nodes ≈ 6 vCPUs. If your subscription is under quota, `01-apply.sh` will fail mid-`tofu apply` with a clear error — see *Troubleshooting*.

### Validation

Inside the container (`./uis shell`), running `kubectl version --client && helm version --short` should both succeed. If `./uis start` works and `kubectl` is on the path, you're set.

---

## Phase 2: Tooling install (one-time per provision-host build)

Two CLIs not installed by default. Both via `./uis tools install`. See [Tools](../../../reference/tools.md) for the full catalogue and how the install system works.

### Tasks

- [ ] 2.1 **Azure CLI** — needed by `00-bootstrap-state.sh`, `01-apply.sh`, and `03-destroy.sh` to call Azure APIs (login, fetch storage keys, create resource groups, etc.).
  ```
  ./uis tools install azure-cli
  ```
  Validates with: `./uis exec az --version` (any version is fine; >= 2.50 is what current scripts assume).

- [ ] 2.2 **OpenTofu** — needed by `01-apply.sh` and `03-destroy.sh` to run the IaC module in `platforms/azure-aks/tofu/`.
  ```
  ./uis tools install opentofu
  ```
  Validates with: `./uis exec tofu --version`. Must be `>= 1.6.0` (the floor in `tofu/main.tf`).

### Why "install on demand" instead of baked into the image

The provision-host image stays small by default; contributors add only what their workflow needs. AWS/GCP/Azure CLIs and OpenTofu are all opt-in. Installs survive container restarts but disappear if you `docker rm` the container or rebuild from scratch — that's expected; re-run the two install commands after a rebuild.

---

## Phase 3: First login + discover your Azure values

You can't fill in the config in Phase 4 without first knowing your tenant ID, subscription ID, available regions, and a globally-unique storage account name. This phase is a one-time discovery session: log in once, run a handful of `az` commands to print the values, jot them down (or leave the terminal open for Phase 4). Phase 4 then plugs them into the config file.

### Before you start: prepare your browser session

`az login --use-device-code` works by giving you a short code that you paste into a Microsoft sign-in page in your laptop browser. The browser is what does the actual authentication — the container just receives a token afterwards. So before running the device-code command, **make sure the browser session is set up correctly**:

1. Sign in to <https://account.microsoft.com> (or any Microsoft service like Outlook on the web) with the account that has access to the helpers.no nonprofit grant subscription.
2. If you have multiple Microsoft accounts and the wrong one is currently the default, either sign out of the others first or use a private/incognito window for the device-code page so it forces a fresh sign-in to the right account.
3. Don't have any Conditional Access pop-ups blocked — the device-code flow may prompt for MFA depending on tenant policy.

Reference: [Azure CLI device-code authentication docs](https://learn.microsoft.com/en-us/cli/azure/authenticate-azure-cli-interactively#sign-in-with-a-web-browser).

### Tasks

- [ ] 3.1 Open a shell inside the container with the UIS wrapper, then start a device-code login. *No `--tenant` flag here* — you might be in multiple tenants and we want to see them all:
  ```
  ./uis shell
  cd /mnt/urbalurbadisk
  az login --use-device-code
  ```
  `./uis shell` is the project's idiomatic way to enter the container — equivalent to `docker exec -it uis-provision-host bash` but matches the other `./uis` commands in this runbook.

  **What you'll see** — Azure CLI prints a code, opens the device-code page in your browser (or you open it yourself), and after you authenticate it lists the tenants/subscriptions your account can reach:
  ```
  ansible@lima-rancher-desktop:/mnt/urbalurbadisk$ az login --use-device-code
  To sign in, use a web browser to open the page https://login.microsoft.com/device and enter the code XXXXXXXXX to authenticate.

  Retrieving tenants and subscriptions for the selection...

  [Tenant and subscription selection]

  No     Subscription name           Subscription ID                       Tenant
  -----  --------------------------  ------------------------------------  ----------
  [1] *  <subscription-name>         <subscription-guid>                   <tenant-name>

  The default is marked with an *; the default tenant is '<tenant-name>' and subscription is '<subscription-name>' (<subscription-guid>).

  Select a subscription and tenant (Type a number or Enter for no changes):
  ```
  Press Enter to accept the default if there's only one row, or type the row number for the helpers.no grant subscription if multiple are listed. Note that `az login`'s output shows the tenant *display name* (e.g. `Helpers.no`) — Phase 4 needs the tenant **GUID**, which step 3.2 prints next.

- [ ] 3.2 Print both GUIDs in a single table — this is where `AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID` come from for Phase 4:
  ```
  az account list --query "[].{name:name, subscriptionId:id, tenantId:tenantId, isDefault:isDefault}" -o table
  ```
  Sample output (genericized):
  ```
  Name                      SubscriptionId                        TenantId                              IsDefault
  ------------------------  ------------------------------------  ------------------------------------  -----------
  <subscription-name>       <subscription-guid>                   <tenant-guid>                         True
  ```
  **Note the two GUIDs** — `SubscriptionId` is your `AZURE_SUBSCRIPTION_ID` and `TenantId` is your `AZURE_TENANT_ID`. The `IsDefault: True` row is the active one. If multiple rows are listed and the wrong one is `True`, see step 3.3.

- [ ] 3.3 *(Only if step 3.2 shows multiple subscriptions and the wrong one is `IsDefault: True`)* Switch the active subscription:
  ```
  az account set --subscription <SUBSCRIPTION_ID>
  az account show --query "{name:name, id:id, tenantId:tenantId}"
  ```

- [ ] 3.4 Confirm you have working permissions on the subscription. Two complementary checks:

  **(a) The lightweight practical test — can you list resource groups?** If this returns rows (or an empty list with no error), you have at least Reader and almost certainly enough for the rest of this runbook:
  ```
  az group list --query "[].name" -o tsv | head -5
  ```
  If this fails with `AuthorizationFailed` or similar, your role isn't active — activate via PIM (see *Troubleshooting*).

  **(b) Optional — see how your role is granted.** Owner / Contributor can be granted directly, via group membership, or inherited from a management group. This wider query surfaces all three:
  ```
  az role assignment list \
      --assignee "$(az account show --query user.name -o tsv)" \
      --scope "/subscriptions/$(az account show --query id -o tsv)" \
      --include-inherited \
      --include-groups \
      --query "[?roleDefinitionName=='Owner' || roleDefinitionName=='Contributor'].{role:roleDefinitionName, scope:scope, principalType:principalType}" \
      -o table
  ```
  Expected: at least one row showing `Owner` or `Contributor`. **If (a) succeeded but (b) is empty, that's fine** — your role may be granted in a way that's obscured by Azure's RBAC tooling (e.g., via a custom role definition that inherits Contributor permissions but isn't named "Owner"/"Contributor"). The authoritative test is whether the bootstrap script in Phase 5 actually creates resources.

- [ ] 3.5 **Register the Azure resource providers your subscription needs.** A fresh subscription has none registered by default — `az account list-locations` works without registration, but anything that creates or queries provider-specific resources (VMs, AKS, storage, networking) returns empty or fails until the provider is registered for your subscription. *This step is silently fatal if skipped*: step 3.7's vCPU quota check returns empty when `Microsoft.Compute` is `NotRegistered`, and Phase 6's `tofu apply` hangs or errors on the first resource create.

  > **Cost: zero.** Registering a provider is *not* the same as creating resources. It's a metadata flag on your subscription that says "this subscription is opted-in to be able to use this service's API" — a binary toggle in Azure's tenant database. No VMs spin up, no clusters get created, no storage gets provisioned, **nothing appears on the bill**. Cost only arrives when you actually create a resource (Phase 5 onward), and even then `03-destroy.sh` is the cost gate that wipes it. You can register the providers, change your mind, never run Phase 5/6, and your bill stays at €0.

  Check the five providers we'll need:
  ```
  for ns in Microsoft.Compute Microsoft.ContainerService Microsoft.Network Microsoft.Storage Microsoft.OperationalInsights; do
    echo -n "$ns: "
    az provider show --namespace "$ns" --query "registrationState" -o tsv
  done
  ```

  **Sample output on a fresh subscription** (none registered yet):
  ```
  Microsoft.Compute: NotRegistered
  Microsoft.ContainerService: NotRegistered
  Microsoft.Network: NotRegistered
  Microsoft.Storage: NotRegistered
  Microsoft.OperationalInsights: NotRegistered
  ```

  **Sample output mid-registration** (entries cycle through `Registering` while Azure works):
  ```
  Microsoft.Compute: Registering
  Microsoft.ContainerService: Registered
  Microsoft.Network: Registering
  Microsoft.Storage: Registered
  Microsoft.OperationalInsights: Registering
  ```

  **Sample output once everything is ready**:
  ```
  Microsoft.Compute: Registered
  Microsoft.ContainerService: Registered
  Microsoft.Network: Registered
  Microsoft.Storage: Registered
  Microsoft.OperationalInsights: Registered
  ```

  If any are `NotRegistered` (or `Registering` from a previous attempt), register them. Idempotent — safe on already-registered providers; registration is async and each takes 1–5 minutes:
  ```
  for ns in Microsoft.Compute Microsoft.ContainerService Microsoft.Network Microsoft.Storage Microsoft.OperationalInsights; do
    az provider register --namespace "$ns"
  done
  ```

  Sample output (each call returns immediately with "registration started" — actual completion is async):
  ```
  Registering is still on-going. You can monitor using 'az provider show -n Microsoft.Compute'
  Registering is still on-going. You can monitor using 'az provider show -n Microsoft.ContainerService'
  Registering is still on-going. You can monitor using 'az provider show -n Microsoft.Network'
  Registering is still on-going. You can monitor using 'az provider show -n Microsoft.Storage'
  Registering is still on-going. You can monitor using 'az provider show -n Microsoft.OperationalInsights'
  ```

  Re-run the status loop every minute or two until all five say `Registered`. While waiting you can continue to steps 3.6 and 3.7 — but **do not skip ahead to Phase 5** until everything is `Registered`.

  Why each one:

  | Provider | Used for |
  |---|---|
  | `Microsoft.Compute` | VMs (the AKS node pool) and vCPU-quota data for step 3.7 |
  | `Microsoft.ContainerService` | AKS itself (the cluster resource) |
  | `Microsoft.Network` | VNet, LoadBalancer (Traefik external IP), NSG |
  | `Microsoft.Storage` | the OpenTofu state backend storage account in Phase 5 |
  | `Microsoft.OperationalInsights` | the Log Analytics workspace the AKS monitoring add-on requires |

- [ ] 3.6 Pick your Azure region and confirm it's available in your subscription. **Region choice depends on where you operate from** — pick the geographically closest region for latency and (usually) lower egress costs.

  List every location your subscription can use:
  ```
  az account list-locations --query "[].{Name:name, Display:displayName}" -o table
  ```

  Common picks by geography (use the lowercase `Name` value for `AZURE_AKS_LOCATION` in Phase 4):

  | Region | Examples |
  |---|---|
  | Europe | `westeurope` (Netherlands), `northeurope` (Ireland), `swedencentral`, `francecentral` |
  | Americas | `eastus`, `westus3`, `centralus`, `canadacentral`, `brazilsouth` |
  | Asia / Pacific | `eastasia` (Hong Kong), `southeastasia` (Singapore), `japaneast`, `australiaeast`, `koreacentral` |
  | Africa / Middle East | `southafricanorth`, `uaenorth` |

  For helpers.no, the default applied by the scripts is `westeurope` because that's where helpers.no's grant resources are commonly placed. If you're operating from elsewhere, pick the region nearest you and set `AZURE_AKS_LOCATION` in your env file.

  Set a shell variable for the rest of this phase so the quota check in step 3.7 uses the same region:
  ```
  MY_LOCATION=westeurope    # ← change to your chosen region
  az account list-locations --query "[?name=='$MY_LOCATION']" -o table
  ```
  Expected: one row matching your choice. Empty = the region isn't enabled in your subscription; pick a different one and re-run.

- [ ] 3.7 Check vCPU quota for the default VM size (`Standard_B2ms` — 2 vCPUs, B-family burstable) **in the region you picked in 3.6**. The default cluster shape (`NODE_COUNT=1`, `MAX_COUNT=3`) needs 2–6 vCPUs in the B-family. **Requires `Microsoft.Compute` to be `Registered` (step 3.5)** — empty output here means registration hasn't completed yet:
  ```
  az vm list-usage --location "$MY_LOCATION" --query "[?contains(name.value, 'BS')]" -o table
  ```

  Sample output:
  ```
  CurrentValue    Limit    LocalName
  --------------  -------  ---------------------------------------
  0               65       Standard BS Family vCPUs                 ← THE ONE THAT MATTERS
  0               65       Standard EIBSv5 Family vCPUs
  0               65       Standard EBSv5 Family vCPUs
  0               65       Standard HBS Family vCPUs
  0               350      Standard MBSMediumMemoryv3 Family vCPUs
  0               0        Standard PBS Family vCPUs
  ```

  The substring filter catches several "BS"-named families. **Look at the row labelled exactly "Standard BS Family vCPUs"** — that's the B-family that includes `Standard_B2ms`. The others (EIBSv5, EBSv5, HBS, MBSMediumMemoryv3, PBS) are unrelated VM families. A fresh subscription typically has `Limit: 65` for the BS family, so `0 + 6 ≤ 65` leaves comfortable headroom.

  If `CurrentValue + 6 > Limit`, you'll hit quota during Phase 6 (provision). Fix: increase the quota in the portal for this region (Subscription → Usage + quotas → request increase — usually granted instantly for small bumps), or set a smaller `AZURE_AKS_NODE_SIZE` in Phase 4 (e.g. `Standard_B1ms` = 1 vCPU per node).

  **Also worth checking — the regional total cap.** Drop the filter to see every quota row, including the broader caps that apply *across* all VM families:
  ```
  az vm list-usage --location "$MY_LOCATION" -o table | head -40
  ```
  Look for the **"Total Regional vCPUs"** row — that's the overall vCPU cap for the entire region, separate from per-family limits. Even if `Standard BS Family vCPUs` has headroom, you can't exceed `Total Regional vCPUs`. On a fresh subscription this is also typically `0/65`, well above what any default cluster needs. If you have other workloads already running in this region, do the math: existing `CurrentValue` + 6 ≤ `Limit` for both the BS family row *and* the total regional row.

  Use the unfiltered output as a fallback if the filtered query returns empty — Azure occasionally returns family names with different casing across regions, and the unfiltered table sidesteps the JMESPath filter.

- [ ] 3.8 Pick a globally-unique storage account name for the OpenTofu state. Names are *globally unique across all of Azure*. Try candidates until one comes back `true`:
  ```
  az storage account check-name --name sahelpersnotfstate --query nameAvailable -o tsv
  az storage account check-name --name sahelpersnotfstate2026 --query nameAvailable -o tsv
  ```
  The first one that prints `true` is yours; **note that name** for Phase 4's `AZURE_STATE_STORAGE_ACCOUNT`. Constraint: lowercase letters + digits only, 3–24 chars.

- [ ] 3.9 Get your email for the Azure tags:
  ```
  az ad signed-in-user show --query userPrincipalName -o tsv
  ```
  Use that for `AZURE_TAG_BUSINESS_OWNER` / `AZURE_TAG_IT_OWNER` (or substitute helpers.no's actual business policy emails if different). The scripts auto-default these to your sign-in email if you leave them commented out.

- [ ] 3.10 Optional — list any existing resource groups so you don't pick an `AZURE_AKS_RESOURCE_GROUP` name that collides with something already in the subscription:
  ```
  az group list --query "[].{name:name, location:location}" -o table
  ```
  Defaults `rg-urbalurba-aks-weu` and `rg-urbalurba-tfstate` are unlikely to collide; check anyway.

### What you should now have written down

Copy these into a scratch buffer / sticky note before Phase 4:

| Phase 4 variable | Value from this phase |
|---|---|
| `AZURE_TENANT_ID` | the GUID in the `TenantId` column of step 3.2's output |
| `AZURE_SUBSCRIPTION_ID` | the GUID in the `SubscriptionId` column of step 3.2's output |
| `AZURE_AKS_LOCATION` *(optional, defaults to `westeurope`)* | the region you picked in step 3.6 |
| `AZURE_AKS_NODE_SIZE` *(optional, defaults to `Standard_B2ms`)* | smaller VM if quota check in 3.7 was tight |
| `AZURE_STATE_STORAGE_ACCOUNT` | the unique name from step 3.8 |
| `AZURE_TAG_BUSINESS_OWNER`, `AZURE_TAG_IT_OWNER` *(optional, defaults to your sign-in email)* | from step 3.9 |

The other Phase 4 variables (`AZURE_AKS_RESOURCE_GROUP`, `AZURE_AKS_CLUSTER_NAME`, `AZURE_AKS_STATE_RESOURCE_GROUP`, `AZURE_AKS_STATE_CONTAINER`, `AZURE_AKS_STATE_KEY`, `AZURE_TAG_COST_CENTER`, `AZURE_AKS_NODE_COUNT`, `AZURE_AKS_MIN_COUNT`, `AZURE_AKS_MAX_COUNT`, `AZURE_AKS_OS_DISK_SIZE`) all have safe defaults applied by the scripts when left commented — Phase 4 explains each.

### What this phase leaves behind

A token in `~/.azure/` inside the container. It survives `docker stop` / `docker start` of the container, but disappears on `docker rm` (full container delete) — re-run `az login` if you destroy the container. Tokens also expire (~1 hour for the access token, ~90 days for the refresh token without re-auth). If a later phase says "Not logged in", just re-run `az login --tenant "$TENANT_ID" --use-device-code`.

### Validation

You can answer for every variable in Phase 4 either *"I have its value"* or *"I'll use the default"*. If both are true, you're ready for Phase 4.

---

## Phase 4: Configuration — what every variable means and where to find it

Per the [secrets architecture doc](../../../contributors/architecture/secrets.md), Azure cloud-account values live at `.uis.secrets/cloud-accounts/azure-default.env` (gitignored, machine-local). This is the same convention the rest of UIS uses — `cloud-accounts/<provider>-default.env` for any cloud-provider config — and the `platforms/azure-aks/scripts/*.sh` scripts source it via the `get_cloud_credentials_path` helper from `provision-host/uis/lib/paths.sh`.

The file does not exist by default. Create it from the committed template:

```
cp provision-host/uis/templates/uis.secrets/cloud-accounts/azure.env.template \
   .uis.secrets/cloud-accounts/azure-default.env
```

Then edit `.uis.secrets/cloud-accounts/azure-default.env`. Only three values are required to fill in; everything else is optional and the scripts apply sensible defaults when you leave it commented.

### Variable-by-variable

#### REQUIRED — only these need values to fill in

| Variable | What it is | How to find it |
|---|---|---|
| `AZURE_TENANT_ID` | The GUID of your Microsoft Entra (Azure AD) tenant. Identifies the directory `az login` authenticates against. | From step 3.2's `az account list -o table` — the `TenantId` column. Or `az account show --query tenantId -o tsv`. |
| `AZURE_SUBSCRIPTION_ID` | The GUID of the subscription that pays for the AKS cluster (the Microsoft nonprofit grant subscription for helpers.no). | From step 3.2's output — the `SubscriptionId` column. Or `az account show --query id -o tsv`. |
| `AZURE_STATE_STORAGE_ACCOUNT` | Name of the Azure Storage Account holding the OpenTofu state blob. **Globally unique across all of Azure.** | The unique name you picked in step 3.8 with `az storage account check-name`. Lowercase letters + digits, 3–24 chars. |

> **No password or service principal stored anywhere.** `01-apply.sh` calls `az login --use-device-code` interactively on first run; the token caches in `~/.azure/` inside the container. When the token expires, you re-run device-code login. There is *nothing* in `kubernetes-secrets.yml` related to Azure infrastructure auth — that file is for cluster workloads.

#### OPTIONAL — Azure tags for cost tracking

Defaults to your `az ad signed-in-user` email (step 3.9) if you leave them commented out.

| Variable | Purpose | Default behaviour |
|---|---|---|
| `AZURE_TAG_BUSINESS_OWNER` | Email of the human who pays for it. | Falls back to your sign-in email. |
| `AZURE_TAG_IT_OWNER` | Email of the human who operates it. | Falls back to your sign-in email. |
| `AZURE_TAG_COST_CENTER` | Cost center identifier for billing reports. | `helpers-no`. |

`tag_project` (`urbalurba-infrastructure`) and `tag_environment` (`Sandbox`) are baked into the scripts as constants.

#### OPTIONAL — AKS cluster shape

All of these have defaults applied via `${VAR:-default}` in the scripts. Uncomment in your env file only to override.

| Variable | Default | What changes if you change it |
|---|---|---|
| `AZURE_AKS_LOCATION` | `westeurope` | Azure region. Different region = different latency/price/quota pool. Pick what's geographically nearest you. |
| `AZURE_AKS_RESOURCE_GROUP` | `rg-urbalurba-aks-weu` | The RG holding the cluster + its Log Analytics workspace + MC_* node-resource-group. |
| `AZURE_AKS_CLUSTER_NAME` | `azure-aks` | The AKS cluster name. Also becomes the kubectl *context* name and the DNS prefix on the API server. Change to run multiple clusters side by side. |
| `AZURE_AKS_NODE_SIZE` | `Standard_B2ms` (2 vCPU / 8 GiB / burstable) | VM SKU for the node pool. Determines vCPUs / RAM / pricing. |
| `AZURE_AKS_NODE_COUNT` | `1` | Initial node count. The autoscaler moves from this baseline. |
| `AZURE_AKS_MIN_COUNT` | `1` | Cluster autoscaler minimum. |
| `AZURE_AKS_MAX_COUNT` | `3` | Cluster autoscaler maximum. Caps the bill at 3 × `AZURE_AKS_NODE_SIZE` cost. |
| `AZURE_AKS_OS_DISK_SIZE` | `30` | Per-node OS disk size in GB. |

> **Cost note**: `Standard_B2ms` ≈ €36/month per node 24/7 in West Europe (~€1.20/day). Three nodes ≈ €100/month if left running. Treat `03-destroy.sh` as load-bearing — see Phase 9.

#### OPTIONAL — OpenTofu state backend layout

OpenTofu needs a remote state backend so the cluster's IaC state survives destroy/recreate cycles. The state is in Azure Blob Storage, in a separate Resource Group from the cluster.

| Variable | Default | Constraints |
|---|---|---|
| `AZURE_AKS_STATE_RESOURCE_GROUP` | `rg-urbalurba-tfstate` | Holds the state storage account. Created once by `00-bootstrap-state.sh` and never destroyed. Must not collide with `AZURE_AKS_RESOURCE_GROUP`. |
| `AZURE_AKS_STATE_CONTAINER` | `tfstate` | Blob container name inside `AZURE_STATE_STORAGE_ACCOUNT`. |
| `AZURE_AKS_STATE_KEY` | `aks/terraform.tfstate` | Blob name (think filename) of the state blob. The path-like syntax keeps room for future state files (e.g. `gke/terraform.tfstate`) in the same container. |

> **Why state is bootstrapped with `az` before `tofu` ever runs**: chicken-and-egg — OpenTofu needs the storage account to *exist* before it can store state there. `00-bootstrap-state.sh` creates it imperatively via `az`, then `tofu` uses it for everything else.

#### Variables baked into the scripts (no env-file knob)

| Variable | What | Where set |
|---|---|---|
| `KUBECONFIG_FILE` | Path inside the container where `01-apply.sh` writes the AKS kubeconfig. Derived as `/mnt/urbalurbadisk/kubeconfig/${AZURE_AKS_CLUSTER_NAME}-kubeconf`. | Each script computes this from `AZURE_AKS_CLUSTER_NAME`. |
| `tag_project`, `tag_environment` | Hard-coded to `urbalurba-infrastructure` / `Sandbox` in the tfvars heredoc. | `01-apply.sh`. Adjust the script directly if you need a different value. |

### Validation

After saving `.uis.secrets/cloud-accounts/azure-default.env`:

- `git check-ignore -v .uis.secrets/cloud-accounts/azure-default.env` → confirms the file is gitignored (the whole `.uis.secrets/` tree is).
- `bash -n .uis.secrets/cloud-accounts/azure-default.env` → syntax OK.
- `source .uis.secrets/cloud-accounts/azure-default.env && echo "$AZURE_TENANT_ID $AZURE_SUBSCRIPTION_ID $AZURE_STATE_STORAGE_ACCOUNT"` → all three required values print non-empty.

---

## Phase 5: Bootstrap the state backend (one-time per subscription)

Run this **once**. The state RG and storage account it creates survive cluster destroys; you don't run this again unless you're starting over with a brand-new state location.

### Tasks

- [ ] 5.1 Run the bootstrap:
  ```
  ./platforms/azure-aks/scripts/00-bootstrap-state.sh
  ```

- [ ] 5.2 Walk through the prompts. The script:
  - Confirms what it's about to create (state RG, storage account, container) — type `y`.
  - Verifies `az login` is good.
  - Creates the state Resource Group (idempotent — skips if exists).
  - Creates the storage account (idempotent — skips if exists). **This is where global-name collisions surface** if `AZURE_STATE_STORAGE_ACCOUNT` is taken.
  - Creates the blob container.
  - Enables blob versioning so an accidental state overwrite is recoverable.

- [ ] 5.3 Verify:
  ```
  az group show --name "$STATE_RESOURCE_GROUP" --query "name"
  az storage account show --name "$STATE_STORAGE_ACCOUNT" --resource-group "$STATE_RESOURCE_GROUP" --query "name"
  ```

### Expected output

`BOOTSTRAP COMPLETE` banner, then a print-out of the values that will go into `tofu/backend.tf`. Total run time ~30–60 seconds.

### Failure modes

- **Storage account name globally taken** → `az storage account create` returns "name is already in use". Pick a different `AZURE_STATE_STORAGE_ACCOUNT`, re-run.
- **No Contributor role** → `az group create` returns AuthorizationFailed. Activate Contributor via PIM, re-run.

---

## Phase 6: Provision the cluster (`01-apply.sh`)

This is the big one — creates the AKS cluster. Takes ~5–10 minutes.

### Tasks

- [ ] 6.1 Run the apply script:
  ```
  ./platforms/azure-aks/scripts/01-apply.sh
  ```

- [ ] 6.2 Walk through what it does:
  - **Verifies `az login`** (re-prompts if expired).
  - **Checks Contributor role**.
  - **Fetches the storage account access key** dynamically and exports it as `ARM_ACCESS_KEY` (OpenTofu's azurerm-backend reads this env var; nothing static stored).
  - **Generates `tofu/terraform.tfvars`** from `.uis.secrets/cloud-accounts/azure-default.env` — auto-generated, do not edit.
  - **Runs `tofu init`** — downloads providers (azurerm), configures the remote backend.
  - **Runs `tofu plan -out=tfplan`** — shows what's about to change. Review the plan output: should show *create* for `azurerm_resource_group.aks`, `azurerm_log_analytics_workspace.aks`, `azurerm_kubernetes_cluster.aks`. No destroys, no replaces.
  - **Prompts to confirm apply** — type `y`.
  - **Runs `tofu apply tfplan`** — creates the resources. AKS itself takes 5–10 minutes; the plan output mid-run is normal.
  - **Writes the kubeconfig** to `$KUBECONFIG_FILE` from `tofu output -raw kube_config_raw`.
  - **Smoke-checks** with `kubectl get nodes` against the new kubeconfig.

- [ ] 6.3 Verify:
  ```
  KUBECONFIG="$KUBECONFIG_FILE" kubectl get nodes
  ```
  Expected: 1 node with status `Ready` (matches `NODE_COUNT=1`).

### Expected output

`APPLY COMPLETE` banner with cluster name, location, kubeconfig path. Total ~5–10 minutes (most of which is Azure provisioning AKS, not script overhead).

### Failure modes

- **Quota exceeded** → `tofu apply` fails mid-flight with "QuotaExceeded" or similar. Increase quota in the Azure portal (Subscription → Usage + quotas) or pick a smaller `AZURE_AKS_NODE_SIZE`. Re-run `01-apply.sh`; OpenTofu will resume from where it failed.
- **Provider version drift** → if Azure changes the API contract, `tofu plan` may show unexpected diffs. Pin the provider in `tofu/main.tf` (`version = "~> 3.100"` is what's there now).
- **kubeconfig mismatch** → if the script writes `kubeconf-all` instead of `azure-aks-kubeconf` (or vice-versa), check `$KUBECONFIG_FILE` in the config matches what's in `01-apply.sh`'s output write.

---

## Phase 7: Configure the cluster (`02-post-apply.sh`)

Cluster's up but bare. This script does the post-provisioning setup.

### Tasks

- [ ] 7.1 Run:
  ```
  ./platforms/azure-aks/scripts/02-post-apply.sh
  ```

- [ ] 7.2 What it does, in order:
  - **Merges the AKS kubeconfig** into `kubeconf-all` via `ansible/playbooks/04-merge-kubeconf.yml` so `kubectl config get-contexts` shows both `rancher-desktop` and the new AKS context side by side.
  - **Switches kubectl context** to the AKS cluster.
  - **Applies storage class aliases** from `platforms/azure-aks/manifests/000-storage-class-azure-alias.yaml` — this maps `local-path` and `microk8s-hostpath` (which UIS service manifests reference) to Azure-Disk-backed storage classes. Without this, every UIS service that requests `local-path` PVCs fails on AKS.
  - **(After PLAN-002 ships)** applies `kubernetes-secrets.yml` to the cluster. As of 2026-05-08 this step is still missing — see the *Without PLAN-002* note below.
  - **Installs Traefik via Helm** with values from `manifests/003-traefik-config.yaml`. AKS provisions a public LoadBalancer and gives it an external IP.
  - **Waits for the external IP** (up to 2 min).

- [ ] 7.3 Verify:
  ```
  kubectl config use-context "$CLUSTER_NAME"
  kubectl get pods -n kube-system -l app.kubernetes.io/name=traefik
  kubectl get svc traefik -n kube-system
  ```
  Expected: Traefik pod `Running`; service has an `EXTERNAL-IP` (not `<pending>`).

### Expected output

`POST-APPLY COMPLETE — CLUSTER READY` banner. Total ~2–4 minutes (most of which is Helm fetching Traefik + Azure assigning the public IP).

### Without PLAN-002

The current `02-post-apply.sh` skips applying `kubernetes-secrets.yml` (gap-analysis finding from 2026-05-07). For the nginx verification (Phase 8 below), this is fine — nginx doesn't need cluster secrets. For *any other* UIS service (postgresql, authentik, openwebui, postgrest), you'll either need to:

1. Wait for [PLAN-platform-aks-002-secrets-apply-parity.md](../completed/PLAN-platform-aks-002-secrets-apply-parity.md) to ship, or
2. Manually apply the secrets after this script: `kubectl apply -f .uis.secrets/generated/kubernetes/kubernetes-secrets.yml` (after running `./uis secrets generate` once).

---

## Phase 8: Verify with `./uis deploy nginx`

The verification bar from the investigation.

### Tasks

- [ ] 8.1 Confirm context is on AKS, not Rancher Desktop:
  ```
  kubectl config current-context
  ```
  Expected: matches `$CLUSTER_NAME` (default `azure-aks`). If it's `rancher-desktop`, switch:
  ```
  kubectl config use-context "$CLUSTER_NAME"
  ```

- [ ] 8.2 Deploy nginx:
  ```
  ./uis deploy nginx
  ```

- [ ] 8.3 Watch the playbook (`ansible/playbooks/020-setup-nginx.yml`) run. Steps 13 and 15 are the load-bearing ones — they spin up an in-cluster `curl-test` pod and fetch a test file + the index page via cluster-internal DNS:
  - Step 13 fetches `http://nginx.default.svc.cluster.local:<port>/<test-file>`.
  - Step 15 fetches `http://nginx.default.svc.cluster.local:<port>/`.
  Both should return 200 with content. If either fails, the cluster's networking, scheduling, storage, or service DNS is broken.

- [ ] 8.4 Optionally, hit nginx from outside the cluster via the Traefik external IP:
  ```
  EXTERNAL_IP=$(kubectl get svc traefik -n kube-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  curl -v "http://$EXTERNAL_IP/"
  ```
  Expected: nginx welcome page (or whatever the IngressRoute serves at root).

### Expected output

`./uis deploy nginx` finishes with no failed tasks; the playbook's "Test connectivity" steps print the test-file content.

### Failure modes

- **Pod stuck in `Pending`** → check `kubectl describe pod` for the reason. Usually means storage class mismatch (Phase 7's storage-class aliases didn't apply) or insufficient cluster resources.
- **External IP `<pending>`** → AKS LoadBalancer hasn't been provisioned. Wait 1–2 more minutes; if still pending, check `kubectl describe svc traefik -n kube-system` for events.
- **In-cluster curl fails** → the cluster has a networking issue (rare). Check `kubectl get pods -n kube-system` for any not-ready CoreDNS pods.

---

## Phase 9: Tear down (`03-destroy.sh`)

**Run this every time you're done.** AKS bills while running.

### Tasks

- [ ] 9.1 Run:
  ```
  ./platforms/azure-aks/scripts/03-destroy.sh
  ```

- [ ] 9.2 What it does:
  - Confirms with you (type `y` after reviewing what will be destroyed).
  - Runs `tofu destroy` with the same backend config — removes the AKS cluster, its resource group, the Log Analytics workspace, and the LoadBalancer IP.
  - **Does NOT** destroy the state RG / storage account from Phase 5 — those persist by design.

- [ ] 9.3 Verify:
  ```
  az group list -o table | grep -E "$RESOURCE_GROUP|$STATE_RESOURCE_GROUP"
  ```
  Expected: only `$STATE_RESOURCE_GROUP` listed; the cluster RG is gone.

### What persists

- The state Resource Group + storage account (a few cents per month, by design).
- Your `~/.azure/` token cache inside the container (until `docker rm`).
- `.uis.secrets/cloud-accounts/azure-default.env` (your config — not deleted).

### What's gone

- The cluster, its node pool, the Log Analytics workspace, the LoadBalancer + public IP.
- All workloads that were running on the cluster (deployments, secrets, configmaps).

### Cost gate

If `03-destroy.sh` errors out partway, **don't walk away** — the cluster is still billing. Re-run the script, or destroy the resource group manually with `az group delete --name "$RESOURCE_GROUP" --yes --no-wait`.

### State RG: persistence vs verification-loop teardown

The state RG (`rg-urbalurba-tfstate` by default) is **intentionally preserved** by `03-destroy.sh`. For production AKS — where you want state continuity across destroy/recreate cycles — that's the right behavior.

For **verification-loop testing** of `00-bootstrap-state.sh → 01-apply.sh` end-to-end, the persistent state RG is a liability:

- If `03-destroy.sh` partially fails (e.g. an orphan resource the provider couldn't reach), the AKS cluster RG is gone but `azurerm_resource_group.aks` may still be in the state file. The next `01-apply.sh` then sees a desynchronised state vs reality.
- A real first-time AKS Step 1 starts with no state at all — the bootstrap script's idempotency *should* be tested against an empty subscription, not against a state blob from a previous run.

So when running PLAN-001 verification (rather than provisioning a real long-lived cluster), tear down the state RG too after `03-destroy.sh`:

```
az group delete --name rg-urbalurba-tfstate --yes
```

Takes ~30-70s. The next run of the verification ladder re-creates `rg-urbalurba-tfstate` from scratch via `00-bootstrap-state.sh` — exercising the full bootstrap path, which is what we want under test. *(Future: a `--purge-state` flag on `03-destroy.sh` would script this; backlog item.)*

---

## Phase 10: Recreate (subsequent runs)

After the first end-to-end run-through, recreating a cluster is the bottom half of this plan only:

```
./uis shell
cd /mnt/urbalurbadisk

# Re-auth if token expired (the discovery login from Phase 3 may have lapsed)
source .uis.secrets/cloud-accounts/azure-default.env
az account show >/dev/null 2>&1 || az login --tenant "$TENANT_ID" --use-device-code

# Phase 5 SKIPPED — state backend persists

# Phase 6 — apply
./platforms/azure-aks/scripts/01-apply.sh

# Phase 7 — post-apply
./platforms/azure-aks/scripts/02-post-apply.sh

# Phase 8 — verify
./uis deploy nginx

# Phase 9 — destroy when done
./platforms/azure-aks/scripts/03-destroy.sh
```

Roughly 10–15 minutes round trip if everything is healthy.

---

## Acceptance Criteria

This plan is "done" when an operator who has never provisioned AKS before can read it top-to-bottom, fill in their values, and successfully complete Phases 3–9 against a real Azure subscription with no further questions to the maintainer. PLAN-001 Phase 2's tester report is the empirical test of that.

Concrete checklist on first use:
- [ ] Operator created `.uis.secrets/cloud-accounts/azure-default.env` with all required values filled in.
- [ ] Operator successfully authenticated via device-code flow.
- [ ] `00-bootstrap-state.sh` completed without errors.
- [ ] `01-apply.sh` provisioned the cluster within 10 minutes.
- [ ] `02-post-apply.sh` configured the cluster (storage classes + Traefik).
- [ ] `./uis deploy nginx` succeeded with the in-cluster curl tests passing.
- [ ] `03-destroy.sh` cleaned up; cluster RG no longer listed in the subscription.

---

## Troubleshooting

### "Contributor role not detected"

PIM activation hasn't propagated. Activate at <https://portal.azure.com/?feature.msaljs=true#view/Microsoft_Azure_PIMCommon/ActivationMenuBlade/~/azurerbac>, wait 1–2 minutes, re-run the failing command. The script's check loop (`01-azure-aks-create.sh:55-97` in the bash precedent) gives you 3 retry attempts — the OpenTofu version is single-shot and you'll have to re-run it from the top.

### "Storage account name already in use" during `00-bootstrap-state.sh`

Storage account names are *globally unique across all of Azure*. Pick a fresh name with helpers.no in it (e.g. `sahelpersnotfstate`), update `AZURE_STATE_STORAGE_ACCOUNT` in your config, re-run `00-bootstrap-state.sh`. Idempotent — won't double-create.

### "QuotaExceeded" during `01-apply.sh`

You don't have enough vCPU quota in the chosen region for the chosen VM size. Two fixes:
- **Increase the quota**: Azure portal → Subscription → Usage + quotas → request increase (instant for small bumps in non-flagship regions; up to 24h for big ones).
- **Pick a smaller VM**: set `AZURE_AKS_NODE_SIZE="Standard_B1ms"` (1 vCPU) in `.uis.secrets/cloud-accounts/azure-default.env`, re-run `01-apply.sh`.

### `tofu apply` fails partway and leaves resources behind

OpenTofu's state will reflect what *did* get created. Two recovery paths:
- **Re-run** `01-apply.sh` — OpenTofu will figure out what's missing and try to create only that.
- **Destroy and start over** — `03-destroy.sh` to clean the partial state, then `01-apply.sh` fresh.

### Traefik external IP stuck `<pending>` for >5 min

AKS LoadBalancer provisioning failed. `kubectl describe svc traefik -n kube-system` will show events. Common causes: the cluster's outbound public IP wasn't assigned (rare; usually a regional Azure issue), or a network-policy mismatch. If unrecoverable, destroy + recreate (it's faster than debugging Azure networking).

### "Cannot connect to cluster with kubectl"

Either:
- Wrong context: `kubectl config current-context` should match `$CLUSTER_NAME`. Switch with `kubectl config use-context "$CLUSTER_NAME"`.
- Stale kubeconfig: `01-apply.sh` should have written a fresh one to `$KUBECONFIG_FILE`. Re-run `02-post-apply.sh` to re-merge into `kubeconf-all`.

### `./uis deploy nginx` fails with "no storage class"

`02-post-apply.sh`'s storage-class aliases didn't apply. Check `kubectl get storageclass` — should show `local-path`, `microk8s-hostpath`, and Azure's defaults. If missing, re-apply: `kubectl apply -f platforms/azure-aks/manifests/000-storage-class-azure-alias.yaml`.

---

## Files to Modify

(This plan is reference documentation; no code changes from the plan itself. The accompanying code work happens via PLAN-001 and PLAN-002.)

- `website/docs/ai-developer/plans/active/PLAN-platform-aks-001b-manual-setup.md` (this file, created at first manual run-through; moves to `completed/` only when the runbook has been successfully exercised end-to-end and any corrections from real-world running have been folded in).

---

## Implementation Notes

- **This is a runbook, not iterative-implementation work.** It's structured as Phases for consistency with other PLANs, but each Phase is a *step in a sequence*, not a *piece of code to land in a PR*. The accompanying code work happens via PLAN-001 (OpenTofu installer + verification) and PLAN-002 (secrets-apply parity).
- **Updates as Phase 2 of PLAN-001 runs.** First-time operators will hit failure modes this document doesn't anticipate. Each gap is an edit to this file (preferably as part of PLAN-001 Phase 3's gap-fixing) — the runbook gets sharper with use.
- **No secrets here.** Despite the keyword density, this document doesn't contain any actual credentials. The variable values you fill in (`AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`) are not secret on their own — they're identifiers; the auth happens via interactive device-code flow and tokens cache in `~/.azure/`.
