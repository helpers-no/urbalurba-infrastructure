#!/bin/bash
# filename: 03-setup-microk8s-v2.sh
# description: Configure an existing microk8s installation by retrieving and merging kubeconfig files.
#
# Purpose:
# - Connects to the target host where MicroK8s is already installed
# - Retrieves the kubeconfig file and dashboard token from the target host
# - Copies these files to the provision host
# - Merges this kubeconfig with any existing configurations into a single file (kubeconf-all)
# - Moves the hostpath-storage to a custom location for better persistence
# - This allows managing multiple MicroK8s clusters from a single provision host
#
# The script assumes:
# - MicroK8s is already installed and running on the target host
# - The dashboard addon is already enabled
# - Ansible is properly configured on the provision host
#
# The script uses three main playbooks:
# 1. 03-copy-microk8s-config.yml: Retrieves kubeconfig and dashboard token
# 2. 04-merge-kubeconf.yml: Merges all kubeconfig files into a single file
# 3. 010-move-hostpath-storage.yml: Moves default storage to a custom location
#
# Usage: ./03-setup-microk8s-v2.sh [target-host]
# example: ./03-setup-microk8s-v2.sh multipass-microk8s
# Default target host is azure-microk8s
#
# Output:
# - Creates/updates /mnt/urbalurbadisk/kubeconfig/TARGET_HOST-kubeconf file
# - Creates/updates /mnt/urbalurbadisk/kubeconfig/TARGET_HOST-dashboardtoken file
# - Merges all kubeconfig files into /mnt/urbalurbadisk/kubeconfig/kubeconf-all
# - Sets the most recently added cluster as the current context
# - Configures system-wide KUBECONFIG environment variable
# - Moves MicroK8s storage to /mnt/urbalurbadisk/kubernetesstorage

# Ensure the script is run with Bash
if [ -z "$BASH_VERSION" ]; then
    echo "This script must be run with Bash"
    exit 1
fi

# Initialize associative arrays for status and errors
declare -A STATUS
declare -A ERRORS

# Variables
ANSIBLE_DIR="/mnt/urbalurbadisk/ansible"
PLAYBOOK_PATH_COPY_MICROK8_CONFIGS="$ANSIBLE_DIR/playbooks/03-copy-microk8s-config.yml"
PLAYBOOK_PATH_MERGE_KUBECONF="$ANSIBLE_DIR/playbooks/04-merge-kubeconf.yml"
PLAYBOOK_PATH_MOVE_STORAGE="$ANSIBLE_DIR/playbooks/010-move-hostpath-storage.yml"
MERGED_KUBECONF_FILE="/mnt/urbalurbadisk/kubeconfig/kubeconf-all"

# Check if TARGET_HOST is provided as an argument, otherwise set default to azure-microk8s
TARGET_HOST=${1:-"azure-microk8s"}

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

# Function to run Ansible playbook with proper error handling
run_playbook() {
    local step=$1
    local playbook=$2
    local extra_args=${3:-""}
    
    echo "$(basename "$0"): Running playbook for $step: $(basename "$playbook")..."
    cd "$ANSIBLE_DIR" && ansible-playbook "$playbook" -e "target_host=$TARGET_HOST" $extra_args
    local result=$?
    if [ $result -ne 0 ]; then
        add_status "$step" "Fail"
        add_error "$step" "Playbook failed with exit code $result"
        return 1
    else
        add_status "$step" "OK"
        return 0
    fi
}

# Test Ansible connection to ensure target host is reachable
test_connection() {
    echo "Testing connection to $TARGET_HOST..."
    cd $ANSIBLE_DIR && ansible $TARGET_HOST -m ping
    check_command_success "Test connection"
}

# Function to list pods in the current cluster
list_pods() {
    echo "Listing pods in all namespaces..."
    # We still need to use --kubeconfig here because the environment variable
    # hasn't taken effect in the current shell session
    kubectl --kubeconfig="$MERGED_KUBECONF_FILE" get pods --all-namespaces
    check_command_success "List pods"
}

# Main execution
main() {
    echo "Starting MicroK8s configuration for $TARGET_HOST"
    echo "---------------------------------------------------"
    echo "This script will:"
    echo "1. Connect to $TARGET_HOST and verify MicroK8s is running"
    echo "2. Retrieve the kubeconfig file and dashboard token"
    echo "3. Merge this kubeconfig with existing configurations into kubeconf-all"
    echo "4. Move MicroK8s hostpath-storage to a custom location"
    echo "5. Configure system-wide KUBECONFIG environment variable"
    echo "---------------------------------------------------"

    test_connection || { print_summary; return 1; }
    
    # Get the MicroK8s config and dashboard token
    run_playbook "Get MicroK8s config" "$PLAYBOOK_PATH_COPY_MICROK8_CONFIGS" || { print_summary; return 1; }
    
    # Merge kubeconfig files
    run_playbook "Merge kubeconf" "$PLAYBOOK_PATH_MERGE_KUBECONF" || { print_summary; return 1; }
    
    # Move hostpath storage to custom location
    run_playbook "Move hostpath storage" "$PLAYBOOK_PATH_MOVE_STORAGE" || { print_summary; return 1; }

    # List pods in the current cluster to verify configuration 
    list_pods

    print_summary
    
    # Return 0 if no errors, 1 otherwise
    return ${#ERRORS[@]}
}

# Print summary of all operations
print_summary() {
    echo "---------- Configuration Summary ----------"
    for step in "${!STATUS[@]}"; do
        echo "$step: ${STATUS[$step]}"
    done

    if [ ${#ERRORS[@]} -eq 0 ]; then
        echo "All steps completed successfully."
        echo "You can now use 'kubectl' to manage your MicroK8s clusters."
        echo ""
        echo "=== Configuration Details ==="
        echo "Kubeconfig file: $MERGED_KUBECONF_FILE"
        echo "Dashboard token: /mnt/urbalurbadisk/kubeconfig/${TARGET_HOST}-dashboardtoken"
        echo "Hostpath storage: Moved to /mnt/urbalurbadisk/kubernetesstorage"
        echo ""
        echo "=== Useful kubectl commands ==="
        echo "# List all available clusters/contexts:"
        echo "kubectl config get-contexts"
        echo ""
        echo "# Switch to a specific cluster:"
        echo "kubectl config use-context <context-name>"
        echo ""
        echo "# List all pods in the current cluster:"
        echo "kubectl get pods --all-namespaces"
    else
        echo "Errors occurred during configuration:"
        for step in "${!ERRORS[@]}"; do
            echo "  $step: ${ERRORS[$step]}"
        done
    fi
}

# Run the main function and exit with its return code
main
exit $?