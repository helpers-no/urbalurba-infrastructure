#!/bin/bash
# filename: 03-raspberry-setup-microk8s.sh
# description: Setup microk8s on target-host. Sets up storage and ingress and a test hello world web page on /tst/nginx
# This script is meant to run directly on provision-host
# usage: ./03-cloud-setup-microk8s.sh <target-host>
# example: ./03-cloud-setup-microk8s.sh azure-microk8s

# Ensure the script is run with Bash
if [ -z "$BASH_VERSION" ]; then
    echo "This script must be run with Bash"
    exit 1
fi

# Variables
PLAYBOOK_PATH_INSTALL_MICROK8S="/mnt/urbalurbadisk/ansible/playbooks/03-install-microk8s.yml"
PLAYBOOK_PATH_MERGE_KUBECONF="/mnt/urbalurbadisk/ansible/playbooks/04-merge-kubeconf.yml"

PLAYBOOK_PATH_SETUP_STORAGE="/mnt/urbalurbadisk/ansible/playbooks/010-setup-hostpath-storage.yml"
PLAYBOOK_PATH_SETUP_INGRESS="/mnt/urbalurbadisk/ansible/playbooks/020-setup-tstweb-nginx.yml"

STATUS=()
ERROR=0

# Check if TARGET_HOST is provided as an argument
if [ -z "$1" ]; then
    echo "Error: TARGET_HOST must be provided as an argument"
    echo "Usage: $0 <target-host>"
    exit 1
else
    TARGET_HOST="$1"
fi

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
if [ ! -d "/mnt/urbalurbadisk/hosts" ]; then
    echo "This script must be run on provision-host with access to /mnt/urbalurbadisk/hosts"
    exit 1
fi

# Change to the correct directory for running ansible commands
cd /mnt/urbalurbadisk/ansible || exit 1

# Test Ansible connection
ansible "$TARGET_HOST" -m ping
check_command_success "Testing connection to $TARGET_HOST"

#TODO: remove this because this part is done in cloud-init
#if [ $ERROR -eq 0 ]; then
#    echo "Installing microk8s on $TARGET_HOST... using the playbook $PLAYBOOK_PATH_INSTALL_MICROK8S"
#    sudo -u ansible ansible-playbook $PLAYBOOK_PATH_INSTALL_MICROK8S -e target_host="$TARGET_HOST"
#    check_command_success "Installing microk8s on $TARGET_HOST"
#fi

if [ $ERROR -eq 0 ]; then
    echo "Merging kubeconf files into one ... using the playbook $PLAYBOOK_PATH_MERGE_KUBECONF"
    sudo -u ansible ansible-playbook $PLAYBOOK_PATH_MERGE_KUBECONF
    check_command_success "Merging kubeconf files into one"
fi


#TODO: done in cloud-init
#if [ $ERROR -eq 0 ]; then
#    echo "Setting up storage on $TARGET_HOST... using the playbook $PLAYBOOK_PATH_SETUP_STORAGE"
#    sudo -u ansible ansible-playbook $PLAYBOOK_PATH_SETUP_STORAGE -e target_host="$TARGET_HOST"
#    check_command_success "Setting up storage on $TARGET_HOST"
#fi

if [ $ERROR -eq 0 ]; then
    echo "Setting up Ingress on $TARGET_HOST... using the playbook $PLAYBOOK_PATH_SETUP_INGRESS"
    sudo -u ansible ansible-playbook $PLAYBOOK_PATH_SETUP_INGRESS -e target_host="$TARGET_HOST"
    check_command_success "Setting up Ingress on $TARGET_HOST"
fi

echo "------ Summary of installation statuses for: $0 ------"
for status in "${STATUS[@]}"; do
    echo "$status"
done

if [ $ERROR -ne 0 ]; then
    echo "---------------- E R R O R --------------------"
    echo "Check the error messages above"
else
    echo "--------------- All OK ------------------------"
fi

exit $ERROR