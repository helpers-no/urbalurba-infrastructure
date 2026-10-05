#!/bin/bash

# File: hosts/azure-aks/02-azure-aks-setup.sh
#
# Description:
# Configures AKS cluster after creation - merges kubeconfig, installs Traefik,
# applies storage classes, deploys secrets, and validates basic services
#
# Prerequisites:
# - AKS cluster created by 01-azure-aks-create.sh
# - kubectl configured with azure-aks context
#
# Usage:
# ./02-azure-aks-setup.sh

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Functions for colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/azure-aks-config.sh"

if [[ ! -f "$CONFIG_FILE" ]]; then
    print_error "Configuration file not found: $CONFIG_FILE"
    exit 1
fi

source "$CONFIG_FILE"

# Source centralized path library for backwards-compatible path resolution
if [[ -f "/mnt/urbalurbadisk/provision-host/uis/lib/paths.sh" ]]; then
    source "/mnt/urbalurbadisk/provision-host/uis/lib/paths.sh"
fi

# Function to wait for pod to be ready
wait_for_pod() {
    local namespace="$1"
    local label="$2"
    local timeout="${3:-300}"
    
    print_status "Waiting for pod with label $label in namespace $namespace..."
    if kubectl wait --for=condition=ready pod \
        -l "$label" \
        -n "$namespace" \
        --timeout="${timeout}s" >/dev/null 2>&1; then
        print_success "Pod is ready"
        return 0
    else
        print_warning "Pod not ready after ${timeout} seconds"
        return 1
    fi
}

# Main setup flow
main() {
    print_status "Starting Azure AKS cluster setup..."
    
    # Step 1: Merge kubeconfig files
    print_status "Merging kubeconfig files..."
    
    # Check if ansible playbook exists
    ANSIBLE_PLAYBOOK="/mnt/urbalurbadisk/ansible/playbooks/04-merge-kubeconf.yml"
    if [[ -f "$ANSIBLE_PLAYBOOK" ]]; then
        cd /mnt/urbalurbadisk
        ansible-playbook "$ANSIBLE_PLAYBOOK"
        print_success "Kubeconfig files merged"
    else
        print_warning "Ansible playbook not found, using single kubeconfig"
        export KUBECONFIG="$KUBECONFIG_FILE"
    fi
    
    # Set merged kubeconfig
    export KUBECONFIG=/mnt/urbalurbadisk/kubeconfig/kubeconf-all
    
    # Step 2: Switch to azure-aks context
    print_status "Switching to azure-aks context..."
    kubectl config use-context azure-aks
    print_success "Switched to azure-aks context"
    
    # Verify connectivity
    print_status "Verifying cluster connectivity..."
    NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
    if [[ "$NODE_COUNT" -eq 0 ]]; then
        print_error "Cannot connect to cluster or no nodes found"
        exit 1
    fi
    print_success "Connected to cluster with $NODE_COUNT nodes"
    
    # Step 3: Apply storage class aliases
    print_status "Applying storage class aliases..."
    
    STORAGE_MANIFEST="$SCRIPT_DIR/manifests-overrides/000-storage-class-azure-alias.yaml"
    if [[ -f "$STORAGE_MANIFEST" ]]; then
        kubectl apply -f "$STORAGE_MANIFEST"
        print_success "Storage class aliases applied"
    else
        print_error "Storage class manifest not found: $STORAGE_MANIFEST"
        print_error "Please create this file manually or ensure it exists before running setup"
        exit 1
    fi
    
    # Step 4: Deploy secrets
    print_status "Checking for secrets configuration..."

    # Use backwards-compatible path resolution
    if type get_kubernetes_secrets_path &>/dev/null; then
        SECRETS_FILE="$(get_kubernetes_secrets_path)/kubernetes-secrets.yml"
    else
        SECRETS_FILE="/mnt/urbalurbadisk/topsecret/kubernetes/kubernetes-secrets.yml"
    fi
    if [[ -f "$SECRETS_FILE" ]]; then
        print_status "Applying kubernetes secrets..."
        kubectl apply -f "$SECRETS_FILE"
        print_success "Secrets deployed"
    else
        print_warning "Secrets file not found at: $SECRETS_FILE"
        print_warning "Skipping secrets deployment"
    fi
    
    # Step 5: Install Traefik
    print_status "Installing Traefik ingress controller..."
    
    # Add Traefik helm repo
    helm repo add traefik https://traefik.github.io/charts >/dev/null 2>&1 || true
    helm repo update >/dev/null 2>&1
    
    # Check if Traefik is already installed
    if helm list -n kube-system | grep -q traefik; then
        print_warning "Traefik is already installed"
        read -p "Do you want to upgrade it? (y/n): " upgrade_traefik
        if [[ "$upgrade_traefik" == "y" ]]; then
            helm upgrade traefik traefik/traefik \
                -f /mnt/urbalurbadisk/manifests/003-traefik-config.yaml \
                --namespace kube-system
            print_success "Traefik upgraded"
        fi
    else
        # Install Traefik
        helm install traefik traefik/traefik \
            -f /mnt/urbalurbadisk/manifests/003-traefik-config.yaml \
            --namespace kube-system
        print_success "Traefik installed"
    fi
    
    # Wait for Traefik to be ready
    wait_for_pod "kube-system" "app.kubernetes.io/name=traefik" 300
    
    print_status "Infrastructure setup complete!"
    print_status "To deploy services, run:"
    echo "  ./uis deploy <service-name>"
    echo "  ./uis stack install <stack-name>"
    
    # Step 6: Check Traefik external IP
    print_status "Checking Traefik external IP..."
    
    # Wait for external IP assignment (with timeout)
    ATTEMPTS=0
    MAX_ATTEMPTS=24  # 2 minutes
    EXTERNAL_IP=""
    
    while [[ $ATTEMPTS -lt $MAX_ATTEMPTS ]]; do
        EXTERNAL_IP=$(kubectl get svc traefik -n kube-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
        
        if [[ -n "$EXTERNAL_IP" && "$EXTERNAL_IP" != "null" ]]; then
            print_success "✅ External IP assigned: $EXTERNAL_IP"
            break
        fi
        
        if [[ $ATTEMPTS -eq 0 ]]; then
            echo -n "Waiting for external IP assignment"
        fi
        echo -n "."
        sleep 5
        ((ATTEMPTS++))
    done
    
    if [[ -z "$EXTERNAL_IP" || "$EXTERNAL_IP" == "null" ]]; then
        echo
        print_warning "External IP not assigned yet"
        print_status "You can check later with:"
        echo "  kubectl get svc traefik -n kube-system"
    else
        # Test external connectivity
        print_status "Testing external connectivity..."
        if curl -s -o /dev/null -w "%{http_code}" "http://$EXTERNAL_IP" --connect-timeout 5 | grep -q "200\|404"; then
            print_success "✅ Cluster is accessible from internet at http://$EXTERNAL_IP"
        else
            print_warning "⚠️ External IP assigned but not responding yet"
        fi
    fi
    
    # Step 8: Display final status
    echo
    print_success "Azure AKS cluster setup completed!"
    echo
    echo "Cluster Status:"
    echo "==============="
    kubectl get nodes
    echo
    echo "Storage Classes:"
    kubectl get storageclass | grep -E "local-path|microk8s-hostpath|default" || true
    echo
    echo "Infrastructure Services:"
    kubectl get pods --all-namespaces | grep "traefik" || true
    echo
    
    if [[ -n "$EXTERNAL_IP" && "$EXTERNAL_IP" != "null" ]]; then
        echo "External Access:"
        echo "==============="
        echo "URL: http://$EXTERNAL_IP"
        echo
        echo "To control internet access:"
        echo "  ./hosts/azure-aks/toggle-internet-access.sh off  # Disable"
        echo "  ./hosts/azure-aks/toggle-internet-access.sh on   # Enable"
    fi
    
    echo
    print_success "Setup complete! Cluster is ready for service deployment."
}

# Run main function
main "$@"