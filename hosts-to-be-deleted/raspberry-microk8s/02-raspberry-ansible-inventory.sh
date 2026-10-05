#!/bin/bash
# filename: 02-raspberry-ansible-inventory.sh
# description: Update Ansible inventory with the IP address of the VM and the cluster name
# To be run on provision-host VM



# Variables
CONFIG_FILE="./raspberry-microk8s.sh"
#The config file has the variables: 
#filename: raspberry-microk8s.sh
#description: manually created created info about the raspberry
#TAILSCALE_IP=the ip in tailscale
#CLUSTER_NAME=cluster name./
#HOST_NAME= hostname


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
if [ "$CURRENT_DIR" != "raspberry-microk8s" ]; then
    echo "This script must be run from the folder hosts-to-be-deleted/raspberry-microk8s"
    exit 1
fi



# Check if the file config filen is present
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Info about the cluster is not in the file $CLOUD_INIT_FILE"
    echo "Please ensure the file is present at the specified path."
    exit 1
fi

# Source the configuration file
source "$CONFIG_FILE"

# TODO: check that the variables TAILSCALE_IP, CLUSTER_NAME  are set



if [ $ERROR -eq 0 ]; then
    # Call the Ansible playbook on the provision-host
    sudo -u ansible ansible-playbook $INVENTORY_PLAYBOOK -e target_host="$CLUSTER_NAME" -e target_host_ip="$TAILSCALE_IP"
    check_command_success "Updating Ansible inventory"
fi

if [ $ERROR -eq 0 ]; then
    # Test the connection using Ansible's ping module
    cd /mnt/urbalurbadisk/ansible && ansible "$CLUSTER_NAME" -m ping
    check_command_success "Testing connection to $CLUSTER_NAME"
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
