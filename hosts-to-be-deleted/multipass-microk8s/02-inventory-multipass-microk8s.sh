#!/bin/bash
# filename: 02-inventory-multipass-microk8s.sh
# description: Update Ansible inventory with the last IP address of the multipass-microk8s VM
# to be run on the host that run  the multipass VM as it uses multipass command to get the IP address
# usage: ./02-inventory-multipass-microk8s.sh

# Variables
PROVISION_HOST="provision-host"
TARGET_HOST="multipass-microk8s"
MULTIPASS_DIR="$HOME/multipass"
VM_HOST_DIR="$MULTIPASS_DIR/$PROVISION_HOST"
INVENTORY_PLAYBOOK="/mnt/urbalurbadisk/ansible/playbooks/02-update-ansible-inventory.yml"
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

# Ensure the script is run from the correct directory
CURRENT_DIR=${PWD##*/}
if [ "$CURRENT_DIR" != "multipass-microk8s" ]; then
    echo "This script must be run from the folder hosts-to-be-deleted/multipass-microk8s"
    exit 1
fi

# Get the last IP address of the multipass-microk8s VM
LAST_IP=$(multipass info $TARGET_HOST | awk '/IPv4/ {ip=$2} END{print ip}')

if [ -z "$LAST_IP" ]; then
    echo "Error: Could not retrieve the IP address for $TARGET_HOST."
    STATUS+=("Retrieve IP address: Fail")
    ERROR=1
else
    echo "Retrieved IP address for $TARGET_HOST: $LAST_IP"
    STATUS+=("Retrieve IP address: OK")
fi

if [ $ERROR -eq 0 ]; then
    # Call the Ansible playbook on the provision-host
    multipass exec $PROVISION_HOST -- bash -c "cd /mnt/urbalurbadisk/ansible && sudo -u ansible ansible-playbook $INVENTORY_PLAYBOOK -e target_host=$TARGET_HOST -e target_host_ip=$LAST_IP"
    check_command_success "Updating Ansible inventory"
fi

if [ $ERROR -eq 0 ]; then
    # Test the connection using Ansible's ping module
    multipass exec $PROVISION_HOST -- bash -c "cd /mnt/urbalurbadisk/ansible && ansible $TARGET_HOST -m ping"
    check_command_success "Testing connection to $TARGET_HOST"
fi

echo "------ Summary of installation statuses for: $0 ------"
for status in "${STATUS[@]}"; do
    echo "$status"
done

if [ $ERROR -ne 0 ]; then
    echo "---------------- E R R O R --------------------"
    echo "Check the status lines above"
else
    echo "--------------- All OK ------------------------"
fi

exit $ERROR
