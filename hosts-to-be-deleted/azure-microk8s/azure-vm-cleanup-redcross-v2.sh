#!/bin/bash
# filename: azure-vm-cleanup-redcross-v2.sh
# description: Remove Azure resources created by 01-azure-vm-create-redcross-v2.sh
# usage: ./azure-vm-cleanup-redcross-v2.sh <vm_instance_name>
# 
# This script deletes all resources created by the 01-azure-vm-create-redcross-v2.sh script
# including resource groups, VMs, NICs, NSGs, and disks.

# Terminal colors for better visibility
BLUE='\033[0;34m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Check if the configuration file exists
CONFIG_FILE="./azure-vm-config-redcross-sandbox.sh"

# Initialize error tracking
ERROR=0
declare -A ERRORS

# Function to add error details to our tracking array
add_error() {
    local step=$1
    local error=$2
    ERRORS["$step"]="${ERRORS[$step]}${ERRORS[$step]:+$'\n'}$error"
}

# Function to prompt user to activate PIM role
pim_yourself() {
    echo -e "${YELLOW}IMPORTANT: You need the Contributor role on the Azure subscription to run this script.${NC}"
    echo -e "In Azure this is a ClickOps operation (the M$ guys did not grow up using a command line tool)"
    echo -e "To activate the Contributor role in Azure:"
    echo -e "  1) Search for PIM in the Azure portal search bar"
    echo -e "  2) Click on Microsoft Entra Privileged Identity Management"
    echo -e "  3) On the PIM page, click \"My roles\""
    echo -e "  4) Click \"Azure resources\""
    echo -e "  5) Click \"Activate\" next to the Contributor role"
    echo -e ""
    echo -e "Alternatively, click on this URL (Ctrl+Click in most terminals):"
    echo -e "${GREEN}https://portal.azure.com/?feature.msaljs=true#view/Microsoft_Azure_PIMCommon/ActivationMenuBlade/~/azurerbac${NC}"
    echo -e "Search for your resource, click on the name, and then click on the Contributor role."
    echo -e ""
    
    # Prompt user to press Enter after activating PIM
    read -p "After you have activated your Contributor role, press Enter to continue..."
    echo -e "${GREEN}Continuing with script execution...${NC}"
}

# Function to display step
display_step() {
    local step_number=$1
    local step_description=$2
    echo -e "\n${BLUE}=== STEP ${step_number}: ${step_description} ===${NC}"
}

# Function to display success
display_success() {
    local message=$1
    echo -e "${GREEN}✓ ${message}${NC}"
}

# Function to display error
display_error() {
    local message=$1
    echo -e "${RED}✗ ${message}${NC}"
    ERROR=1
}

# Function to display substep
display_substep() {
    local message=$1
    echo -e "${YELLOW}→ ${message}${NC}"
}

# Function to check if a command succeeds
check_command() {
    if [ $? -ne 0 ]; then
        display_error "$1 failed"
        return 1
    else
        display_success "$1 succeeded"
        return 0
    fi
}

# Function to check if a resource exists
resource_exists() {
    local resource_type=$1
    local resource_group=$2
    local resource_name=$3
    
    local exists=$(az $resource_type show --resource-group $resource_group --name $resource_name --query id -o tsv 2>/dev/null)
    if [ -n "$exists" ]; then
        return 0  # Resource exists
    else
        return 1  # Resource doesn't exist
    fi
}

# Function to print summary of operations
print_summary() {
    echo -e "\n${BLUE}===== Azure Resource Cleanup Summary =====${NC}"
    
    if [ ${#ERRORS[@]} -eq 0 ]; then
        echo -e "${GREEN}All cleanup operations completed successfully.${NC}"
    else
        echo -e "${RED}Errors occurred during cleanup:${NC}"
        for step in "${!ERRORS[@]}"; do
            echo -e "  ${RED}$step:${NC} ${ERRORS[$step]}"
        done
    fi
}

# Check if script is run with Bash
if [ -z "$BASH_VERSION" ]; then
    display_error "This script must be run with Bash"
    exit 1
fi

# Check if required parameter is provided
if [ $# -ne 1 ]; then
    display_error "Usage: $0 <vm_instance_name>"
    echo -e "${YELLOW}Example: $0 azure-microk8s${NC}"
    exit 1
fi

VM_INSTANCE=$1

# Check if the configuration file exists
if [ ! -f "$CONFIG_FILE" ]; then
    display_error "Configuration file $CONFIG_FILE not found in the current directory."
    echo "Please ensure you're running this script from the same directory as $CONFIG_FILE"
    exit 1
fi

# Source the configuration file
display_substep "Loading configuration from $CONFIG_FILE"
source "$CONFIG_FILE"
display_success "Configuration loaded"

# Generate resource names based on VM_INSTANCE
generate_resource_names

# Get Tailscale machine name from the original input parameter
TAILSCALE_MACHINE_NAME="$VM_INSTANCE"

# Display resource names that will be deleted
echo -e "${YELLOW}The following resources will be deleted:${NC}"
echo -e "  VM Instance Name: ${RED}$VM_INSTANCE_NAME${NC}"
echo -e "  Resource Group: ${RED}$RESOURCE_GROUP${NC}"
echo -e "  Network Interface: ${RED}$NIC_NAME${NC}"
echo -e "  Network Security Group: ${RED}$NSG_NAME${NC}"
echo -e "  OS Disk: ${RED}$OS_DISK_NAME${NC}"
echo -e "  Data Disk: ${RED}$DATA_DISK_NAME${NC}"

# Ask for confirmation
echo ""
read -p "Are you sure you want to delete these resources? (yes/no): " confirmation
if [[ $confirmation != "yes" ]]; then
    echo -e "${GREEN}Deletion cancelled.${NC}"
    exit 0
fi

# Prompt user to activate PIM role
display_step "1" "Activating Privileged Identity Management (PIM) role"
pim_yourself

# Set Azure CLI login experience and login
display_step "2" "Setting up Azure CLI and login"
display_substep "Setting Azure CLI login experience"
az config set core.login_experience_v2=off
check_command "Setting Azure CLI login experience"

# Azure Login
display_substep "Initiating Azure login with device code authentication"
echo -e "${YELLOW}Please follow these steps to log in:${NC}"
echo -e "  1. Open a web browser and go to: ${GREEN}https://microsoft.com/devicelogin${NC}"
echo -e "  2. Enter the code that will be displayed below"
echo -e "  3. Follow the prompts to complete the login process"

# Run the login command
az login --tenant $TENANT_ID --use-device-code
if [ $? -ne 0 ]; then
    display_error "Azure login failed"
    exit 1
fi
display_success "Azure login successful"

# Set Subscription
display_substep "Setting Azure subscription to $SUBSCRIPTION_ID"
az account set --subscription $SUBSCRIPTION_ID
check_command "Setting Azure subscription"

# Check if VM exists before trying to delete
display_step "3" "Checking for resource existence"
display_substep "Checking if VM exists: $VM_INSTANCE_NAME"

VM_EXISTS=false
if resource_exists "vm" "$RESOURCE_GROUP" "$VM_INSTANCE_NAME"; then
    display_success "VM $VM_INSTANCE_NAME found - will be deleted"
    VM_EXISTS=true
else
    display_substep "VM $VM_INSTANCE_NAME not found - will skip VM deletion"
fi

# Delete resources
display_step "4" "Deleting Azure resources"

# If resources exist in a specific group, we can delete the entire group
display_substep "Checking if we should delete resource group $RESOURCE_GROUP"
RG_DELETION_SAFE=false

# If this is a dedicated resource group for this VM (check by listing VMs in the group)
VM_COUNT=$(az vm list --resource-group $RESOURCE_GROUP --query "length(@)" -o tsv)
if [ "$VM_COUNT" -eq "1" ]; then
    # Only one VM in the resource group, it's safe to delete the whole group
    if [ "$VM_EXISTS" = true ]; then
        display_substep "Only one VM exists in resource group $RESOURCE_GROUP - safe to delete entire group"
        RG_DELETION_SAFE=true
    fi
elif [ "$VM_COUNT" -eq "0" ]; then
    display_substep "No VMs found in resource group $RESOURCE_GROUP - checking other resources"
    # No VMs, but check if other important resources exist
    OTHER_RESOURCES=$(az resource list --resource-group $RESOURCE_GROUP --query "length(@)" -o tsv)
    if [ "$OTHER_RESOURCES" -eq "0" ]; then
        display_substep "Resource group $RESOURCE_GROUP is empty - will delete it"
        RG_DELETION_SAFE=true
    else
        display_substep "Resource group $RESOURCE_GROUP contains $OTHER_RESOURCES resources - will delete specific resources only"
    fi
else
    display_substep "Multiple VMs ($VM_COUNT) found in resource group $RESOURCE_GROUP - will delete specific resources only"
fi

if [ "$RG_DELETION_SAFE" = true ]; then
    # Delete the entire resource group
    display_substep "Deleting entire resource group: $RESOURCE_GROUP"
    
    # Run the deletion command and capture both stdout and stderr
    DELETION_OUTPUT=$(az group delete --name $RESOURCE_GROUP --yes --no-wait 2>&1)
    DELETION_STATUS=$?
    
    # Check for authorization errors specifically
    if [[ "$DELETION_STATUS" -ne 0 ]]; then
        if [[ "$DELETION_OUTPUT" == *"AuthorizationFailed"* ]]; then
            display_error "Authorization failed to delete resource group. Your PIM role may not have sufficient permissions."
            display_substep "You may need to request elevated permissions or delete individual resources instead."
            add_error "Resource Group Deletion" "Authorization failed to delete resource group"
            
            # Ask if the user wants to try deleting individual resources instead
            echo ""
            read -p "Would you like to try deleting individual resources instead? (yes/no): " delete_individual
            if [[ $delete_individual != "yes" ]]; then
                print_summary
                exit 1
            else
                display_substep "Proceeding to delete individual resources..."
                RG_DELETION_SAFE=false
            fi
        else
            # Some other error occurred
            display_error "Failed to delete resource group: $DELETION_OUTPUT"
            add_error "Resource Group Deletion" "Failed to delete resource group: $DELETION_OUTPUT"
            print_summary
            exit 1
        fi
    else
        display_success "Resource group deletion initiated"
        
        echo -e "${GREEN}Resource deletion initiated.${NC}"
        echo -e "${YELLOW}Note: Resource group deletion happens asynchronously and may take several minutes to complete.${NC}"
        
        # Ask if the user wants to wait for deletion to complete
        echo ""
        read -p "Would you like this script to wait and confirm complete deletion? (yes/no): " wait_for_deletion
        if [[ $wait_for_deletion == "yes" ]]; then
            display_substep "Waiting for resource group deletion to complete (this may take 5-10 minutes)..."
            
            # Initialize variables for the wait loop
            max_attempts=20
            wait_time=30
            attempt=1
            
            while [ $attempt -le $max_attempts ]; do
                # Check if resource group exists
                RG_STATUS=$(az group show --name $RESOURCE_GROUP --query "properties.provisioningState" -o tsv 2>/dev/null)
                RG_EXISTS=$?
                
                if [ $RG_EXISTS -ne 0 ]; then
                    display_success "Resource group $RESOURCE_GROUP has been successfully deleted!"
                    break
                fi
                
                # Check if we're in a "Deleting" state
                if [[ "$RG_STATUS" == "Deleting" ]]; then
                    display_substep "Attempt $attempt/$max_attempts: Resource group is in state: Deleting. Waiting ${wait_time}s..."
                else
                    # If we're not in "Deleting" state, something may be wrong
                    display_substep "Attempt $attempt/$max_attempts: Resource group is in state: $RG_STATUS. Waiting ${wait_time}s..."
                    
                    # After a few attempts, if we're still not in "Deleting" state, warn the user
                    if [ $attempt -gt 3 ] && [[ "$RG_STATUS" != "Deleting" ]]; then
                        display_error "Resource group is not in 'Deleting' state after multiple attempts."
                        display_substep "The deletion may have failed. Please check the Azure portal."
                        
                        # Ask if the user wants to continue waiting
                        echo ""
                        read -p "Continue waiting? (yes/no): " continue_waiting
                        if [[ $continue_waiting != "yes" ]]; then
                            display_substep "Aborting wait. The resource group may still be deleted eventually."
                            break
                        fi
                    fi
                fi
                
                sleep $wait_time
                ((attempt++))
            done
            
            # If we've exhausted all attempts and the resource group still exists
            if [ $attempt -gt $max_attempts ]; then
                display_error "Resource group deletion is taking longer than expected or may have failed."
                display_substep "You can check the status later with: az group show --name $RESOURCE_GROUP"
                add_error "Resource Group Deletion" "Timeout waiting for deletion"
            fi
        fi
    fi
fi

# Handle individual resource deletion if needed
if [ "$RG_DELETION_SAFE" != true ]; then
    # Delete individual resources
    if [ "$VM_EXISTS" = true ]; then
        # Delete VM
        display_substep "Deleting VM: $VM_INSTANCE_NAME"
        VM_DEL_OUTPUT=$(az vm delete --resource-group $RESOURCE_GROUP --name $VM_INSTANCE_NAME --yes 2>&1)
        VM_DEL_STATUS=$?
        
        if [ $VM_DEL_STATUS -ne 0 ]; then
            if [[ "$VM_DEL_OUTPUT" == *"AuthorizationFailed"* ]]; then
                display_error "Authorization failed to delete VM. Your PIM role may not have sufficient permissions."
                add_error "VM Deletion" "Authorization failed to delete VM"
            else
                display_error "Failed to delete VM: $VM_DEL_OUTPUT"
                add_error "VM Deletion" "Failed to delete VM: $VM_DEL_OUTPUT"
            fi
        else
            display_success "Deleting VM"
        fi
    fi

    # Delete Network Interface
    display_substep "Checking for Network Interface: $NIC_NAME"
    if resource_exists "network nic" "$RESOURCE_GROUP" "$NIC_NAME"; then
        display_substep "Deleting Network Interface: $NIC_NAME"
        NIC_DEL_OUTPUT=$(az network nic delete --resource-group $RESOURCE_GROUP --name $NIC_NAME 2>&1)
        NIC_DEL_STATUS=$?
        
        if [ $NIC_DEL_STATUS -ne 0 ]; then
            if [[ "$NIC_DEL_OUTPUT" == *"AuthorizationFailed"* ]]; then
                display_error "Authorization failed to delete Network Interface."
                add_error "Network Interface Deletion" "Authorization failed"
            else
                display_error "Failed to delete Network Interface: $NIC_DEL_OUTPUT"
                add_error "Network Interface Deletion" "Failed: $NIC_DEL_OUTPUT"
            fi
        else
            display_success "Deleting Network Interface"
        fi
    else
        display_substep "Network Interface $NIC_NAME not found - skipping"
    fi

    # Delete Network Security Group
    display_substep "Checking for Network Security Group: $NSG_NAME"
    if resource_exists "network nsg" "$RESOURCE_GROUP" "$NSG_NAME"; then
        display_substep "Deleting Network Security Group: $NSG_NAME"
        NSG_DEL_OUTPUT=$(az network nsg delete --resource-group $RESOURCE_GROUP --name $NSG_NAME 2>&1)
        NSG_DEL_STATUS=$?
        
        if [ $NSG_DEL_STATUS -ne 0 ]; then
            if [[ "$NSG_DEL_OUTPUT" == *"AuthorizationFailed"* ]]; then
                display_error "Authorization failed to delete Network Security Group."
                add_error "NSG Deletion" "Authorization failed"
            else
                display_error "Failed to delete Network Security Group: $NSG_DEL_OUTPUT"
                add_error "NSG Deletion" "Failed: $NSG_DEL_OUTPUT"
            fi
        else
            display_success "Deleting Network Security Group"
        fi
    else
        display_substep "Network Security Group $NSG_NAME not found - skipping"
    fi

    # Delete OS Disk
    display_substep "Checking for OS Disk: $OS_DISK_NAME"
    if resource_exists "disk" "$RESOURCE_GROUP" "$OS_DISK_NAME"; then
        display_substep "Deleting OS Disk: $OS_DISK_NAME"
        OS_DISK_DEL_OUTPUT=$(az disk delete --resource-group $RESOURCE_GROUP --name $OS_DISK_NAME --yes 2>&1)
        OS_DISK_DEL_STATUS=$?
        
        if [ $OS_DISK_DEL_STATUS -ne 0 ]; then
            if [[ "$OS_DISK_DEL_OUTPUT" == *"AuthorizationFailed"* ]]; then
                display_error "Authorization failed to delete OS Disk."
                add_error "OS Disk Deletion" "Authorization failed"
            else
                display_error "Failed to delete OS Disk: $OS_DISK_DEL_OUTPUT"
                add_error "OS Disk Deletion" "Failed: $OS_DISK_DEL_OUTPUT"
            fi
        else
            display_success "Deleting OS Disk"
        fi
    else
        display_substep "OS Disk $OS_DISK_NAME not found - skipping"
    fi

    # Delete Data Disk
    display_substep "Checking for Data Disk: $DATA_DISK_NAME"
    if resource_exists "disk" "$RESOURCE_GROUP" "$DATA_DISK_NAME"; then
        display_substep "Deleting Data Disk: $DATA_DISK_NAME"
        DATA_DISK_DEL_OUTPUT=$(az disk delete --resource-group $RESOURCE_GROUP --name $DATA_DISK_NAME --yes 2>&1)
        DATA_DISK_DEL_STATUS=$?
        
        if [ $DATA_DISK_DEL_STATUS -ne 0 ]; then
            if [[ "$DATA_DISK_DEL_OUTPUT" == *"AuthorizationFailed"* ]]; then
                display_error "Authorization failed to delete Data Disk."
                add_error "Data Disk Deletion" "Authorization failed"
            else
                display_error "Failed to delete Data Disk: $DATA_DISK_DEL_OUTPUT"
                add_error "Data Disk Deletion" "Failed: $DATA_DISK_DEL_OUTPUT"
            fi
        else
            display_success "Deleting Data Disk"
        fi
    else
        display_substep "Data Disk $DATA_DISK_NAME not found - skipping"
    fi
fi

# Delete local info file if it exists
if [ -f "azure-microk8s.sh" ]; then
    display_substep "Deleting local info file: azure-microk8s.sh"
    rm -f azure-microk8s.sh
    check_command "Deleting local info file"
fi

display_step "5" "Cleanup complete"
print_summary

echo -e "${GREEN}Azure resources cleanup completed!${NC}"

# Remind about the asynchronous nature of Azure resource deletion
if [ "$RG_DELETION_SAFE" = true ] && [[ $wait_for_deletion != "yes" ]]; then
    echo -e "${YELLOW}Remember: Azure resource group deletion is asynchronous and may take 5-15 minutes to complete fully.${NC}"
    echo -e "To verify complete deletion later, run: ${GREEN}az group show --name $RESOURCE_GROUP${NC}"
    echo -e "When deletion is complete, you'll see: ${RED}(ResourceGroupNotFound) Resource group '$RESOURCE_GROUP' could not be found.${NC}"
fi

echo -e "${YELLOW}Don't forget to manually delete the host from tailscale network if needed.${NC}"
echo -e "Go to https://login.tailscale.com/admin/machines and delete the machine named: $TAILSCALE_MACHINE_NAME"

exit $ERROR