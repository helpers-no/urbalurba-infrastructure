#!/bin/bash

# File: hosts/install-azure-aks.sh
#
# Description:
# Main orchestrator script for Azure AKS deployment with Urbalurba Infrastructure
# This script runs INSIDE the provision-host container and coordinates the complete setup
#
# Prerequisites:
# - provision-host container is running (created by ./uis start)
# - Azure CLI is logged in with appropriate permissions
#
# Usage:
# docker exec -it provision-host bash
# cd /mnt/urbalurbadisk
# ./hosts/install-azure-aks.sh

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

print_section() {
    echo
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}$1${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo
}

# Check if we're inside the provision-host container
check_environment() {
    if [[ ! -f /.dockerenv ]] || [[ ! -d /mnt/urbalurbadisk ]]; then
        print_error "This script must run inside the provision-host container"
        echo "Please run:"
        echo "  docker exec -it provision-host bash"
        echo "  cd /mnt/urbalurbadisk"
        echo "  ./hosts/install-azure-aks.sh"
        exit 1
    fi
    
    if [[ "$PWD" != "/mnt/urbalurbadisk" ]]; then
        print_warning "Changing directory to /mnt/urbalurbadisk"
        cd /mnt/urbalurbadisk
    fi
}


# Main installation flow
main() {
    print_section "AZURE AKS INSTALLATION FOR URBALURBA INFRASTRUCTURE"
    
    # Step 0: Environment check
    print_status "Checking environment..."
    check_environment
    print_success "Environment check passed"
    
    # Step 1: Create AKS cluster
    print_section "Step 1: Creating Azure AKS Cluster"
    if [[ -f hosts/azure-aks/01-azure-aks-create.sh ]]; then
        ./hosts/azure-aks/01-azure-aks-create.sh
    else
        print_error "Script not found: hosts/azure-aks/01-azure-aks-create.sh"
        exit 1
    fi
    
    # Step 2: Setup and configure cluster
    print_section "Step 2: Configuring AKS Cluster"
    if [[ -f hosts/azure-aks/02-azure-aks-setup.sh ]]; then
        ./hosts/azure-aks/02-azure-aks-setup.sh
    else
        print_error "Script not found: hosts/azure-aks/02-azure-aks-setup.sh"
        exit 1
    fi
    
    # Step 3: Final validation
    print_section "Step 3: Validation"
    
    print_status "Checking cluster connectivity..."
    export KUBECONFIG=/mnt/urbalurbadisk/kubeconfig/kubeconf-all
    kubectl config use-context azure-aks
    
    NODE_COUNT=$(kubectl get nodes -o json | jq '.items | length')
    if [[ "$NODE_COUNT" -ge 1 ]]; then
        print_success "✅ Cluster has $NODE_COUNT nodes"
    else
        print_error "❌ No nodes found in cluster"
        exit 1
    fi
    
    print_status "Checking Traefik deployment..."
    if kubectl get pods -n kube-system -l app.kubernetes.io/name=traefik --no-headers | grep -q Running; then
        print_success "✅ Traefik is running"
    else
        print_warning "⚠️ Traefik is not running yet"
    fi
    
    print_status "Checking storage classes..."
    if kubectl get storageclass local-path >/dev/null 2>&1; then
        print_success "✅ Storage class aliases configured"
    else
        print_warning "⚠️ Storage class aliases not found"
    fi
    
    # Display cluster access information
    print_section "INSTALLATION COMPLETE!"
    
    echo -e "${GREEN}Azure AKS cluster is ready!${NC}"
    echo
    echo "Cluster Information:"
    echo "==================="
    kubectl get nodes
    echo
    
    # Check if Traefik has external IP
    EXTERNAL_IP=$(kubectl get svc traefik -n kube-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    
    if [[ -n "$EXTERNAL_IP" ]]; then
        echo "External Access:"
        echo "==============="
        echo "Cluster URL: http://$EXTERNAL_IP"
        echo "Status: ✅ Internet accessible"
        echo
        echo "To disable internet access (save costs):"
        echo "  ./hosts/azure-aks/toggle-internet-access.sh off"
    else
        echo "External Access:"
        echo "==============="
        echo "Status: 🔒 Internal only (no external IP)"
        echo
        echo "To enable internet access:"
        echo "  ./hosts/azure-aks/toggle-internet-access.sh on"
    fi
    
    echo
    echo "Context Switching:"
    echo "=================="
    echo "Current context: azure-aks"
    echo
    echo "To switch contexts:"
    echo "  kubectl config use-context rancher-desktop  # Local"
    echo "  kubectl config use-context azure-aks        # Azure"
    echo
    echo "Deploy Services:"
    echo "================"
    echo "To deploy Urbalurba services:"
    echo "  ./uis deploy <service-name>"
    echo "  ./uis stack install <stack-name>"
    echo
    echo "Cleanup:"
    echo "========"
    echo "To destroy the AKS cluster (save costs):"
    echo "  ./hosts/azure-aks/03-azure-aks-cleanup.sh"
    echo
    print_success "Azure AKS installation completed successfully! 🎉"
}

# Run main function
main "$@"