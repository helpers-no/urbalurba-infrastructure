#!/bin/bash
# filename: 01-create-multipass-microk8s.sh
# description: Create a multipass-microk8s VM with bridge networking and a large combined disk for OS and data

# Usage: ./01-create-multipass-microk8s.sh [OPTIONS]

# OPTIONS:
#   --memory SIZE       Set the VM memory size (default: 8G)
#   --cpus NUMBER       Set the number of CPUs for the VM (default: 1)
#   --disk SIZE         Set the total disk size in GB (default: 80G)
#   --bridge-name NAME  Set the bridge network name (default: en0)

# Examples:
#   ./01-create-multipass-microk8s.sh
#   ./01-create-multipass-microk8s.sh --memory 16G --cpus 2 --disk 100G --bridge-name br0

# This script creates a folder /mnt/urbalurbadisk for data storage within the same disk used by the OS.

set -e  # Exit immediately if a command exits with a non-zero status.

# Variables
VM_NAME="multipass-microk8s"
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
CLOUD_INIT_FILE="$SCRIPT_DIR/../../cloud-init/multipass-cloud-init.yml"
CLOUD_INIT_TEMPLATE="multipass"
CPUS=1
MEMORY="8G"
DISK_SIZE="80G"  # Combined OS and data disk size
BRIDGE_NAME="en0"
STATUS=()
ERROR=0

LAUNCH_TIMEOUT=600  # 10 minutes

# Function to check the success of the last command
check_command_success() {
    if [ $? -ne 0 ]; then
        STATUS+=("$1: Fail")
        ERROR=1
    else
        STATUS+=("$1: OK")
    fi
}

# Parse command line arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --memory) MEMORY="$2"; shift ;;
        --cpus) CPUS="$2"; shift ;;
        --disk) DISK_SIZE="$2"; shift ;;
        --bridge-name) BRIDGE_NAME="$2"; shift ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

# Check if the VM is already running
if multipass list | grep -q "$VM_NAME"; then
    echo "Error: VM with name $VM_NAME is already running."
    exit 1
fi
check_command_success "Check if VM is already running"

# Check if the desired bridge exists in multipass networks
if ! multipass networks | grep -qw "$BRIDGE_NAME"; then
    echo "Error: Specified bridge network ($BRIDGE_NAME) does not exist!"
    echo "Please set up the bridge network or change the BRIDGE_NAME variable to a valid bridge."
    exit 1
fi
check_command_success "Check if bridge network exists"

# Check and create cloud-init file if it doesn't exist
if [ ! -f "$CLOUD_INIT_FILE" ]; then
    echo "==========------------------> Step 0.2: Create cloud-init file for $VM_NAME"
    run_script_from_directory "$SCRIPT_DIR/../../cloud-init" "create-cloud-init.sh" "$VM_NAME" "$CLOUD_INIT_TEMPLATE"
fi

# Create the VM with a combined OS and data disk
echo "Create VM: $VM_NAME with $CPUS CPUs - $MEMORY memory - ${DISK_SIZE} disk - bridge network: $BRIDGE_NAME - max timeout: $LAUNCH_TIMEOUT"
multipass launch --name "$VM_NAME" --cloud-init "$CLOUD_INIT_FILE" --cpus "$CPUS" --memory "$MEMORY" --disk "${DISK_SIZE}" --network "$BRIDGE_NAME" --timeout "$LAUNCH_TIMEOUT"
check_command_success "Create VM with combined OS and data disk"

# Create a folder for data storage within the same disk
echo "Creating /mnt/urbalurbadisk in VM: $VM_NAME"
multipass exec "$VM_NAME" -- sudo mkdir -p /mnt/urbalurbadisk
check_command_success "Create /mnt/urbalurbadisk folder"

# Starting the VM
echo "Starting VM: $VM_NAME"
multipass start "$VM_NAME"
check_command_success "Start VM"

# Display VM information
multipass info "$VM_NAME"
check_command_success "Get VM info"

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
    echo "Login to the VM: $VM_NAME from your host:"
    echo "multipass shell $VM_NAME"
    echo "Disk Information:"
    echo "The VM $VM_NAME has a combined OS and data disk with a maximum size of ${DISK_SIZE}."
    echo "Data folder is available at /mnt/urbalurbadisk."
    echo
fi

exit $ERROR
