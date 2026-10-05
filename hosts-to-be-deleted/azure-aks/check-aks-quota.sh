#!/bin/bash
# filename: check-aks-quota.sh
# description: Validates Azure quota availability before AKS cluster creation
# usage: ./check-aks-quota.sh
# returns: 0 if quota is sufficient, 1 if insufficient

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Auto-source configuration file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/azure-aks-config.sh"

if [ -f "$CONFIG_FILE" ]; then
    echo -e "${BLUE}Loading configuration from $CONFIG_FILE${NC}"
    source "$CONFIG_FILE"
else
    echo -e "${RED}ERROR: Configuration file not found: $CONFIG_FILE${NC}"
    echo "Expected file: azure-aks-config.sh in the same directory"
    exit 1
fi

# Verify required variables are set
if [ -z "$NODE_COUNT" ] || [ -z "$NODE_SIZE" ] || [ -z "$LOCATION" ]; then
    echo -e "${RED}ERROR: Required variables not set in configuration file.${NC}"
    echo "Required: NODE_COUNT, NODE_SIZE, LOCATION"
    echo "Check: $CONFIG_FILE"
    exit 1
fi

# Function to display error and exit
quota_error() {
    local message="$1"
    echo -e "${RED}❌ QUOTA CHECK FAILED: $message${NC}"
    echo -e "${YELLOW}Solutions:${NC}"
    echo "  1. Reduce node count: export NODE_COUNT=1"
    echo "  2. Use smaller VMs: export NODE_SIZE=\"Standard_B1ms\""
    echo "  3. Delete unused resources in region: $LOCATION"
    echo "  4. Request quota increase: https://learn.microsoft.com/en-us/azure/quotas/view-quotas"
    exit 1
}

# Function to display success
quota_success() {
    local message="$1"
    echo -e "${GREEN}✅ $message${NC}"
}

# Calculate vCPUs needed based on VM size
calculate_vcpus_per_node() {
    case "$NODE_SIZE" in
        "Standard_B1ms")
            echo 1
            ;;
        "Standard_B2ms")
            echo 2
            ;;
        "Standard_B4ms")
            echo 4
            ;;
        "Standard_D2as_v6")
            echo 2
            ;;
        "Standard_D4as_v6")
            echo 4
            ;;
        *)
            echo -e "${YELLOW}WARNING: Unknown VM size $NODE_SIZE, assuming 2 vCPUs${NC}"
            echo 2
            ;;
    esac
}

# Get VM family name for quota check
get_vm_family() {
    case "$NODE_SIZE" in
        "Standard_B"*"ms")
            echo "standardBSFamily"
            ;;
        "Standard_D"*"as_v6")
            echo "standardDav6Family"
            ;;
        *)
            echo -e "${YELLOW}WARNING: Unknown VM family for $NODE_SIZE${NC}"
            echo "unknown"
            ;;
    esac
}

echo -e "${BLUE}=== AZURE AKS QUOTA VALIDATION ===${NC}"
echo "Checking quota availability for AKS cluster creation..."

# Calculate requirements
VCPUS_PER_NODE=$(calculate_vcpus_per_node)
TOTAL_VCPUS_NEEDED=$((NODE_COUNT * VCPUS_PER_NODE))
VM_FAMILY=$(get_vm_family)

echo -e "${BLUE}Planned AKS cluster requirements:${NC}"
echo "- Node count: $NODE_COUNT"
echo "- VM size: $NODE_SIZE"
echo "- vCPUs per node: $VCPUS_PER_NODE"
echo "- Total vCPUs needed: $TOTAL_VCPUS_NEEDED"
echo "- VM family: $VM_FAMILY"

# Check if we can get quota information
echo -e "${BLUE}Fetching quota information...${NC}"
if ! az vm list-usage --location "$LOCATION" >/dev/null 2>&1; then
    echo -e "${RED}ERROR: Cannot fetch quota information. Check Azure CLI login and permissions.${NC}"
    exit 1
fi

# Check VM family specific quota (if we know the family)
if [ "$VM_FAMILY" != "unknown" ]; then
    echo -e "${BLUE}Checking VM family quota ($VM_FAMILY)...${NC}"
    
    FAMILY_CURRENT=$(az vm list-usage --location "$LOCATION" \
        --query "[?contains(name.value,'$VM_FAMILY')].currentValue" -o tsv)
    FAMILY_LIMIT=$(az vm list-usage --location "$LOCATION" \
        --query "[?contains(name.value,'$VM_FAMILY')].limit" -o tsv)
    
    if [ -z "$FAMILY_CURRENT" ] || [ -z "$FAMILY_LIMIT" ]; then
        echo -e "${YELLOW}WARNING: Could not fetch family-specific quota for $VM_FAMILY${NC}"
        echo "Proceeding with total regional quota check only..."
    else
        FAMILY_AVAILABLE=$((FAMILY_LIMIT - FAMILY_CURRENT))
        
        echo "- Current usage: $FAMILY_CURRENT vCPUs"
        echo "- Limit: $FAMILY_LIMIT vCPUs"
        echo "- Available: $FAMILY_AVAILABLE vCPUs"
        echo "- Required: $TOTAL_VCPUS_NEEDED vCPUs"
        
        if [ "$FAMILY_AVAILABLE" -ge "$TOTAL_VCPUS_NEEDED" ]; then
            quota_success "VM family quota sufficient"
        else
            quota_error "VM family quota insufficient ($FAMILY_AVAILABLE available, $TOTAL_VCPUS_NEEDED needed)"
        fi
    fi
fi

# Check total regional quota
echo -e "${BLUE}Checking total regional vCPU quota...${NC}"

TOTAL_CURRENT=$(az vm list-usage --location "$LOCATION" \
    --query "[?name.value=='cores'].currentValue" -o tsv)
TOTAL_LIMIT=$(az vm list-usage --location "$LOCATION" \
    --query "[?name.value=='cores'].limit" -o tsv)

if [ -z "$TOTAL_CURRENT" ] || [ -z "$TOTAL_LIMIT" ]; then
    echo -e "${RED}ERROR: Cannot fetch total regional quota information${NC}"
    exit 1
fi

TOTAL_AVAILABLE=$((TOTAL_LIMIT - TOTAL_CURRENT))

echo "- Current usage: $TOTAL_CURRENT vCPUs"
echo "- Limit: $TOTAL_LIMIT vCPUs"
echo "- Available: $TOTAL_AVAILABLE vCPUs"
echo "- Required: $TOTAL_VCPUS_NEEDED vCPUs"

if [ "$TOTAL_AVAILABLE" -ge "$TOTAL_VCPUS_NEEDED" ]; then
    quota_success "Total regional quota sufficient"
else
    quota_error "Total regional quota insufficient ($TOTAL_AVAILABLE available, $TOTAL_VCPUS_NEEDED needed)"
fi

# Check for existing resources that might conflict
echo -e "${BLUE}Checking for existing resources in region...${NC}"

EXISTING_VMS=$(az vm list --query "[?location=='$LOCATION']" -o tsv 2>/dev/null | wc -l)
if [ "$EXISTING_VMS" -gt 0 ]; then
    echo -e "${YELLOW}Found $EXISTING_VMS existing VMs in region $LOCATION${NC}"
    echo "Run this command to see details:"
    echo "az vm list --query \"[?location=='$LOCATION'].{Name:name,Size:hardwareProfile.vmSize,State:powerState,ResourceGroup:resourceGroup}\" -o table"
fi

# Final validation summary
echo -e "${GREEN}=== QUOTA VALIDATION PASSED ===${NC}"
echo -e "${GREEN}✅ Sufficient quota available for AKS cluster${NC}"
echo -e "${GREEN}✅ Safe to proceed with cluster creation${NC}"
echo -e "${GREEN}====================================${NC}"

exit 0