#!/bin/bash
# filename: 02-azure-ansible-inventory-v2.sh
# description: Update Ansible inventory with the IP address of the azure vm / azure-microk8s cluster
# 
# Parameters:
#   [config_file]           Optional - Path to Azure VM configuration file
#                           Default: ./azure-vm-config-redcross-sandbox.sh
#
#   [cluster_info_file]     Optional - Path to file containing cluster information
#                           Default: Value of AZURE_CLUSTER_INFO from config file
#                           (typically azure-microk8s.sh)
#
# Examples:
#   ./02-azure-ansible-inventory-v2.sh                             # Use default files
#   ./02-azure-ansible-inventory-v2.sh ./my-config.sh              # Custom config file
#   ./02-azure-ansible-inventory-v2.sh ./my-config.sh ./info.sh    # Custom config and info files
#
# To be run on provision-host VM as user ansible

# Terminal colors for better visibility
BLUE='\033[0;34m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Initialize associative arrays for status and errors
declare -A STATUS
declare -A ERRORS
ERROR=0  # Global error tracker

# Source centralized path library for backwards-compatible path resolution
if [[ -f "/mnt/urbalurbadisk/provision-host/uis/lib/paths.sh" ]]; then
    source "/mnt/urbalurbadisk/provision-host/uis/lib/paths.sh"
    SSH_KEY_DIR=$(get_ssh_key_path)
else
    SSH_KEY_DIR="/mnt/urbalurbadisk/secrets"
fi

# Default Variables
CONFIG_FILE="./azure-vm-config-redcross-sandbox.sh"
ANSIBLE_DIR="/mnt/urbalurbadisk/ansible"
INVENTORY_PLAYBOOK="$ANSIBLE_DIR/playbooks/02-update-ansible-inventory.yml"

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

# Function to run command and capture output
run_command() {
    local component=$1
    local step=$2
    local command=$3
    
    display_substep "Running: $step"
    OUTPUT=$(eval "$command" 2>&1)
    
    if [ $? -ne 0 ]; then
        add_error "$component" "$step failed. Output: $OUTPUT"
        echo -e "${RED}Command output:${NC}\n$OUTPUT"
        return 1
    else
        add_status "$component" "$step" "OK"
        display_success "$component: $step"
        return 0
    fi
}

# Function to check if we're in the correct directory
check_current_directory() {
    display_step "1" "Checking current directory"
    
    CURRENT_DIR=${PWD##*/}
    display_substep "Current directory: $CURRENT_DIR"
    
    if [ "$CURRENT_DIR" != "azure-microk8s" ]; then
        add_error "Directory Check" "This script must be run from the folder hosts-to-be-deleted/azure-microk8s"
        echo -e "${RED}Current directory: $CURRENT_DIR${NC}"
        echo -e "${RED}Full path: $PWD${NC}"
        return 1
    fi
    
    display_success "Correct directory confirmed: hosts-to-be-deleted/azure-microk8s"
    add_status "Environment" "Directory" "OK"
    return 0
}

# Function to load configuration from files
load_configuration() {
    display_step "2" "Loading configuration"
    
    # Check if custom config file was provided
    if [ ! -z "$1" ]; then
        CONFIG_FILE="$1"
    fi
    
    # Check if the file that contains the configuration exists
    if ! check_file_exists "$CONFIG_FILE" "Configuration"; then
        return 1
    fi
    
    # Source the configuration file
    display_substep "Loading configuration from $CONFIG_FILE"
    source "$CONFIG_FILE"
    
    if [ $? -ne 0 ]; then
        add_error "Configuration" "Failed to load configuration from $CONFIG_FILE"
        return 1
    fi
    
    display_success "Successfully loaded configuration from $CONFIG_FILE"
    add_status "Configuration" "Main Config" "OK"
    
    # Check if custom cluster info file was provided
    if [ ! -z "$2" ]; then
        AZURE_CLUSTER_INFO="$2"
    fi
    
    # Check if the file that contains the info about the cluster exists 
    if ! check_file_exists "$AZURE_CLUSTER_INFO" "Cluster Info"; then
        return 1
    fi
    
    # Source the cluster info file
    display_substep "Loading cluster information from $AZURE_CLUSTER_INFO"
    source "$AZURE_CLUSTER_INFO"
    
    if [ $? -ne 0 ]; then
        add_error "Configuration" "Failed to load cluster information from $AZURE_CLUSTER_INFO"
        return 1
    fi
    
    display_success "Successfully loaded cluster information from $AZURE_CLUSTER_INFO"
    add_status "Configuration" "Cluster Info" "OK"
    
    # Display the loaded configuration
    display_substep "Loaded configuration:"
    echo -e "  Cluster Name: ${YELLOW}$CLUSTER_NAME${NC}"
    echo -e "  Tailscale IP: ${YELLOW}$TAILSCALE_IP${NC}"
    echo -e "  Host Name: ${YELLOW}$HOST_NAME${NC}"
    echo -e "  Ansible Directory: ${YELLOW}$ANSIBLE_DIR${NC}"
    
    return 0
}

# Function to update ansible inventory
update_ansible_inventory() {
    display_step "3" "Updating Ansible inventory"
    
    # Validate required variables
    display_substep "Validating configuration variables"
    if [ -z "$CLUSTER_NAME" ]; then
        add_error "Ansible Update" "CLUSTER_NAME is not defined"
        return 1
    fi
    
    if [ -z "$TAILSCALE_IP" ]; then
        add_error "Ansible Update" "TAILSCALE_IP is not defined"
        return 1
    fi
    
    display_success "Configuration variables validated"
    
    # Check if Ansible directory exists
    display_substep "Checking if Ansible directory exists: $ANSIBLE_DIR"
    if [ ! -d "$ANSIBLE_DIR" ]; then
        add_error "Ansible Update" "Ansible directory $ANSIBLE_DIR does not exist"
        return 1
    fi
    
    display_success "Ansible directory exists"
    
    # Check if inventory playbook exists
    display_substep "Checking if inventory playbook exists: $INVENTORY_PLAYBOOK"
    if [ ! -f "$INVENTORY_PLAYBOOK" ]; then
        add_error "Ansible Update" "Inventory playbook $INVENTORY_PLAYBOOK does not exist"
        return 1
    fi
    
    display_success "Inventory playbook exists"
    
    # Check SSH connectivity to the target host first
    display_substep "Pre-checking SSH connectivity to $TAILSCALE_IP (port 22)"
    if ! run_command "Network" "SSH Connectivity Test" "timeout 5 bash -c 'cat < /dev/null > /dev/tcp/$TAILSCALE_IP/22' 2>/dev/null"; then
        display_error "SSH connectivity check to $TAILSCALE_IP failed"
        display_substep "Will attempt Ansible inventory update anyway, but the playbook may fail if host is unreachable"
        add_status "Network" "SSH Connectivity" "Failed - proceeding anyway"
    else
        display_success "SSH connectivity to $TAILSCALE_IP confirmed"
        add_status "Network" "SSH Connectivity" "OK"
    fi
    
    # Using the SSH key from secrets directory (backwards-compatible path)
    SSH_KEY="$SSH_KEY_DIR/id_rsa_ansible"
    
    # Now run the Ansible playbook with explicit SSH key
    display_substep "Running Ansible playbook to update inventory"
    
    ANSIBLE_CMD="cd \"$ANSIBLE_DIR\" && SSH_AUTH_SOCK= ansible-playbook \"$INVENTORY_PLAYBOOK\" -e target_host=\"$CLUSTER_NAME\" -e target_host_ip=\"$TAILSCALE_IP\" --private-key=\"$SSH_KEY\" -e \"ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes'\""
    
    if ! run_command "Ansible" "Update Inventory" "$ANSIBLE_CMD"; then
        add_error "Ansible" "Inventory update via playbook failed"
        display_substep "Make sure the playbook exists and has the correct parameters"
        display_substep "Check that the Ansible controller has permissions to update the inventory"
        return 1
    fi
    
    display_success "Ansible inventory updated successfully via playbook"
    add_status "Ansible" "Inventory Update" "Successful"
    return 0
}

# Function to test Ansible connection
test_ansible_connection() {
    display_step "4" "Testing Ansible connection"
    
    # Try to ping the host first using standard ping command
    display_substep "Checking network connectivity to $TAILSCALE_IP"
    if ! run_command "Network" "ICMP Ping Test" "ping -c 1 -W 3 $TAILSCALE_IP >/dev/null 2>&1"; then
        display_substep "ICMP ping failed but continuing with Ansible test (ping might be blocked)"
        add_status "Network" "ICMP Ping" "Failed - continuing anyway"
    else
        display_success "Host $TAILSCALE_IP is reachable via ICMP ping"
        add_status "Network" "ICMP Ping" "OK"
    fi
    
    # Point directly to the SSH key (backwards-compatible path)
    SSH_KEY="$SSH_KEY_DIR/id_rsa_ansible"
    
    # Check if the key exists
    display_substep "Checking if SSH key exists: $SSH_KEY"
    if [ ! -f "$SSH_KEY" ]; then
        add_error "SSH" "SSH key $SSH_KEY does not exist"
        return 1
    fi
    
    display_success "SSH key found"
    
    # Now test Ansible connectivity
    display_substep "Pinging host $CLUSTER_NAME via Ansible"
    
    # Add -vvv for verbose output if specified
    ANSIBLE_OPTS=""
    if [ -n "$VERBOSE" ]; then
        ANSIBLE_OPTS="-vvv"
    fi
    
    # First try with explicit key and SSH options to bypass the problematic config
    if ! run_command "Ansible" "Connection Test" "cd \"$ANSIBLE_DIR\" && SSH_AUTH_SOCK= ansible \"$CLUSTER_NAME\" -m ping -o $ANSIBLE_OPTS \
        --private-key=\"$SSH_KEY\" \
        -e \"ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes'\""; then
        
        display_substep "Ping module failed, trying with raw module (minimal SSH test)"
        
        # Try with raw module
        if ! run_command "Ansible" "Basic SSH Test" "cd \"$ANSIBLE_DIR\" && SSH_AUTH_SOCK= ansible \"$CLUSTER_NAME\" -m raw -a 'echo Ansible connection successful' $ANSIBLE_OPTS \
            --private-key=\"$SSH_KEY\" \
            -e \"ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes'\""; then
            
            display_error "All Ansible connection tests failed"
            
            # Check SSH key permissions
            display_substep "Checking SSH key permissions"
            KEY_PERMS=$(stat -c "%a" "$SSH_KEY" 2>/dev/null)
            if [ "$KEY_PERMS" != "600" ]; then
                display_substep "SSH key has incorrect permissions: $KEY_PERMS (should be 600)"
                display_substep "Trying to fix permissions"
                if ! run_command "SSH" "Fix Key Permissions" "chmod 600 \"$SSH_KEY\""; then
                    add_error "SSH" "Failed to fix SSH key permissions"
                fi
            else
                display_substep "SSH key permissions are correct: $KEY_PERMS"
            fi
            
            add_status "Ansible" "Connection Test" "Failed"
            return 1
        else
            display_success "Basic SSH connection successful (using raw module)"
            add_status "Ansible" "Connection Test" "Basic OK (raw module)"
            return 0
        fi
    else
        display_success "Successfully connected to $CLUSTER_NAME via Ansible"
        add_status "Ansible" "Connection Test" "OK"
        return 0
    fi
}

# Print summary of status
print_summary() {
    display_step "6" "Summary"
    
    echo -e "${BLUE}===== Ansible Inventory Update Summary =====${NC}"
    
    # Print statuses
    echo -e "${YELLOW}Component Status:${NC}"
    for key in "${!STATUS[@]}"; do
        IFS='|' read -r component step <<< "$key"
        echo -e "  ${GREEN}$component - $step:${NC} ${STATUS[$key]}"
    done
    
    # Print any errors
    if [ ${#ERRORS[@]} -gt 0 ]; then
        echo -e "\n${RED}Errors occurred:${NC}"
        for component in "${!ERRORS[@]}"; do
            echo -e "  ${RED}$component:${NC} ${ERRORS[$component]}"
        done
        
        # Special case: If there were errors but the connection test passed
        if [[ "${STATUS[Ansible|Connection Test]}" == "OK" ]]; then
            echo -e "\n${YELLOW}⚠️ Warnings occurred but Ansible connection is WORKING.${NC}"
            echo -e "  Cluster Name: ${YELLOW}$CLUSTER_NAME${NC}"
            echo -e "  Host IP: ${YELLOW}$TAILSCALE_IP${NC}"
            echo -e "\n${GREEN}You can now manage this VM through Ansible:${NC}"
            echo -e "  ${YELLOW}ansible $CLUSTER_NAME -m ping${NC}"
            echo -e "  ${YELLOW}ansible-playbook your-playbook.yml -l $CLUSTER_NAME${NC}"
            
            # Setting ERROR to 0 since the connection is working despite warnings
            ERROR=0
        else
            echo -e "\n${RED}Ansible inventory update FAILED.${NC}"
            echo -e "Please check the errors above and retry."
        fi
    else
        echo -e "\n${GREEN}✅ Ansible inventory update completed successfully.${NC}"
        echo -e "  Cluster Name: ${YELLOW}$CLUSTER_NAME${NC}"
        echo -e "  Host IP: ${YELLOW}$TAILSCALE_IP${NC}"
        
        # Show inventory file path
        INVENTORY_FILE="$ANSIBLE_DIR/inventory.yml"
        if [ -f "$INVENTORY_FILE" ]; then
            echo -e "  Inventory File: ${YELLOW}$INVENTORY_FILE${NC}"
        fi
        
        echo -e "\n${GREEN}You can now manage this VM through Ansible:${NC}"
        echo -e "  ${YELLOW}ansible $CLUSTER_NAME -m ping${NC}"
        echo -e "  ${YELLOW}ansible-playbook your-playbook.yml -l $CLUSTER_NAME${NC}"
        
        # Helpful reminder for common commands
        echo -e "\n${BLUE}Common Ansible commands:${NC}"
        echo -e "  ${YELLOW}# Check system facts${NC}"
        echo -e "  ansible $CLUSTER_NAME -m setup"
        echo -e "  ${YELLOW}# Run ad-hoc command${NC}"
        echo -e "  ansible $CLUSTER_NAME -a \"microk8s status\""
        echo -e "  ${YELLOW}# Apply a playbook to this host${NC}"
        echo -e "  ansible-playbook path/to/playbook.yml -l $CLUSTER_NAME"
    fi
}

# Function to validate inventory file format
validate_inventory_file() {
    display_step "5" "Validating Ansible inventory file"
    
    INVENTORY_FILE="$ANSIBLE_DIR/inventory.yml"
    
    # Check if inventory file exists
    display_substep "Checking if inventory file exists: $INVENTORY_FILE"
    if [ ! -f "$INVENTORY_FILE" ]; then
        add_error "Validation" "Inventory file $INVENTORY_FILE does not exist"
        return 1
    fi
    
    display_success "Inventory file exists"
    
    # Check if file is valid YAML
    display_substep "Checking if inventory file is valid YAML"
    
    # Try python if available for yaml validation
    if command -v python3 &> /dev/null; then
        if ! run_command "Validation" "YAML Syntax" "python3 -c 'import yaml; yaml.safe_load(open(\"$INVENTORY_FILE\"))'" 2>/dev/null; then
            add_error "Validation" "Inventory file is not valid YAML"
            display_substep "Will continue but Ansible may fail when using this inventory"
        else
            display_success "Inventory file is valid YAML"
        fi
    elif command -v python &> /dev/null; then
        if ! run_command "Validation" "YAML Syntax" "python -c 'import yaml; yaml.safe_load(open(\"$INVENTORY_FILE\"))'" 2>/dev/null; then
            add_error "Validation" "Inventory file is not valid YAML"
            display_substep "Will continue but Ansible may fail when using this inventory"
        else
            display_success "Inventory file is valid YAML"
        fi
    else
        display_substep "Python not available for YAML validation, skipping syntax check"
        add_status "Validation" "YAML Syntax" "Skipped (Python not available)"
    fi
    
    # Check if cluster name exists in inventory
    display_substep "Checking if $CLUSTER_NAME exists in inventory"
    
    if grep -q "$CLUSTER_NAME:" "$INVENTORY_FILE"; then
        display_success "Cluster name $CLUSTER_NAME found in inventory"
        
        # Check if IP address matches
        display_substep "Checking if IP address is correct"
        if grep -A1 "$CLUSTER_NAME:" "$INVENTORY_FILE" | grep -q "ansible_host: $TAILSCALE_IP"; then
            display_success "IP address $TAILSCALE_IP correctly set for $CLUSTER_NAME"
            add_status "Validation" "IP Address" "Correct"
        else
            add_error "Validation" "IP address for $CLUSTER_NAME does not match expected $TAILSCALE_IP"
            
            # Show current IP
            CURRENT_IP=$(grep -A1 "$CLUSTER_NAME:" "$INVENTORY_FILE" | grep "ansible_host:" | awk '{print $2}')
            if [ -n "$CURRENT_IP" ]; then
                display_substep "Current IP: $CURRENT_IP, Expected: $TAILSCALE_IP"
            fi
        fi
    else
        add_error "Validation" "Cluster name $CLUSTER_NAME not found in inventory"
    fi
    
    # Display inventory for cluster if verbose mode
    if [ -n "$VERBOSE" ]; then
        display_substep "Inventory entry for $CLUSTER_NAME:"
        awk "/$CLUSTER_NAME:/,/^$/" "$INVENTORY_FILE" | head -n2
    fi
    
    return 0
}

# Main function
main() {
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}      Azure VM Ansible Inventory Update V2      ${NC}"
    echo -e "${BLUE}================================================${NC}"
    
    # Parse command line options
    VERBOSE=""
    POSITIONAL_ARGS=()
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -h|--help)
                echo -e "${GREEN}Usage: $0 [OPTIONS] [CONFIG_FILE] [CLUSTER_INFO_FILE]${NC}"
                echo -e "${YELLOW}Options:${NC}"
                echo -e "  -v, --verbose    Enable verbose output"
                echo -e "  -h, --help       Show this help message and exit"
                echo -e "${YELLOW}Arguments:${NC}"
                echo -e "  CONFIG_FILE        Path to the configuration file (default: $CONFIG_FILE)"
                echo -e "  CLUSTER_INFO_FILE  Path to the cluster info file (default: defined in CONFIG_FILE)"
                exit 0
                ;;
            *)
                POSITIONAL_ARGS+=("$1")
                shift
                ;;
        esac
    done
    
    # Restore positional arguments
    set -- "${POSITIONAL_ARGS[@]}"
    
    # Check if we're in the correct directory
    if ! check_current_directory; then
        print_summary
        exit 1
    fi
    
    # Load configuration
    if ! load_configuration "$1" "$2"; then
        print_summary
        exit 1
    fi
    
    # Update Ansible inventory
    if ! update_ansible_inventory; then
        print_summary
        exit 1
    fi
    
    # Validate inventory file
    validate_inventory_file
    
    # Test Ansible connection
    if ! test_ansible_connection; then
        print_summary
        exit 1
    fi
    
    # Print summary
    print_summary
    
    exit $ERROR
}

# Run the main function with all arguments passed to the script
main "$@"