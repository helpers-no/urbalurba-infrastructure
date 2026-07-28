#!/bin/bash
# filename: provision-host-04-helmrepo.sh
# description: Uses ansible playbook to install helm and helm repositories system-wide on the provision host.

set -eo pipefail

# Initialize associative arrays for status and errors
declare -A STATUS
declare -A ERRORS

# Global variables
ANSIBLE_DIR="/mnt/urbalurbadisk/ansible"
PLAYBOOK_PATH_SETUP_HELM="${ANSIBLE_DIR}/playbooks/05-install-helm-repos.yml"
KUBECONFIG_FILE="/mnt/urbalurbadisk/kubeconfig/kubeconf-all"

# Function to add status
add_status() {
    local step=$1
    local status=$2
    STATUS["$step"]=$status
}

# Function to add error
add_error() {
    local step=$1
    local error=$2
    ERRORS["$step"]="${ERRORS[$step]-}${ERRORS[$step]+$'\n'}$error"
}

# Function to check command success
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

# Install Helm and repositories
install_helm_and_repos() {
    if [ "$RUNNING_IN_CONTAINER" = "true" ]; then
        echo "Installing Helm directly (container environment)"
        curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
        
        # NOTE: These repositories must be kept in sync with ansible/playbooks/05-install-helm-repos.yml
        # If you add or remove repositories here, make sure to update the Ansible playbook as well.
        echo "Adding Helm repositories directly"
        helm repo add bitnami https://charts.bitnami.com/bitnami
        helm repo add runix https://helm.runix.net
        helm repo add graviteeio https://helm.gravitee.io
        helm repo add minio https://charts.min.io/
        helm repo add temporal https://go.temporal.io/helm-charts
        helm repo update
        
        echo "Helm $(helm version --short) installed successfully"
    else
        # Ensure Helm is installed before running the playbook
        if ! command -v helm &> /dev/null; then
            echo "Installing Helm before running the playbook"
            curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
        fi
        
        echo "Installing Helm and repositories using the playbook $PLAYBOOK_PATH_SETUP_HELM"
        ANSIBLE_CONFIG="${ANSIBLE_DIR}/ansible.cfg" ansible-playbook "$PLAYBOOK_PATH_SETUP_HELM"
    fi
    check_command_success "Install Helm and Repositories"
}

# Verify Helm installation
verify_helm_installation() {
    echo "Verifying Helm installation..."
    if helm version; then
        add_status "Verify Helm Installation" "OK"
    else
        add_status "Verify Helm Installation" "Fail"
        add_error "Verify Helm Installation" "Helm version check failed"
    fi
}

# Verify Helm repositories
verify_helm_repos() {
    echo "Verifying Helm repositories..."
    if helm repo list; then
        add_status "Verify Helm Repositories" "OK"
    else
        add_status "Verify Helm Repositories" "Fail"
        add_error "Verify Helm Repositories" "Helm repository list failed"
    fi
}

# Print summary
print_summary() {
    echo "---------- Installation Summary ----------"
    for step in "${!STATUS[@]}"; do
        echo "$step: ${STATUS[$step]}"
    done

    if [ ${#ERRORS[@]} -eq 0 ]; then
        echo "All steps completed successfully."
    else
        echo "Errors occurred during installation:"
        for step in "${!ERRORS[@]}"; do
            echo "  $step: ${ERRORS[$step]}"
        done
    fi
}

# Main execution
main() {
    echo "Starting Helm and repositories installation on $(hostname)"
    echo "---------------------------------------------------"

    # Ensure the script is run from the correct directory
    if [[ ${PWD##*/} != "provision-host" ]]; then
        echo "This script must be run in the provision-host directory."
        exit 1
    fi

    # Ensure Helm is installed before running the playbook
    if ! command -v helm &> /dev/null; then
        echo "Installing Helm before running the playbook"
        curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    fi
    
    echo "Installing Helm repositories using the playbook $PLAYBOOK_PATH_SETUP_HELM"
    if ! ANSIBLE_CONFIG="${ANSIBLE_DIR}/ansible.cfg" ansible-playbook "$PLAYBOOK_PATH_SETUP_HELM"; then
        echo "Ansible playbook failed, falling back to direct installation"
        install_helm_and_repos
    fi
    
    # Verify installation
    verify_helm_installation
    verify_helm_repos
    
    print_summary
    
    # Return 0 if no errors, 1 otherwise
    return ${#ERRORS[@]}
}

# Run the main function and exit with its return code
main
exit $?