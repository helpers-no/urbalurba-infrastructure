#!/bin/bash
# azure-discovery.sh — Shared Azure helpers for per-platform init wizards.
#
# Spec: website/docs/ai-developer/plans/completed/PLAN-uis-platform-init-azure-aks.md
# Sourced by platforms/azure-aks/scripts/init.sh and, in future, by
# platforms/azure-microk8s/scripts/init.sh (which will share the auth +
# subscription-picker + role-check + region-picker pieces).
#
# Contract:
#   - Functions exit non-zero on failure (caller should `set -euo pipefail`).
#   - Functions stream visible output (no spinners, no swallowed stdout) per
#     the always-have-output principle (UIS Ansible playbook convention).
#   - Functions read/write a small set of well-known env vars rather than
#     piping return values: AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID,
#     AZURE_SUBSCRIPTION_NAME, AZURE_REGION.

# Guard against multiple sourcing
[[ -n "${_UIS_AZURE_DISCOVERY_LOADED:-}" ]] && return 0
_UIS_AZURE_DISCOVERY_LOADED=1


# ============================================================
# Preflight
# ============================================================

# require_tools_or_die — verify the AKS-meta-tool dependencies are installed.
# Exits non-zero if `az` or `tofu` is missing, with a clear hint at the
# meta-installer (PLAN #1, shipped 2026-05-10 via PR #154).
require_tools_or_die() {
    set -euo pipefail
    local missing=()
    command -v az   >/dev/null 2>&1 || missing+=("azure-cli")
    command -v tofu >/dev/null 2>&1 || missing+=("opentofu")
    if (( ${#missing[@]} > 0 )); then
        echo "✗ Missing required tool(s): ${missing[*]}"
        echo "  Run './uis tools install azure-aks' to install the AKS dependencies."
        exit 1
    fi
}

# require_interactive_or_die — the wizard is interactive-only (Q5 of the
# parent investigation). Abort early with a clear diagnostic if no TTY is
# attached or UIS_NONINTERACTIVE is set, rather than letting `read` block
# mysteriously mid-wizard.
require_interactive_or_die() {
    set -euo pipefail
    if [[ -n "${UIS_NONINTERACTIVE:-}" ]] || [[ ! -t 0 ]]; then
        echo "✗ This wizard requires an interactive terminal."
        if [[ -n "${UIS_NONINTERACTIVE:-}" ]]; then
            echo "  UIS_NONINTERACTIVE is set, but './uis platform init' does not yet support"
            echo "  non-interactive mode."
        else
            echo "  No TTY attached to stdin. Run this command directly from your terminal,"
            echo "  not via 'docker exec' without -it or piped from a script."
        fi
        exit 1
    fi
}


# ============================================================
# Overwrite / file guards
# ============================================================

# prompt_overwrite_if_exists — Q4. If the cloud-account env file already
# exists, prompt y/N (default no) before letting the caller overwrite it.
# Aborts the wizard with exit 0 (clean exit, not an error) if the user says no.
#
# Args:
#   $1 — absolute path to the target file (e.g. .uis.secrets/cloud-accounts/azure-default.env)
prompt_overwrite_if_exists() {
    set -euo pipefail
    local target="${1:-}"
    [[ -n "$target" ]] || { echo "✗ prompt_overwrite_if_exists called without a path"; exit 1; }

    if [[ -f "$target" ]]; then
        echo
        echo "Config file already exists at: $target"
        local answer
        read -rp "Overwrite existing config? (y/N): " answer
        case "${answer,,}" in
            y|yes)
                echo "✓ Will overwrite on save."
                ;;
            *)
                echo "Aborting. Delete the file manually or pick a different cloud-accounts target."
                exit 0
                ;;
        esac
    fi
}


# ============================================================
# Azure auth + discovery
# ============================================================

# az_login_if_needed — check current az session; run device-code login if not
# signed in. Device code (not browser) because the provision-host container
# has no display. Mines hosts-to-be-deleted/azure-aks/01-azure-aks-create.sh:128-140 (renamed from hosts/ 2026-10-05).
az_login_if_needed() {
    set -euo pipefail
    if az account show >/dev/null 2>&1; then
        local upn
        upn=$(az account show --query user.name -o tsv)
        echo "✓ Already signed in to Azure as $upn"
        return 0
    fi
    echo "Not signed in to Azure. Running 'az login --use-device-code'..."
    echo
    az login --use-device-code
    echo
    echo "✓ Signed in."
}

# pick_subscription — interactive numbered picker. Sets AZURE_SUBSCRIPTION_ID,
# AZURE_SUBSCRIPTION_NAME, AZURE_TENANT_ID; calls `az account set` so
# subsequent `az` commands target the chosen subscription.
#
# Auto-selects if the user has only one subscription.
pick_subscription() {
    set -euo pipefail
    echo
    echo "Available subscriptions:"
    local subs=()
    while IFS=$'\t' read -r name id ; do
        subs+=("${name}"$'\t'"${id}")
    done < <(az account list --query "[].{name:name, id:id}" -o tsv)

    if (( ${#subs[@]} == 0 )); then
        echo "✗ No subscriptions found for the signed-in account."
        echo "  Either you don't have access to any subscriptions, or 'az account list' is filtered."
        echo "  Try 'az account list --refresh' or contact your subscription admin."
        exit 1
    fi

    if (( ${#subs[@]} == 1 )); then
        AZURE_SUBSCRIPTION_NAME="${subs[0]%$'\t'*}"
        AZURE_SUBSCRIPTION_ID="${subs[0]##*$'\t'}"
        echo "  Auto-selected: $AZURE_SUBSCRIPTION_NAME ($AZURE_SUBSCRIPTION_ID)"
        echo "  (only subscription available)"
    else
        local i=1
        for entry in "${subs[@]}"; do
            local name="${entry%$'\t'*}"
            local id="${entry##*$'\t'}"
            echo "  $i) $name ($id)"
            ((i++))
        done
        local choice
        while true; do
            read -rp "Pick a subscription [1-${#subs[@]}]: " choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#subs[@]} )); then
                local picked="${subs[$((choice-1))]}"
                AZURE_SUBSCRIPTION_NAME="${picked%$'\t'*}"
                AZURE_SUBSCRIPTION_ID="${picked##*$'\t'}"
                break
            fi
            echo "  Invalid choice. Enter a number between 1 and ${#subs[@]}."
        done
    fi

    az account set --subscription "$AZURE_SUBSCRIPTION_ID"
    AZURE_TENANT_ID=$(az account show --query tenantId -o tsv)
    export AZURE_SUBSCRIPTION_ID AZURE_SUBSCRIPTION_NAME AZURE_TENANT_ID
    echo "✓ Subscription: $AZURE_SUBSCRIPTION_NAME"
    echo "  ID:     $AZURE_SUBSCRIPTION_ID"
    echo "  Tenant: $AZURE_TENANT_ID"
}

# check_owner_or_contributor — role check with PIM-activation retry loop.
# Mines hosts-to-be-deleted/azure-microk8s/01-azure-vm-create-redcross-v2.sh:36-83
# (renamed from hosts/ 2026-10-05; retry-3x with portal link + "press Enter") and
# combines it with PR #149's
# --include-inherited --include-groups flags for broader role visibility.
#
# Retry-3x is preserved per the maintainer's principle: "if I once made 3
# retries then I did it for a reason. keep it." PIM activation is a normal
# recovery path, not an error edge case. Forcing the user to re-run the whole
# wizard after PIM activation would cost them the sub-pick they already made.
check_owner_or_contributor() {
    set -euo pipefail
    local upn
    upn=$(az account show --query user.name -o tsv)
    local attempt
    for attempt in 1 2 3 ; do
        echo
        echo "Checking role on subscription $AZURE_SUBSCRIPTION_ID for $upn (attempt $attempt/3)..."
        local roles
        roles=$(az role assignment list \
            --assignee "$upn" \
            --scope "/subscriptions/$AZURE_SUBSCRIPTION_ID" \
            --include-inherited --include-groups \
            --query "[?roleDefinitionName=='Owner' || roleDefinitionName=='Contributor'].roleDefinitionName" \
            -o tsv 2>/dev/null | sort -u | tr '\n' ',' | sed 's/,$//')
        if [[ -n "$roles" ]]; then
            echo "✓ Role: $roles"
            return 0
        fi
        echo
        echo "✗ $upn does not currently have Owner or Contributor on this subscription."
        if (( attempt < 3 )); then
            echo "  If your role is assigned via Azure AD PIM, activate it now:"
            echo "  https://portal.azure.com/?feature.msaljs=true#view/Microsoft_Azure_PIMCommon/ActivationMenuBlade/~/azurerbac"
            read -rp "  After activating, press Enter to re-check (or Ctrl-C to abort): " _
        fi
    done
    echo
    echo "✗ Role check failed after 3 attempts. Aborting."
    echo "  Either pick a different subscription, request a role assignment,"
    echo "  or activate Owner/Contributor via the PIM link above and re-run"
    echo "  './uis platform init azure-aks'."
    exit 1
}

# pick_region — single prompt with `westeurope` as the verified-working
# default (matches platforms/azure-aks/tofu/variables.tf default, and the
# region PR #149's Tier A verification rounds ran against).
#
# Empty input → westeurope. Non-empty input → validated against
# `az account list-locations`. No long numbered list, no per-region AKS
# pre-validation (the 1% failure case where AKS isn't supported in the
# chosen region surfaces via 01-apply.sh).
pick_region() {
    set -euo pipefail
    local default_region="westeurope"
    local region
    echo
    while true; do
        read -rp "Region [$default_region]: " region
        region="${region:-$default_region}"
        if az account list-locations --query "[?name=='$region'].name" -o tsv | grep -q .; then
            AZURE_REGION="$region"
            export AZURE_REGION
            echo "✓ Region: $AZURE_REGION"
            return 0
        fi
        echo "  Unknown region '$region'. List available regions with: az account list-locations -o table"
        echo
    done
}

# check_quota — port from hosts-to-be-deleted/azure-aks/check-aks-quota.sh:56-170 (renamed from hosts/ 2026-10-05). Verifies
# the chosen region has enough Standard_B-family vCPUs for the default
# AZURE_NODE_COUNT (1) × AZURE_NODE_SIZE (Standard_B2s_v2, 2 vCPUs) = 2 vCPUs.
# Fail-fast per Q7 — surface the quota issue inside the wizard, not 5 minutes
# into `01-apply.sh`.
#
# Notes:
#   - Defaults match platforms/azure-aks/tofu/variables.tf.
#   - vCPU math is hardcoded for Standard_B2s_v2 (the documented default node
#     size). If we change the default, update this function in lockstep.
check_quota() {
    set -euo pipefail
    local node_count=1
    local vcpus_per_node=2          # Standard_B2s_v2 = 2 vCPUs
    local total_vcpus=$((node_count * vcpus_per_node))

    echo
    echo "Checking Standard_B-family vCPU quota in $AZURE_REGION (need $total_vcpus)..."

    local usage
    usage=$(az vm list-usage --location "$AZURE_REGION" \
        --query "[?contains(name.value,'standardBSFamily')].{current:currentValue, limit:limit}" \
        -o tsv 2>/dev/null || echo "")

    if [[ -z "$usage" ]]; then
        echo "  ⚠ Could not query Standard_B-family quota in $AZURE_REGION."
        echo "    Proceeding anyway — the apply step will surface quota errors if they exist."
        return 0
    fi

    local current limit
    current=$(echo "$usage" | awk '{print $1}')
    limit=$(echo "$usage"   | awk '{print $2}')
    local available=$((limit - current))

    if (( available < total_vcpus )); then
        echo "✗ Insufficient Standard_B-family quota in $AZURE_REGION."
        echo "  In use:    $current vCPUs"
        echo "  Limit:     $limit vCPUs"
        echo "  Available: $available vCPUs"
        echo "  Needed:    $total_vcpus vCPUs (1 × Standard_B2s_v2 = 2 vCPUs)"
        echo
        echo "  Request a quota increase here:"
        echo "  https://portal.azure.com/#view/Microsoft_Azure_Capacity/QuotaMenuBlade/~/myQuotas"
        echo "  Or pick a different region by re-running './uis platform init azure-aks'."
        exit 1
    fi
    echo "✓ Quota OK: $available vCPUs available in Standard_B family (need $total_vcpus)"
}

# register_providers — Q6. Blocking provider registration with annotated
# per-poll output (Q10). For each of the four required providers, register
# if not already, then poll until Registered or 10-minute timeout.
register_providers() {
    set -euo pipefail
    echo
    echo "Registering Azure resource providers (this can take 2-5 minutes)..."
    local providers=(
        "Microsoft.ContainerService"
        "Microsoft.Compute"
        "Microsoft.Network"
        "Microsoft.Storage"
    )
    local p
    for p in "${providers[@]}" ; do
        _register_one_provider "$p"
    done
    echo "✓ All providers Registered."
}

# Internal: register one provider, poll until Registered or timeout.
_register_one_provider() {
    local provider="$1"
    local state
    state=$(az provider show --namespace "$provider" --query registrationState -o tsv)
    if [[ "$state" == "Registered" ]]; then
        echo "  $provider: already Registered"
        return 0
    fi

    echo "  $provider: Registering..."
    az provider register --namespace "$provider" >/dev/null

    local start_ts elapsed
    start_ts=$(date +%s)
    while true ; do
        state=$(az provider show --namespace "$provider" --query registrationState -o tsv)
        elapsed=$(( $(date +%s) - start_ts ))
        if [[ "$state" == "Registered" ]]; then
            echo "  $provider: Registered (${elapsed}s)"
            return 0
        fi
        if (( elapsed > 600 )); then
            echo "  ✗ $provider: timed out after ${elapsed}s (state still: $state)"
            echo "    Check Azure Portal or contact your subscription admin."
            return 1
        fi
        echo "  $provider: $state... (${elapsed}s)"
        sleep 5
    done
}


# ============================================================
# Persist
# ============================================================

# write_env_atomically — Q3. Write .uis.secrets/cloud-accounts/azure-default.env
# atomically (tmp file + mv), populated from the discovered Azure values.
#
# Args:
#   $1 — absolute path to the target env file
#
# Required env vars (set by the discovery functions above):
#   AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID, AZURE_SUBSCRIPTION_NAME, AZURE_REGION
write_env_atomically() {
    set -euo pipefail
    local target="${1:-}"
    [[ -n "$target" ]] || { echo "✗ write_env_atomically called without a path"; exit 1; }

    : "${AZURE_TENANT_ID:?AZURE_TENANT_ID must be set}"
    : "${AZURE_SUBSCRIPTION_ID:?AZURE_SUBSCRIPTION_ID must be set}"
    : "${AZURE_SUBSCRIPTION_NAME:?AZURE_SUBSCRIPTION_NAME must be set}"
    : "${AZURE_REGION:?AZURE_REGION must be set}"

    # Derive the OpenTofu state storage account name from the subscription ID.
    # Azure storage account names must be 3-24 chars, lowercase alphanumeric only,
    # and globally unique. Stripping the sub-id UUID's hyphens and prefixing with
    # 'sa' / suffixing with 'tf' yields a 20-char name that's deterministic per
    # subscription (re-running init produces the same name → idempotent) and
    # globally unique by UUID construction.
    local stripped_sub="${AZURE_SUBSCRIPTION_ID//-/}"
    local AZURE_STATE_STORAGE_ACCOUNT="sa${stripped_sub:0:16}tf"

    mkdir -p "$(dirname "$target")"
    local tmp="${target}.tmp.$$"
    cat > "$tmp" <<EOF
# .uis.secrets/cloud-accounts/azure-default.env
#
# Written by uis platform init azure-aks on $(date -u +%Y-%m-%dT%H:%M:%SZ).
# Hand-edit OK — the wizard re-reads and re-prompts on next invocation.

# === Account identity ===
AZURE_TENANT_ID="$AZURE_TENANT_ID"
AZURE_SUBSCRIPTION_ID="$AZURE_SUBSCRIPTION_ID"
# Subscription display name (informational): $AZURE_SUBSCRIPTION_NAME

# === Default region ===
AZURE_REGION="$AZURE_REGION"

# === OpenTofu remote state ===
# Storage account name is derived from the subscription ID and must be globally
# unique within Azure. Override only if you already have a state account you
# want to reuse for this subscription.
AZURE_STATE_STORAGE_ACCOUNT="$AZURE_STATE_STORAGE_ACCOUNT"
EOF
    mv "$tmp" "$target"
    echo "✓ Wrote $target"
    echo "  Derived state storage account name: $AZURE_STATE_STORAGE_ACCOUNT"
}
