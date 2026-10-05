#!/bin/bash
# filename: install-azure-microk8s-v2.sh
# description: Install and configure MicroK8s cluster on Azure
#
# ⚠️  DEPRECATED: This script calls provision-host/kubernetes/provision-kubernetes.sh
# which has been removed. Remote deployment support is being reworked to use the UIS CLI.
# See: website/docs/ai-developer/plans/backlog/INVESTIGATE-remote-deployment-targets.md
#
# Purpose:
# - Creates an Azure VM with the specified configuration (including MicroK8s installation via cloud-init)
# - Registers the VM in Ansible inventory on the provision host
# - Sets up MicroK8s configuration (retrieves kubeconfig and merges it)
#
# The script follows these steps:
# 1. Create Azure VM using the 01-azure-vm-create-redcross-v2.sh script (includes MicroK8s installation via cloud-init)
# 2. Register the VM in Ansible inventory using 02-azure-ansible-inventory-v2.sh
# 3. Setup MicroK8s configuration using 03-setup-microk8s-v2.sh (retrieves config and merges kubeconfig)
#
# Usage: ./install-azure-microk8s-v2.sh
# No parameters required - configuration is set within the script
#
# Requirements:
# - Script must be run as user 'ansible' on the provision host
# - Azure CLI must be configured correctly
# - Ansible must be installed and configured
# - Required scripts must be available in their respective directories

# Ensure the script is run with Bash
if [ -z "$BASH_VERSION" ]; then
    echo "This script must be run with Bash"
    exit 1
fi

# Initialize associative arrays for status and errors
declare -A STATUS
declare -A ERRORS

# Variables
CLUSTER_NAME="azure-microk8s"
VM_INSTANCE="azure-microk8s"
URB_PATH="/mnt/urbalurbadisk"
SECRETS_CLUSTER="rancher-desktop"

# Function to add status to our tracking array
add_status() {
    local step=$1
    local status=$2
    STATUS["$step"]=$status
}

# Function to add error details to our tracking array
add_error() {
    local step=$1
    local error=$2
    ERRORS["$step"]="${ERRORS[$step]}${ERRORS[$step]:+$'\n'}$error"
}

# Function to check command success and update status accordingly
check_command_success() {
    local step=$1
    if [ $? -ne 0 ]; then
        add_status "$step" "Fail"
        add_error "$step" "Command failed"
        return 1
    else
        add_status "$step" "OK"
        return 0
    fi
}

# Function to select Kubernetes context
select_k8s_context() {
    local context="$1"
    if kubectl config use-context "$context"; then
        add_status "Select K8s context" "OK"
        echo "Successfully switched to context: $context"
    else
        add_status "Select K8s context" "Fail"
        add_error "Select K8s context" "Failed to switch to context: $context"
        return 1
    fi
}

# Function to get Kubernetes secret value
get_kubernetes_secret() {
    local namespace="default"
    local secret_name="urbalurba-secrets"
    local key="$1"
    local value

    value=$(kubectl get secret --namespace "$namespace" "$secret_name" -o jsonpath="{.data.$key}" 2>/dev/null | base64 -d)

    if [ -z "$value" ]; then
        add_status "Get K8s secret" "Fail"
        add_error "Get K8s secret" "Unable to read $key from Kubernetes secret"
        return 1
    fi

    echo "$value"
}

# Function to run a script from its specific directory
run_script_from_directory() {
    local step=$1
    local directory=$2
    local script=$3
    shift 3
    local args=("$@")

    echo "---------> Running $script ${args[*]} in directory: $directory"
    
    # Save current directory
    local current_dir=$(pwd)
    
    # Change to script directory
    cd "$directory" || {
        add_status "$step" "Fail"
        add_error "$step" "Failed to change to directory: $directory"
        return 1
    }
    
    # Run the script
    ./$script "${args[@]}"
    local result=$?
    
    # Return to original directory
    cd "$current_dir"
    
    if [ $result -ne 0 ]; then
        add_status "$step" "Fail"
        add_error "$step" "Script failed with exit code $result"
        return 1
    else
        add_status "$step" "OK"
        return 0
    fi
}

# Function to load credentials from Kubernetes secrets
load_credentials() {
    echo "Loading credentials from Kubernetes secrets in cluster: $SECRETS_CLUSTER"
    
    # Select the Kubernetes context
    select_k8s_context "$SECRETS_CLUSTER" || return 1
    
    # Get credentials from Kubernetes secrets
    UBUNTU_VM_USER=$(get_kubernetes_secret "UBUNTU_VM_USER") || return 1
    UBUNTU_VM_USER_PASSWORD=$(get_kubernetes_secret "UBUNTU_VM_USER_PASSWORD") || return 1
    
    # Verify that required variables are set
    if [ -z "$UBUNTU_VM_USER" ] || [ -z "$UBUNTU_VM_USER_PASSWORD" ]; then
        add_status "Load credentials" "Fail"
        add_error "Load credentials" "Required credentials not found in Kubernetes secrets"
        return 1
    fi
    
    add_status "Load credentials" "OK"
}

# Function to display system status
display_system_status() {
    echo "====================  F I N I S H E D  ===================="
    echo "Azure VM with MicroK8s is all set up with name: $CLUSTER_NAME"
    echo "."
    echo "These are the installed systems:"
    kubectl --context="$CLUSTER_NAME" get services 2>/dev/null
    echo "."
    echo "Access your cluster using:"
    echo "  kubectl --context=$CLUSTER_NAME get nodes"
    echo "  ssh ansible@$CLUSTER_NAME"
    echo "."
    echo "====================  E N D  O F  I N S T A L L A T I O N  ===================="
}

# Print summary of all operations
print_summary() {
    echo "---------- Installation Summary ----------"
    for step in "${!STATUS[@]}"; do
        echo "$step: ${STATUS[$step]}"
    done

    if [ ${#ERRORS[@]} -eq 0 ]; then
        echo "All steps completed successfully."
        display_system_status
    else
        echo "Errors occurred during installation:"
        for step in "${!ERRORS[@]}"; do
            echo "  $step: ${ERRORS[$step]}"
        done
    fi
}

# Main execution
main() {
    echo "Starting MicroK8s installation on Azure"
    echo "---------------------------------------------------"
    echo "This script will:"
    echo "1. Create Azure VM named: $VM_INSTANCE (with MicroK8s installation via cloud-init)"
    echo "2. Register VM in Ansible inventory"
    echo "3. Setup MicroK8s configuration (retrieve config and merge kubeconfig)"
    echo "---------------------------------------------------"

    # Load credentials
    load_credentials || { print_summary; return 1; }

    # Step 1: Create Azure VM (with MicroK8s installed via cloud-init)
    echo "==========> Step 1: Create Azure VM named: $VM_INSTANCE with MicroK8s"
    run_script_from_directory "Create Azure VM" "$URB_PATH/hosts/azure-microk8s" "01-azure-vm-create-redcross-v2.sh" "$UBUNTU_VM_USER" "$UBUNTU_VM_USER_PASSWORD" "$VM_INSTANCE" || { print_summary; return 1; }

    # Step 2: Register VM in Ansible inventory
    echo "==========> Step 2: Register VM $VM_INSTANCE in Ansible inventory"
    run_script_from_directory "Register VM in Ansible" "$URB_PATH/hosts/azure-microk8s" "02-azure-ansible-inventory-v2.sh" || { print_summary; return 1; }

    # Step 3: Setup MicroK8s configuration (retrieve config files and merge kubeconfig)
    echo "==========> Step 3: Setup MicroK8s configuration for: $CLUSTER_NAME"
    run_script_from_directory "Setup MicroK8s config" "$URB_PATH/hosts" "03-setup-microk8s-v2.sh" "$CLUSTER_NAME" || { print_summary; return 1; }

    # Step 4: Apply secrets to the Azure MicroK8s cluster
    echo "==========> Step 4: Applying secrets to the Azure MicroK8s cluster: $CLUSTER_NAME"
    run_script_from_directory "Apply secrets to Azure MicroK8s" "$URB_PATH/topsecret" "update-kubernetes-secrets-rancher.sh" "$CLUSTER_NAME" || { print_summary; return 1; }

    # Step 5: Provision kubernetes services on the cluster
    echo "==========> Step 5: Start the installation of kubernetes systems on: $CLUSTER_NAME"
    run_script_from_directory "Provision Kubernetes" "$URB_PATH/provision-host/kubernetes" "provision-kubernetes.sh" "$CLUSTER_NAME" || { print_summary; return 1; }

    # Print summary
    print_summary
    
    # Return 0 if no errors, 1 otherwise
    return ${#ERRORS[@]}
}

# Run the main function and exit with its return code
main
exit $?