#!/bin/bash

# File: hosts/azure-aks/01-azure-aks-create.sh
#
# Description:
# Creates Azure AKS cluster with PIM activation and proper configuration
# Based on validated steps from steps-plan.md
#
# Prerequisites:
# - Azure CLI installed (available in provision-host)
# - Azure subscription access with Contributor role
#
# Usage:
# ./01-azure-aks-create.sh

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Functions for colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}


# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/azure-aks-config.sh"

if [[ ! -f "$CONFIG_FILE" ]]; then
    print_error "Configuration file not found: $CONFIG_FILE"
    exit 1
fi

print_status "Loading configuration from azure-aks-config.sh..."
source "$CONFIG_FILE"

# Function to check and prompt for PIM activation (based on azure-microk8s pattern)
check_pim_activation() {
    print_status "Checking for Contributor role..."
    
    # First check if user already has Contributor role
    if az role assignment list --scope "/subscriptions/$SUBSCRIPTION_ID" --query "[?roleDefinitionName=='Contributor' && principalType=='User']" -o tsv 2>/dev/null | grep -q .; then
        print_success "Contributor role is already active"
        return 0
    fi
    
    # User doesn't have Contributor role
    print_warning "Contributor role not detected"
    
    echo
    echo "To activate the Contributor role in Azure:"
    echo "1. Click: https://portal.azure.com/?feature.msaljs=true#view/Microsoft_Azure_PIMCommon/ActivationMenuBlade/~/azurerbac"
    echo "2. Find and activate 'Contributor' role for subscription: $SUBSCRIPTION_ID"
    echo "3. Wait 1-2 minutes for activation"
    echo
    
    # Loop until user has Contributor role or gives up
    local MAX_ATTEMPTS=3
    for attempt in $(seq 1 $MAX_ATTEMPTS); do
        read -p "After activating your Contributor role, press Enter to verify permissions..."
        
        print_status "Verifying Contributor role activation..."
        if az role assignment list --scope "/subscriptions/$SUBSCRIPTION_ID" --query "[?roleDefinitionName=='Contributor' && principalType=='User']" -o tsv 2>/dev/null | grep -q .; then
            print_success "Contributor role successfully activated"
            return 0
        else
            if [ $attempt -lt $MAX_ATTEMPTS ]; then
                print_warning "Contributor role not detected. Please make sure you completed the activation process."
                echo "Attempt $attempt of $MAX_ATTEMPTS. Please try again."
            else
                print_error "Contributor role not detected after $MAX_ATTEMPTS attempts."
                print_error "This script requires Contributor role to run successfully."
                return 1
            fi
        fi
    done
    
    return 1
}

# Function to wait for operation with status updates
wait_for_operation() {
    local message="$1"
    local check_command="$2"
    local max_attempts="${3:-60}"
    local delay="${4:-5}"
    
    echo -n "$message"
    local attempts=0
    
    while [[ $attempts -lt $max_attempts ]]; do
        if eval "$check_command" >/dev/null 2>&1; then
            echo " ✅"
            return 0
        fi
        echo -n "."
        sleep $delay
        ((attempts++))
    done
    
    echo " ❌"
    return 1
}

# Main cluster creation flow
main() {
    print_status "Starting Azure AKS cluster creation..."
    
    # Step 1: Azure login
    print_status "Checking Azure login status..."
    if ! az account show >/dev/null 2>&1; then
        print_warning "Not logged in to Azure. Starting login process..."
        az login --tenant "$TENANT_ID" --use-device-code
    fi
    
    # Step 2: Set subscription to configured one (unattended)
    print_status "Setting subscription to $SUBSCRIPTION_ID..."
    az account set --subscription "$SUBSCRIPTION_ID"
    
    # Show current subscription
    CURRENT_SUB=$(az account show --query name -o tsv)
    print_success "Using subscription: $CURRENT_SUB"
    
    # Step 3: Check PIM activation
    if ! check_pim_activation; then
        print_error "Cannot proceed without Contributor role"
        exit 1
    fi
    
    # Step 4: Check quota
    print_status "Checking Azure quota availability..."
    if [[ -f "$SCRIPT_DIR/check-aks-quota.sh" ]]; then
        if ! "$SCRIPT_DIR/check-aks-quota.sh"; then
            print_error "Quota check failed. Please resolve quota issues before continuing."
            exit 1
        fi
    else
        print_warning "Quota check script not found, skipping quota validation"
    fi
    
    # Step 5: Create resource group
    print_status "Checking resource group: $RESOURCE_GROUP..."
    if az group show --name "$RESOURCE_GROUP" >/dev/null 2>&1; then
        print_success "Resource group already exists: $RESOURCE_GROUP"
    else
        print_status "Creating resource group: $RESOURCE_GROUP..."
        az group create \
            --name "$RESOURCE_GROUP" \
            --location "$LOCATION" \
            --tags $TAGS
        print_success "Resource group created"
    fi
    
    # Step 6: Check if cluster already exists
    print_status "Checking for existing cluster: $CLUSTER_NAME..."
    if az aks show --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" >/dev/null 2>&1; then
        print_success "Cluster already exists: $CLUSTER_NAME"
        print_success "Cluster creation completed (cluster already exists)"
        return 0
    fi
    
    
    # Step 7: Create AKS cluster
    print_status "Creating AKS cluster: $CLUSTER_NAME..."
    print_status "This will take 5-10 minutes..."
    
    az aks create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$CLUSTER_NAME" \
        --node-count "$NODE_COUNT" \
        --node-vm-size "$NODE_SIZE" \
        --location "$LOCATION" \
        --network-plugin azure \
        --network-policy azure \
        --generate-ssh-keys \
        --enable-managed-identity \
        --enable-cluster-autoscaler \
        --min-count 1 \
        --max-count 3 \
        --enable-addons monitoring \
        --tier free \
        --node-osdisk-size 30 \
        --tags $TAGS
    
    print_success "AKS cluster created successfully"
    
    # Step 8: Get cluster credentials
    print_status "Getting cluster credentials..."
    az aks get-credentials \
        --resource-group "$RESOURCE_GROUP" \
        --name "$CLUSTER_NAME" \
        --file "$KUBECONFIG_FILE" \
        --overwrite-existing
    
    print_success "Cluster credentials saved to: $KUBECONFIG_FILE"
    
    # Step 9: Verify cluster access
    print_status "Verifying cluster access..."
    export KUBECONFIG="$KUBECONFIG_FILE"
    
    if kubectl get nodes >/dev/null 2>&1; then
        print_success "✅ Cluster is accessible via kubectl"
        echo
        kubectl get nodes
    else
        print_error "❌ Cannot access cluster with kubectl"
        exit 1
    fi
    
    print_success "Azure AKS cluster creation completed!"
    echo
    echo "Cluster Details:"
    echo "================"
    echo "Resource Group: $RESOURCE_GROUP"
    echo "Cluster Name: $CLUSTER_NAME"
    echo "Location: $LOCATION"
    echo "Node Count: $NODE_COUNT"
    echo "Node Size: $NODE_SIZE"
    echo "Kubeconfig: $KUBECONFIG_FILE"
    echo
}

# Run main function
main "$@"