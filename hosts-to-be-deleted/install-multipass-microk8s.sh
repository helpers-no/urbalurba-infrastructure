#!/bin/bash
# filename: install-multipass-microk8s.sh
# description: Creates the vm named multipass-microk8s in multipass and installs microk8s on it
# Its /mnt/urbalurbadisk is mounted on the hosts uswers home folder in the folder multipass
# The script must be run on the Mac host (not tested on windows or linux hosts)

set -e  # Exit immediately if a command exits with a non-zero status.

# Variables
STATUS=()
ERROR=0

# Function to check the success of the last command
check_command_success() {
    if [ $? -ne 0 ]; then
        STATUS+=("$1: Fail")
        ERROR=1
    else
        STATUS+=("$1: OK")
    fi
}

# Function to run a script from a specific directory
run_script_from_directory() {
    local directory=$1
    shift
    local script=$1
    shift
    local args=("$@")

    echo "- Script: $0 -----------------> Running $script ${args[*]} in directory: $directory"
    if [ ! -d "$directory" ]; then
        echo "Error: Directory $directory does not exist."
        ERROR=1
        return
    fi
    if [ ! -f "$directory/$script" ]; then
        echo "Error: Script $script does not exist in $directory."
        ERROR=1
        return
    fi
    (cd "$directory" && ./$script "${args[@]}")
    check_command_success "$script in $directory"
}

# Function to run a script on provision-host as the ansible user
run_script_as_ansible_on_provision_host() {
    local host_directory=$1
    local script_name=$2
    local target_host=$3
    shift 3
    local args=("$@")

    local full_script_path="/mnt/urbalurbadisk/$host_directory/$script_name"

    echo "- Script: $0 -----------------> Running $script_name ${args[*]} on provision-host for target: $target_host"
    ssh ansible@provision-host "bash $full_script_path $target_host ${args[*]}"
    check_command_success "$script_name on provision-host for $target_host"
}

# Function to ensure the script is run from the root directory of the project
ensure_root_directory() {
    if [ ! -f "README.md" ]; then  # Replace "README.md" with a file that exists only in the root of your project
        echo "Error: This script must be run from the root directory of the project."
        exit 1
    fi
}



echo "==========------------------> Step 1: Create multipass VM named: multipass-microk8s"
run_script_from_directory "multipass-microk8s" "01-create-multipass-microk8s.sh" "--cpus" "6" "--memory" "10G" "--disk" "50G"

echo "==========------------------> Step 2: Register VM multipass-microk8s in ansible inventory on provision-host"
run_script_from_directory "multipass-microk8s" "02-inventory-multipass-microk8s.sh"


echo "==========------------------> Step 3: Install software on VM multipass-microk8s"
run_script_as_ansible_on_provision_host "hosts" "03-setup-microk8s.sh" "multipass-microk8s"


echo "==========------------------> Step 4: Applying secrets to the cluster"
run_script_from_directory "../topsecret" "update-kubernetes-secrets.sh"




echo "==========------------------> Step 5: Install local kubeconfig"
run_script_from_directory "../topsecret" "kubeconf-copy2local.sh" "multipass-microk8s"

echo "------ Summary of installation statuses for: $0 ------"
for status in "${STATUS[@]}"; do
    echo "$status"
done

if [ $ERROR -ne 0 ]; then
    echo "---------------- E R R O R --------------------"
    echo "Check the status lines above"
    exit 1
else
    echo "--------------- All OK ------------------------"
    echo "Multipass-microk8s VM creation and setup completed successfully."
fi

exit $ERROR