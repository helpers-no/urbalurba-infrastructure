#!/bin/bash
# install-raspberry.sh - install all cluster and all software on raspberry
# Must be started in the hosts folder


#TODO: create the script that creates the rasperry ubuntu and installs tailscale

# the path on the mont disk on provision-host
URB_PATH=/mnt/urbalurbadisk
SELECTED_MICROK8S=multipass-microk8s
MICROK8S_CLUSTER_TO_SETUP=raspberry-microk8s

# Ensure the script is run with Bash
if [ -z "$BASH_VERSION" ]; then
    echo "This script must be run with Bash"
    exit 1
fi


# Check if the script is running in the hosts directory
CURRENT_DIR=${PWD##*/}
if [ "$CURRENT_DIR" != "hosts" ]; then
    echo "This script must be run in the hosts dir on provision-host."
    exit 1
fi



# Function to ensure a script runs from its specific directory
run_script_from_directory() {
    local directory=$1
    shift
    local script=$1
    shift
    local args=("$@")

    echo "------------------> Running "$script ${args[*]}" in directory:$directory"
    cd "$directory"
    ./$script "${args[@]}"
    if [ $? -ne 0 ]; then
        echo "Error: $script failed."
        exit 1
    fi
    cd - > /dev/null  # Return to the previous directory and suppress output
}

# Function to select the Kubernetes context
select_k8s_context() {
    local context="$1"
    if kubectl config use-context "$context"; then
        echo "Successfully switched to context: $context"
    else
        echo "Failed to switch to context: $context"
        exit 1
    fi
}

get_kubernetes_secret() {
    local namespace="default"
    local secret_name="urbalurba-secrets"
    local key="$1"
    local value

    value=$(kubectl get secret --namespace "$namespace" "$secret_name" -o jsonpath="{.data.$key}" 2>/dev/null | base64 -d)

    if [ -z "$value" ]; then
        echo "Error: Unable to read $key from Kubernetes secret" >&2
        return 1
    fi

    echo "$value"
}

# Select the Kubernetes context before getting secrets
select_k8s_context "$SELECTED_MICROK8S"



#TODO: echo "==========------------------> Step 1: Create multipass VM named: azure-microk8s"
#run_script_from_directory "$URB_PATH/hosts/azure" "01-azure-vm-create-redcross.sh" "$UBUNTU_VM_USER" "$UBUNTU_VM_USER_PASSWORD" "$TAILSCALE_SECRET" "$VM_INSTANCE"



echo "==========------------------> Step 2: Register VM azure-microk8s in ansible inventory on provision-host"
run_script_from_directory "$URB_PATH/hosts/raspberry-microk8s" "02-raspberry-ansible-inventory.sh"

#
echo "==========------------------> Step 3: Install microk8s cluster on VM azure-microk8s"
run_script_from_directory "$URB_PATH/hosts" "03-raspberry-setup-microk8s.sh" "$MICROK8S_CLUSTER_TO_SETUP"


echo "=============== Got here ================"
echo "secrets are pushed from the local mac-- fix this"
exit 0


#echo "==========------------------> Step 6: Applying secrets to the cluster. You must have set up the secrets file in the topsecret/kubernetes directory"
#run_script_from_directory "topsecret" "update-kubernetes-secrets.sh" 

# this is not relevant for Azure because you cant reach it from the outside
#echo "==========------------------> Step 7: Install local kubeconfig so that you can access the cluster from your local machine"
#run_script_from_directory "topsecret" "kubeconf-copy.sh" 

echo "----------------------> Start the installation of the default apps <----------------------"

echo "==========-------------------> App A: Setup logging and monitoring (Prometheus, Grafana, Loki, and Fluentd)"
run_script_from_directory "kubernetes/default-apps" "04-setup-log-monitor.sh" 

echo "==========-------------------> App B: Setup postgresql database"
run_script_from_directory "kubernetes/default-apps" "05-setup-postgres.sh" 

echo "==========-------------------> App C: Setup redis"
run_script_from_directory "kubernetes/default-apps" "06-setup-redis.sh" 

echo "------------------> App D: Setup Elasticsearch"
run_script_from_directory "kubernetes/default-apps" "07-setup-elasticsearch.sh" 



echo "----------------------> Start networking <----------------------"

echo "------------------> Net 1: Set up tailscale on provision-host and connect it to the tailscale network"
run_script_from_directory "networking" "tailscale/802-tailscale-host-setup.sh provision-host"

echo "------------------> Net 2: Set up tailscale on multipass-microk8s and connect it to the tailscale network"
run_script_from_directory "networking" "tailscale/802-tailscale-host-setup.sh multipass-microk8s"


echo "----------------------> Continue the installation of the default apps <----------------------"

echo "=============== Got here ================"
exit 0

echo "------------------> App E: Setup Gravitee API Management Platform"
run_script_from_directory "kubernetes/default-apps" "08-setup-gravitee.sh GRAVITEE_TEST multipass-microk8s" 



echo "------------------> Finaly store config and status files for: multipass-microk8s"
run_script_from_directory "" "cluster-status.sh multipass-microk8s" 


echo "### cloudflare does not work inside the company TODO: fix or move"
echo "------------------> Net 3: Set Cloudflare tunnel and DNS for multipass-microk8s"
run_script_from_directory "networking" "cloudflare/820-cloudflare-tunnel-setup.sh CLOUDFLARE_TEST"

echo "------------------> Net 4: Deploy the tunnel and expose domains on the internet for multipass-microk8s"
run_script_from_directory "networking" "cloudflare/821-cloudflare-tunnel-deploy.sh CLOUDFLARE_TEST multipass-microk8s"


echo "All steps completed successfully."