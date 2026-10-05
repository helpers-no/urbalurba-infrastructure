#!/bin/bash
# File: 01-setup-kubernetes-rancher.sh
# Description: Sets up the Kubernetes environment for Rancher Desktop

set -e

echo "Setting up Kubernetes environment for Rancher Desktop..."

# Ensure kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl not found. Please ensure Rancher Desktop is installed and running."
    exit 1
fi

# Check if we can access the Kubernetes cluster
if ! kubectl get nodes &> /dev/null; then
    echo "Error: Cannot connect to Kubernetes. Please ensure Rancher Desktop is running and Kubernetes is enabled."
    exit 1
fi

# Set the current context to rancher-desktop if it exists
if kubectl config get-contexts | grep -q rancher-desktop; then
    echo "Setting kubectl context to rancher-desktop..."
    kubectl config use-context rancher-desktop
    
    # Create a 'default' context alias that points to the rancher-desktop cluster
    echo "Creating 'default' context alias for rancher-desktop..."
    
    # Get the cluster and user from the rancher-desktop context
    RANCHER_CLUSTER=$(kubectl config view -o jsonpath='{.contexts[?(@.name=="rancher-desktop")].context.cluster}')
    RANCHER_USER=$(kubectl config view -o jsonpath='{.contexts[?(@.name=="rancher-desktop")].context.user}')
    
    # Check if we got the cluster and user
    if [ -n "$RANCHER_CLUSTER" ] && [ -n "$RANCHER_USER" ]; then
        # Create the default context if it doesn't exist
        if ! kubectl config get-contexts | grep -q "^default "; then
            kubectl config set-context default --cluster="$RANCHER_CLUSTER" --user="$RANCHER_USER"
            echo "Created 'default' context pointing to rancher-desktop cluster"
        else
            echo "'default' context already exists, updating it to point to rancher-desktop cluster"
            kubectl config set-context default --cluster="$RANCHER_CLUSTER" --user="$RANCHER_USER"
        fi
        
        # Verify the default context
        echo "Verifying 'default' context..."
        DEFAULT_CLUSTER=$(kubectl config view -o jsonpath='{.contexts[?(@.name=="default")].context.cluster}')
        if [ "$DEFAULT_CLUSTER" = "$RANCHER_CLUSTER" ]; then
            echo "'default' context is correctly set up"
        else
            echo "Warning: 'default' context is not pointing to the expected cluster"
        fi
    else
        echo "Warning: Could not get cluster and user from rancher-desktop context"
    fi
else
    echo "Warning: rancher-desktop context not found. Using current context."
fi

echo "Kubernetes environment setup completed successfully."
exit 0 