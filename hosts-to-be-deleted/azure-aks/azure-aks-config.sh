#!/bin/bash
# filename: azure-aks-config.sh
# description: Configuration variables for Azure AKS deployment
# usage: Source this file before running AKS scripts

# Azure tenant and subscription configuration (from azure-microk8s config)
TENANT_ID="d34df49e-8ff4-46d6-b78d-3cef3261bcd6"
SUBSCRIPTION_ID="68bf1e87-1a04-4500-ab03-cc04054b0862"

# AKS cluster configuration
RESOURCE_GROUP="rg-urbalurba-aks-weu"
CLUSTER_NAME="azure-aks"
LOCATION="westeurope"

# Node configuration
NODE_COUNT=1
NODE_SIZE="Standard_B2ms"

# Additional configuration (adapted from azure-microk8s)
TAGS="CostCenter=IKT Project=kubernetes-test Environment=Sandbox Description='Azure Kubernetes Service cluster for Urbalurba Infrastructure' BusinessOwner=terje.christensen@redcross.no ITOwner=terje.christensen@redcross.no"

# Generate resource names based on configuration
VM_INSTANCE_NAME="vm-${CLUSTER_NAME}-node"
KUBECONFIG_FILE="/mnt/urbalurbadisk/kubeconfig/azure-aks-kubeconf"

# Display configuration (when sourced)
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
    echo "Azure AKS Configuration loaded:"
    echo "  Subscription: $SUBSCRIPTION_ID"
    echo "  Resource Group: $RESOURCE_GROUP"
    echo "  Cluster Name: $CLUSTER_NAME"
    echo "  Location: $LOCATION"
    echo "  Nodes: $NODE_COUNT x $NODE_SIZE"
fi