#!/bin/bash
# filename: 01-azure-vm-create-redcross-v2.sh
# description: Create an Azure VM in an empty sandbox environment with all required resources
# usage: ./01-azure-vm-create-redcross-v2.sh <admin_username> <admin_password> <vm_instance_name>
# To be run on provision-host VM

# Initialize associative arrays for status and errors
declare -A STATUS
declare -A ERRORS
ERROR=0  # Global error tracker

# Source centralized path library for backwards-compatible path resolution
if [[ -f "/mnt/urbalurbadisk/provision-host/uis/lib/paths.sh" ]]; then
    source "/mnt/urbalurbadisk/provision-host/uis/lib/paths.sh"
    SSH_KEY_DIR=$(get_ssh_key_path)
    ANSIBLE_KEY_PATH="$SSH_KEY_DIR/id_rsa_ansible"
else
    # Fallback to old hardcoded path
    ANSIBLE_KEY_PATH="/mnt/urbalurbadisk/secrets/id_rsa_ansible"
fi
CONFIG_FILE="./azure-vm-config-redcross-sandbox.sh"
CLUSTER_NAME="azure-microk8s"
CLOUD_INIT_FILE="/mnt/urbalurbadisk/cloud-init/azure-cloud-init.yml"

# Terminal colors for better visibility
BLUE='\033[0;34m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Function to prompt user to activate PIM role and verify permissions
pim_yourself() {
    echo -e "${YELLOW}IMPORTANT: You need the Contributor role on the Azure subscription to run this script.${NC}"
    
    # First check if user already has Contributor role
    echo -e "Checking current permissions..."
    if az role assignment list --scope "/subscriptions/$SUBSCRIPTION_ID" --query "[?roleDefinitionName=='Contributor' && principalType=='User']" -o tsv 2>/dev/null | grep -q .; then
        echo -e "${GREEN}✓ You already have the Contributor role activated. Proceeding with script.${NC}"
        return 0
    fi
    
    # User doesn't have Contributor role, prompt for PIM activation
    echo -e "${RED}× You do NOT currently have the Contributor role needed for this script.${NC}"
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
    
    # Loop until user has Contributor role or gives up
    MAX_ATTEMPTS=3
    for attempt in $(seq 1 $MAX_ATTEMPTS); do
        # Prompt user to press Enter after activating PIM
        read -p "After you have activated your Contributor role, press Enter to verify permissions..."
        
        # Check if user now has Contributor role
        echo -e "Verifying Contributor role activation..."
        if az role assignment list --scope "/subscriptions/$SUBSCRIPTION_ID" --query "[?roleDefinitionName=='Contributor' && principalType=='User']" -o tsv 2>/dev/null | grep -q .; then
            echo -e "${GREEN}✓ Contributor role successfully activated.${NC}"
            return 0
        else
            if [ $attempt -lt $MAX_ATTEMPTS ]; then
                echo -e "${RED}× Contributor role not detected. Please make sure you completed the activation process.${NC}"
                echo -e "Attempt $attempt of $MAX_ATTEMPTS. Please try again."
            else
                echo -e "${RED}× Contributor role not detected after $MAX_ATTEMPTS attempts.${NC}"
                echo -e "${RED}This script requires Contributor role to run successfully.${NC}"
                return 1
            fi
        fi
    done
    
    # If we get here, all attempts failed
    return 1
}

# Function to display steps clearly
display_step() {
    local step_number=$1
    local step_name=$2
    echo -e "\n${BLUE}=== STEP ${step_number}: ${step_name} ===${NC}"
}

# Function to display substeps
display_substep() {
    local substep_name=$1
    echo -e "${YELLOW}  → ${substep_name}${NC}"
}

# Function to display success message
display_success() {
    local message=$1
    echo -e "${GREEN}  ✓ ${message}${NC}"
}

# Function to display error message
display_error() {
    local message=$1
    echo -e "${RED}  ✗ ${message}${NC}"
}

# Function to add status
add_status() {
    local component=$1
    local step=$2
    local status=$3
    STATUS["$component|$step"]=$status
}

# Function to add error
add_error() {
    local component=$1
    local error=$2
    ERRORS["$component"]="${ERRORS[$component]}${ERRORS[$component]:+$'\n'}$error"
    ERROR=1
    display_error "[$component] $error"
}

# Function to check if a file exists
check_file_exists() {
    local file=$1
    local component=$2
    
    display_substep "Checking if $file exists"
    if [ ! -f "$file" ]; then
        add_error "$component" "File $file not found."
        return 1
    fi
    display_success "File $file found"
    return 0
}

# Function to check command success
check_command_success() {
    local component=$1
    local step=$2
    local output=$3
    
    if [ $? -ne 0 ]; then
        add_error "$component" "$step failed. Output: $output"
        return 1
    else
        add_status "$component" "$step" "OK"
        display_success "$component: $step"
        return 0
    fi
}

# Function to run command and capture output
run_command() {
    local component=$1
    local step=$2
    local command=$3
    
    display_substep "Running: $step"
    OUTPUT=$(eval "$command" 2>&1)
    if ! check_command_success "$component" "$step" "$OUTPUT"; then
        echo -e "${RED}Command output:${NC}\n$OUTPUT"
        return 1
    fi
    return 0
}

# Function to run command on VM and display output
run_command_on_vm() {
    local component="VM Command"
    local description="$1"
    local command="$2"
    
    display_substep "Running on VM: $description"
    OUTPUT=$(az vm run-command invoke \
      --resource-group $RESOURCE_GROUP \
      --name $VM_INSTANCE_NAME \
      --command-id RunShellScript \
      --scripts "$command" \
      --query 'value[0].message' \
      --output tsv 2>&1)
    
    if ! check_command_success "$component" "$description" "$OUTPUT"; then
        echo -e "${RED}Command output:${NC}\n$OUTPUT"
        return 1
    fi
    echo "$OUTPUT"
    return 0
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

# Function to create a resource group if it doesn't exist
create_resource_group_if_not_exists() {
    local rg_name=$1
    local location=$2
    local tags=$3
    
    display_substep "Checking if Resource Group $rg_name exists"
    if resource_exists "group" "" "$rg_name"; then
        display_success "Resource Group $rg_name already exists"
    else
        display_substep "Creating Resource Group: $rg_name in $location"
        if ! run_command "Resource Group" "Create $rg_name" "az group create --name $rg_name --location $location --tags $tags"; then
            return 1
        fi
    fi
    return 0
}

# Function to create VNet if it doesn't exist
create_vnet_if_not_exists() {
    local rg_name=$1
    local vnet_name=$2
    local address_prefix=$3
    local location=$4
    local tags=$5
    
    display_substep "Checking if VNet $vnet_name exists"
    if resource_exists "network vnet" "$rg_name" "$vnet_name"; then
        display_success "VNet $vnet_name already exists"
    else
        display_substep "Creating VNet: $vnet_name with address space $address_prefix"
        if ! run_command "Network" "Create VNet" "az network vnet create --resource-group $rg_name --name $vnet_name --address-prefix $address_prefix --location $location --tags $tags"; then
            return 1
        fi
    fi
    return 0
}

# Function to create subnet if it doesn't exist
create_subnet_if_not_exists() {
    local rg_name=$1
    local vnet_name=$2
    local subnet_name=$3
    local address_prefix=$4
    
    display_substep "Checking if Subnet $subnet_name exists"
    if az network vnet subnet show --resource-group $rg_name --vnet-name $vnet_name --name $subnet_name --query id -o tsv 2>/dev/null; then
        display_success "Subnet $subnet_name already exists"
    else
        display_substep "Creating Subnet: $subnet_name with address prefix $address_prefix"
        if ! run_command "Network" "Create Subnet" "az network vnet subnet create --resource-group $rg_name --vnet-name $vnet_name --name $subnet_name --address-prefix $address_prefix"; then
            return 1
        fi
    fi
    return 0
}

# Function to create NSG if it doesn't exist
create_nsg_if_not_exists() {
    local rg_name=$1
    local nsg_name=$2
    local location=$3
    local tags=$4
    
    display_substep "Checking if NSG $nsg_name exists"
    if resource_exists "network nsg" "$rg_name" "$nsg_name"; then
        display_success "NSG $nsg_name already exists"
    else
        display_substep "Creating NSG: $nsg_name"
        if ! run_command "Network" "Create NSG" "az network nsg create --resource-group $rg_name --name $nsg_name --location $location --tags $tags"; then
            return 1
        fi
        
        # Note: No SSH rule is added as we're using Tailscale for secure access
        display_substep "Using Tailscale for secure access - no external SSH rule needed"
        add_status "Network" "SSH Access" "Secured via Tailscale"
    fi
    return 0
}

# Getting Tailscale IP with retries
get_tailscale_ip() {
    local component="Tailscale"
    local max_attempts=10
    local wait_time=30
    local long_wait_time=300

    display_substep "Getting Tailscale IP (may take multiple attempts)"
    
    for ((attempt=1; attempt<=$max_attempts; attempt++)); do
        display_substep "Attempt $attempt of $max_attempts to get Tailscale IP"
        
        TAILSCALE_IP=$(az vm run-command invoke \
          --resource-group $RESOURCE_GROUP \
          --name $VM_INSTANCE_NAME \
          --command-id RunShellScript \
          --scripts "tailscale ip -4" \
          --query 'value[0].message' \
          --output tsv 2>&1 | grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b')

        if [ -n "$TAILSCALE_IP" ]; then
            display_success "Successfully retrieved Tailscale IP: $TAILSCALE_IP"
            add_status "$component" "IP" "$TAILSCALE_IP"
            
            # Get Tailscale hostname - properly extract just the hostname
            TAILSCALE_HOSTNAME=$(az vm run-command invoke \
              --resource-group $RESOURCE_GROUP \
              --name $VM_INSTANCE_NAME \
              --command-id RunShellScript \
              --scripts "tailscale status | grep \"${TAILSCALE_IP}\" | awk '{print \$1}'" \
              --query 'value[0].message' \
              --output tsv 2>/dev/null)
            
            # Clean up the hostname - trim whitespace and remove any output text
            TAILSCALE_HOSTNAME=$(echo "$TAILSCALE_HOSTNAME" | tr -d '\r\n' | xargs)
            
            # Use the VM instance name as fallback if hostname can't be determined
            if [ -z "$TAILSCALE_HOSTNAME" ] || [[ "$TAILSCALE_HOSTNAME" == *"Enable succeeded"* ]]; then
                TAILSCALE_HOSTNAME="$VM_INSTANCE"
                display_substep "Using instance name as Tailscale hostname: $TAILSCALE_HOSTNAME"
            else
                display_success "Successfully retrieved Tailscale hostname: $TAILSCALE_HOSTNAME"
            fi
            
            add_status "$component" "Hostname" "$TAILSCALE_HOSTNAME"
            return 0
        else
            if [ $attempt -eq 5 ]; then
                display_substep "Fifth attempt failed. Waiting for $long_wait_time seconds..."
                sleep $long_wait_time
            else
                display_substep "Attempt failed. Waiting for $wait_time seconds before retrying..."
                sleep $wait_time
            fi
        fi
    done

    add_error "$component" "Failed to get Tailscale IP after $max_attempts attempts"
    return 1
}

# Function to check cloud-init status
check_cloud_init_status()  {
    display_substep "Checking if cloud-init has completed processing"
    
    # Check for the finish modules-final entry which indicates cloud-init has completed
    CLOUD_INIT_FINISH=$(az vm run-command invoke \
      --resource-group $RESOURCE_GROUP \
      --name $VM_INSTANCE_NAME \
      --command-id RunShellScript \
      --scripts "grep 'finish: modules-final' /var/log/cloud-init.log | tail -1" \
      --query 'value[0].message' \
      --output tsv 2>&1)
    
    # Check for authorization failures first
    if [[ "$CLOUD_INIT_FINISH" == *"AuthorizationFailed"* ]]; then
        display_error "Permission denied checking cloud-init logs - PIM role might not be active"
        display_substep "Continuing without cloud-init verification"
        add_status "Cloud-Init" "Completion Check" "Skipped - Permission denied"
        return 0  # Continue the script regardless
    fi
    
    # Check if we found the finish message
    if [[ "$CLOUD_INIT_FINISH" == *"finish: modules-final: SUCCESS"* ]]; then
        display_success "Cloud-init has completed all modules successfully"
        add_status "Cloud-Init" "Completion" "Successful"
        return 0
    elif [[ "$CLOUD_INIT_FINISH" == *"finish: modules-final"* ]]; then
        display_substep "Cloud-init has completed all modules with possible warnings"
        add_status "Cloud-Init" "Completion" "Completed with warnings"
        return 0
    fi
    
    # If we didn't find a finish message, check if MicroK8s is running
    display_substep "Unable to confirm cloud-init completion, checking MicroK8s status"
    MICROK8S_STATUS=$(az vm run-command invoke \
      --resource-group $RESOURCE_GROUP \
      --name $VM_INSTANCE_NAME \
      --command-id RunShellScript \
      --scripts "microk8s status | grep 'microk8s is running'" \
      --query 'value[0].message' \
      --output tsv 2>&1)
    
    if [[ "$MICROK8S_STATUS" == *"microk8s is running"* ]]; then
        display_success "MicroK8s is running - cloud-init has likely completed successfully"
        add_status "Cloud-Init" "Completion" "Likely successful (MicroK8s running)"
        return 0
    fi
    
    # If we get here, we couldn't confirm completion
    display_substep "Could not confirm cloud-init completion, continuing anyway"
    add_status "Cloud-Init" "Completion" "Unknown"
    return 0  # Continue the script anyway
}

# Print summary
print_summary() {
    echo -e "\n${BLUE}===== Azure VM Creation Summary =====${NC}"
    
    echo -e "${YELLOW}Component Status:${NC}"
    for key in "${!STATUS[@]}"; do
        IFS='|' read -r component step <<< "$key"
        echo -e "  ${GREEN}$component - $step:${NC} ${STATUS[$key]}"
    done
    
    if [ ${#ERRORS[@]} -eq 0 ]; then
        echo -e "\n${GREEN}VM creation completed successfully.${NC}"
        echo -e "  Virtual Machine: ${YELLOW}$VM_INSTANCE_NAME${NC}"
        echo -e "  Resource Group: ${YELLOW}$RESOURCE_GROUP${NC}"
        echo -e "  Tailscale IP: ${YELLOW}$TAILSCALE_IP${NC}"
        if [ -n "${STATUS[Tailscale|Hostname]}" ]; then
            echo -e "  Tailscale Hostname: ${YELLOW}${STATUS[Tailscale|Hostname]}${NC}"
        fi
        echo -e "\n${GREEN}To SSH to the VM, use:${NC}"
        echo -e "  ${YELLOW}ssh -i $ANSIBLE_KEY_PATH ansible@$TAILSCALE_IP${NC}"
    else
        echo -e "\n${RED}Errors occurred during VM creation:${NC}"
        for component in "${!ERRORS[@]}"; do
            echo -e "  ${RED}$component:${NC} ${ERRORS[$component]}"
        done
        
        if [ -n "$TAILSCALE_IP" ]; then
            echo -e "\n${YELLOW}Despite errors, the VM appears to be accessible:${NC}"
            echo -e "  Tailscale IP: ${YELLOW}$TAILSCALE_IP${NC}"
            if [ -n "${STATUS[Tailscale|Hostname]}" ]; then
                echo -e "  Tailscale Hostname: ${YELLOW}${STATUS[Tailscale|Hostname]}${NC}"
            fi
            echo -e "\n${YELLOW}You can try to SSH to the VM using:${NC}"
            echo -e "  ${YELLOW}ssh -i $ANSIBLE_KEY_PATH ansible@$TAILSCALE_IP${NC}"
        fi
    fi
}

display_microk8s_status() {
    display_substep "Checking MicroK8s status"
    
    # Get MicroK8s status from the VM
    MICROK8S_STATUS=$(az vm run-command invoke \
      --resource-group $RESOURCE_GROUP \
      --name $VM_INSTANCE_NAME \
      --command-id RunShellScript \
      --scripts "microk8s status" \
      --query 'value[0].message' \
      --output tsv 2>&1)
    
    # Check for authorization failures first
    if [[ "$MICROK8S_STATUS" == *"AuthorizationFailed"* ]]; then
        display_error "Permission denied checking MicroK8s status - PIM role might not be active"
        add_status "MicroK8s" "Status Check" "Skipped - Permission denied"
        return 0  # Continue the script regardless
    fi
    
    # Check if MicroK8s is running
    if [[ "$MICROK8S_STATUS" == *"microk8s is running"* ]]; then
        display_success "MicroK8s is running"
        
        # Display enabled addons
        ENABLED_ADDONS=$(echo "$MICROK8S_STATUS" | grep -A50 "enabled:" | grep -B50 "disabled:" | grep -v "enabled:" | grep -v "disabled:" | awk '{$1=$1};1')
        
        echo -e "${GREEN}Enabled addons:${NC}"
        echo "$ENABLED_ADDONS" | while read -r line; do
            if [[ -n "$line" ]]; then
                echo -e "  ${GREEN}✓${NC} $line"
            fi
        done
        
        add_status "MicroK8s" "Status" "Running"
        return 0
    elif [[ "$MICROK8S_STATUS" == *"microk8s is not running"* ]]; then
        display_error "MicroK8s is not running"
        add_status "MicroK8s" "Status" "Not running"
        return 1
    else
        display_substep "Could not determine MicroK8s status"
        echo "$MICROK8S_STATUS" | head -10
        add_status "MicroK8s" "Status" "Unknown"
        return 0
    fi
}

# Main execution
main() {
    # Display script header
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}    Azure VM Creation Script v2 (Full Setup)    ${NC}"
    echo -e "${BLUE}================================================${NC}"
    
    # Check if required parameters are provided
    if [ $# -ne 3 ]; then
        display_error "Incorrect number of parameters provided"
        echo -e "${YELLOW}Usage: $0 <admin_username> <admin_password> <vm_instance_name>${NC}"
        exit 1
    fi

    ADMIN_USERNAME=$1
    ADMIN_PASSWORD=$2
    VM_INSTANCE=$3

    # Check if VM_INSTANCE is not empty
    if [ -z "$VM_INSTANCE" ]; then
        add_error "Parameter Check" "VM_INSTANCE parameter cannot be empty"
        print_summary
        exit 1
    fi

    echo -e "${GREEN}Starting Azure VM creation process for instance: ${YELLOW}$VM_INSTANCE${NC}"

    # STEP 1: Check required files and load configuration
    display_step "1" "Checking required files and loading configuration"
    
    # Check if required files exist
    if ! check_file_exists "$CONFIG_FILE" "Configuration"; then
        print_summary
        exit 1
    fi
    
    if ! check_file_exists "$CLOUD_INIT_FILE" "Cloud-Init"; then
        print_summary
        exit 1
    fi

    # Source the configuration file
    display_substep "Loading configuration from $CONFIG_FILE"
    source "$CONFIG_FILE"
    display_success "Configuration loaded"
    
    # Generate resource names based on VM_INSTANCE
    display_substep "Generating resource names"
    generate_resource_names
    
    # Display configured variables
    echo -e "${YELLOW}Configured variables:${NC}"
    echo -e "  VM Instance Name: ${GREEN}$VM_INSTANCE_NAME${NC}"
    echo -e "  VM Resource Group: ${GREEN}$RESOURCE_GROUP${NC}"
    echo -e "  Network Resource Group: ${GREEN}$NETWORK_RG${NC}"
    echo -e "  Subscription ID: ${GREEN}$SUBSCRIPTION_ID${NC}"

    # STEP 1.5: Prompt user to activate PIM role and verify
    display_step "1.5" "Checking and activating Privileged Identity Management (PIM) role"
    
    # Call the pim_yourself function with verification
    if ! pim_yourself; then
        add_status "PIM Verification" "Fail"
        add_error "PIM Verification" "Contributor role not detected or activation failed"
        echo -e "${RED}Error: This script requires Contributor role to run successfully.${NC}"
        echo -e "${RED}Please activate your PIM role and try again.${NC}"
        print_summary
        exit 1
    fi
    
    add_status "PIM Verification" "OK"
    echo -e "${GREEN}Contributor role verified. Proceeding with script execution...${NC}"

    # STEP 2: Azure CLI setup and login
    display_step "2" "Setting up Azure CLI and login"
    
    # Set Azure CLI login experience
    run_command "Azure CLI" "Setting login experience" "az config set core.login_experience_v2=off"

    # Azure Login
    display_substep "Initiating Azure login"
    echo -e "${YELLOW}Please follow these steps to log in:${NC}"
    echo -e "  1. Open a web browser and go to: ${GREEN}https://microsoft.com/devicelogin${NC}"
    echo -e "  2. Enter the code that will be displayed below"
    echo -e "  3. Follow the prompts to complete the login process"

    # Run the login command directly to ensure the user sees the device code
    echo -e "${BLUE}Running: az login --tenant $TENANT_ID --use-device-code${NC}"
    az login --tenant $TENANT_ID --use-device-code
    
    # Check if login was successful
    if [ $? -ne 0 ]; then
        add_error "Azure" "Login failed"
        print_summary
        exit 1
    fi
    display_success "Azure login successful"

    # Set Subscription
    if ! run_command "Azure" "Set subscription" "az account set --subscription $SUBSCRIPTION_ID"; then
        print_summary
        exit 1
    fi
    
    # STEP 3: Check VM Existence
    display_step "3" "Checking for existing resources"
    display_substep "Checking if VM already exists: $VM_INSTANCE_NAME"
    if resource_exists "vm" "$RESOURCE_GROUP" "$VM_INSTANCE_NAME"; then
        add_error "VM Check" "VM $VM_INSTANCE_NAME already exists in resource group $RESOURCE_GROUP"
        print_summary
        exit 1
    else
        display_success "VM does not exist, can proceed with creation"
    fi

    # STEP 4: Create Resource Groups
    display_step "4" "Creating Resource Groups"
    
    # Create VM Resource Group
    if ! create_resource_group_if_not_exists "$RESOURCE_GROUP" "$LOCATION" "$TAGS"; then
        print_summary
        exit 1
    fi
    
    # Create Network Resource Group
    if ! create_resource_group_if_not_exists "$NETWORK_RG" "$LOCATION" "$TAGS"; then
        print_summary
        exit 1
    fi

    # STEP 5: Create VNet and Subnet
    display_step "5" "Creating VNet and Subnet"
    
    # Create VNet
    if ! create_vnet_if_not_exists "$NETWORK_RG" "$VNET_NAME" "${VNET_ADDRESS_SPACE:-10.2.0.0/16}" "$LOCATION" "$TAGS"; then
        print_summary
        exit 1
    fi
    
    # Create Subnet
    if ! create_subnet_if_not_exists "$NETWORK_RG" "$VNET_NAME" "$SUBNET_NAME" "${SUBNET_ADDRESS_PREFIX:-10.2.1.0/24}"; then
        print_summary
        exit 1
    fi
    
    # Update subnet full path for later use
    display_substep "Updating SUBNET_FULL_PATH variable"
    SUBNET_FULL_PATH="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$NETWORK_RG/providers/Microsoft.Network/virtualNetworks/$VNET_NAME/subnets/$SUBNET_NAME"
    add_status "Network" "Update variables" "OK"

    # STEP 6: Create Network Security Group
    display_step "6" "Creating Network Security Group"
    
    # Create NSG
    if ! create_nsg_if_not_exists "$RESOURCE_GROUP" "$NSG_NAME" "$LOCATION" "$TAGS"; then
        print_summary
        exit 1
    fi

    # STEP 7: Create Network Interface
    display_step "7" "Creating Network Interface"
    display_substep "Creating network interface: $NIC_NAME"
    if ! run_command "Network" "Create interface" "az network nic create --resource-group $RESOURCE_GROUP --name $NIC_NAME --subnet $SUBNET_FULL_PATH --network-security-group $NSG_NAME --private-ip-address-version IPv4"; then
        print_summary
        exit 1
    fi

    # STEP 8: Create VM with Data Disk
    display_step "8" "Creating Virtual Machine with Data Disk"
    display_substep "Starting VM creation (this may take several minutes)"
    if ! run_command "VM" "Create" "az vm create --resource-group $RESOURCE_GROUP --name $VM_INSTANCE_NAME --image $IMAGE --size $VM_SIZE --location $LOCATION --admin-username \"$ADMIN_USERNAME\" --admin-password \"$ADMIN_PASSWORD\" --authentication-type $AUTH_TYPE --storage-sku $STORAGE_SKU --os-disk-name $OS_DISK_NAME --os-disk-size-gb $OS_DISK_SIZE --data-disk-sizes-gb $DATA_DISK_SIZE --data-disk-caching ReadWrite --tags $TAGS --nics $NIC_NAME --custom-data @$CLOUD_INIT_FILE"; then
        print_summary
        exit 1
    fi

    # STEP 9: Wait for VM to be Ready
    display_step "9" "Waiting for VM to be fully provisioned"
    if ! run_command "VM" "Wait for creation" "az vm wait --resource-group $RESOURCE_GROUP --name $VM_INSTANCE_NAME --created"; then
        print_summary
        exit 1
    fi
    
    # STEP 10: Wait for cloud-init to complete
    display_step "10" "Waiting for cloud-init to complete"
    # Give cloud-init some time to start before checking status
    sleep 60
    if ! check_cloud_init_status; then
        display_substep "Cloud-init had issues but continuing with the process"
        # We continue despite cloud-init issues since some operations might still succeed
    fi
    
    # STEP 11: Format and Mount Data Disk
    display_step "11" "Formatting and mounting data disk"
    if ! run_command_on_vm "Formatting and mounting data disk" "sudo parted /dev/sdc --script mklabel gpt mkpart xfspart xfs 0% 100% && \
                   sudo mkfs.xfs /dev/sdc1 && \
                   sudo partprobe /dev/sdc1 && \
                   sudo mkdir -p $MOUNT_POINT && \
                   sudo mount /dev/sdc1 $MOUNT_POINT && \
                   echo '/dev/sdc1 $MOUNT_POINT xfs defaults 0 2' | sudo tee -a /etc/fstab && \
                   sudo chown $ADMIN_USERNAME:$ADMIN_USERNAME $MOUNT_POINT && \
                   sudo chmod 755 $MOUNT_POINT && \
                   echo 'Disk formatted, mounted, and permissions set'"; then
        display_substep "Disk formatting failed but continuing with next steps"
    fi

    # STEP 12: Get Tailscale IP
    display_step "12" "Getting Tailscale IP and Hostname"
    if ! get_tailscale_ip; then
        display_substep "Could not retrieve Tailscale IP - cloud-init may still be configuring Tailscale"
        display_substep "Continuing without Tailscale IP. You will need to manually verify Tailscale connectivity later."
        # Set a placeholder value so the script can continue
        TAILSCALE_IP="<TAILSCALE_IP_NOT_AVAILABLE>"
        add_status "Tailscale" "Status" "Not ready - manual verification required"
    fi

    # STEP 13: Create azure-microk8s.sh file
    display_step "13" "Creating cluster information file"
    display_substep "Creating: $AZURE_CLUSTER_INFO"
    
    # Use a temporary file if permission issues occur
    TMP_CLUSTER_INFO="/tmp/azure-microk8s.sh.tmp"
    cat << EOF > "$TMP_CLUSTER_INFO"
#!/bin/bash
# filename: $AZURE_CLUSTER_INFO
# description: automatically created info about azure 
TAILSCALE_IP=$TAILSCALE_IP
TAILSCALE_HOSTNAME=${STATUS["Tailscale|Hostname"]:-"$VM_INSTANCE"}
CLUSTER_NAME=$CLUSTER_NAME
HOST_NAME=$VM_INSTANCE_NAME
EOF

    # Make the temp file executable before moving it
    chmod +x "$TMP_CLUSTER_INFO" 2>/dev/null

    # Try multiple methods to get the file in place with proper permissions
    if cp "$TMP_CLUSTER_INFO" "$AZURE_CLUSTER_INFO" 2>/dev/null; then
        display_success "Created $AZURE_CLUSTER_INFO"
    elif sudo cp "$TMP_CLUSTER_INFO" "$AZURE_CLUSTER_INFO" 2>/dev/null; then
        # If sudo cp worked, update ownership
        sudo chown $(id -u):$(id -g) "$AZURE_CLUSTER_INFO" 2>/dev/null
        display_success "Created $AZURE_CLUSTER_INFO (using sudo)"
    elif mv "$TMP_CLUSTER_INFO" "$AZURE_CLUSTER_INFO" 2>/dev/null; then
        display_success "Created $AZURE_CLUSTER_INFO (using move)"
    elif sudo mv "$TMP_CLUSTER_INFO" "$AZURE_CLUSTER_INFO" 2>/dev/null; then
        display_success "Created $AZURE_CLUSTER_INFO (using sudo move)"
    else
        # If all methods fail, inform the user and provide the temp file path
        display_error "Could not create $AZURE_CLUSTER_INFO due to permission issues"
        display_substep "Using temporary file at $TMP_CLUSTER_INFO instead"
        AZURE_CLUSTER_INFO="$TMP_CLUSTER_INFO"  # Use the temp file for subsequent steps
        add_status "Configuration" "Info File" "Using temporary file: $TMP_CLUSTER_INFO"
    fi

    # STEP 14: Set execute permissions for azure-microk8s.sh
    display_step "14" "Setting execute permissions for info file"
    if ! chmod +x "$AZURE_CLUSTER_INFO" 2>/dev/null; then
        if ! sudo chmod +x "$AZURE_CLUSTER_INFO" 2>/dev/null; then
            display_substep "Setting permissions failed but continuing with next steps"
            add_status "Configuration" "File Permissions" "Failed to set executable permissions"
        else
            display_success "Set executable permissions using sudo"
            add_status "Configuration" "File Permissions" "Set with sudo"
        fi
    else
        display_success "Set executable permissions"
        add_status "Configuration" "File Permissions" "Set successfully"
    fi

    # STEP 15: Test Ansible User SSH Access (if Tailscale IP is available)
    if [[ "$TAILSCALE_IP" != "<TAILSCALE_IP_NOT_AVAILABLE>" ]]; then
        display_step "15" "Testing Ansible user SSH access"
        display_substep "Testing SSH connection to $TAILSCALE_IP"
        if ssh -i "$ANSIBLE_KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PasswordAuthentication=no -o ConnectTimeout=10 -F /dev/null ansible@$TAILSCALE_IP echo "Ansible user SSH test successful"; then
            display_success "Ansible SSH access successful"
            add_status "Ansible" "SSH Test" "Successful"
        else
            add_error "Ansible" "SSH test failed. Please check Ansible user configuration and SSH key setup."
            add_status "Ansible" "SSH Test" "Failed"
        fi
    else
        display_step "15" "Skipping SSH test - no Tailscale IP available"
        display_substep "Once Tailscale is connected, you can SSH using: ssh -i $ANSIBLE_KEY_PATH -F /dev/null ansible@<tailscale-ip>"
        add_status "Ansible" "SSH Test" "Skipped - no Tailscale IP available"
    fi

    # STEP 16: Display the cluster information
    display_step "16" "Displaying cluster information"
    display_microk8s_status    

    # Print final summary
    print_summary
    exit $ERROR
}

# Run the main function
main "$@"