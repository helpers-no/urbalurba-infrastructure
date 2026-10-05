#!/bin/bash

# File: hosts/azure-aks/manage-aks-cluster.sh
#
# Description:
# Comprehensive management tool for Azure AKS cluster
# Provides internet access control, cluster start/stop, and cost management
#
# Usage:
# ./manage-aks-cluster.sh [command] [options]
#
# Commands:
#   status           - Show cluster and internet access status (default)
#   internet on/off  - Enable/disable internet access
#   cluster stop     - Stop cluster (saves ~$120/month)
#   cluster start    - Start stopped cluster
#   costs            - Show cost information
#   help             - Show this help message

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/azure-aks-config.sh"

if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE" >/dev/null 2>&1
fi

# Function to print colored output
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
    echo -e "${CYAN}=== $1 ===${NC}"
}

# Function to check if we're in provision-host or need to use docker exec
run_kubectl() {
    if [[ -f /.dockerenv ]] && [[ -d /mnt/urbalurbadisk ]]; then
        # We're inside provision-host container
        export KUBECONFIG=/mnt/urbalurbadisk/kubeconfig/kubeconf-all
        kubectl config use-context azure-aks >/dev/null 2>&1
        kubectl "$@"
    else
        # We're on host machine, need to use docker exec
        docker exec provision-host bash -c "export KUBECONFIG=/mnt/urbalurbadisk/kubeconfig/kubeconf-all && kubectl config use-context azure-aks >/dev/null 2>&1 && kubectl $*"
    fi
}

# Function to get current service type and external IP
get_current_status() {
    local service_info
    service_info=$(run_kubectl get svc traefik -n kube-system -o jsonpath='{.spec.type},{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "NotFound,")
    
    local service_type="${service_info%,*}"
    local external_ip="${service_info#*,}"
    
    echo "$service_type,$external_ip"
}

# Function to check cluster state
get_cluster_state() {
    local state
    state=$(az aks show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$CLUSTER_NAME" \
        --query "powerState.code" -o tsv 2>/dev/null || echo "NotFound")
    echo "$state"
}

# Function to display comprehensive status
show_status() {
    print_section "Azure AKS Cluster Status"
    
    # Check Azure cluster state
    local cluster_state
    cluster_state=$(get_cluster_state)
    
    echo "Resource Group: $RESOURCE_GROUP"
    echo "Cluster Name: $CLUSTER_NAME"
    echo "Location: $LOCATION"
    
    if [[ "$cluster_state" == "NotFound" ]]; then
        print_error "❌ Cluster not found or not accessible"
        echo "Make sure you're logged in to Azure: az login"
        return 1
    elif [[ "$cluster_state" == "Stopped" ]]; then
        print_warning "⏸️  CLUSTER STATUS: STOPPED"
        echo "Cluster is stopped to save costs"
        echo "To start: $0 cluster start"
        return 0
    else
        print_success "✅ CLUSTER STATUS: RUNNING"
    fi
    
    # Check Kubernetes connectivity
    if ! run_kubectl get nodes >/dev/null 2>&1; then
        print_warning "Cannot connect to Kubernetes API"
        return 1
    fi
    
    # Show nodes
    echo
    echo "Nodes:"
    run_kubectl get nodes --no-headers | while read line; do
        echo "  $line"
    done
    
    # Check internet access
    print_section "Internet Access Status"
    
    local status_info
    status_info=$(get_current_status)
    local service_type="${status_info%,*}"
    local external_ip="${status_info#*,}"
    
    if [[ "$service_type" == "LoadBalancer" ]]; then
        if [[ -n "$external_ip" && "$external_ip" != "null" ]]; then
            print_success "✅ INTERNET ACCESS: ENABLED"
            echo "External IP: $external_ip"
            echo "Cluster URL: http://$external_ip"
        else
            print_warning "⏳ INTERNET ACCESS: PENDING"
            echo "LoadBalancer configured but IP not yet assigned"
        fi
    else
        print_warning "🔒 INTERNET ACCESS: DISABLED"
        echo "Cluster is only accessible internally"
    fi
    
    # Show cost information
    print_section "Cost Information"
    show_costs_summary
    
    # Show available commands
    print_section "Available Commands"
    echo "  $0 status           # Show this status (default)"
    echo "  $0 internet on      # Enable internet access"
    echo "  $0 internet off     # Disable internet access"
    echo "  $0 cluster stop     # Stop cluster (save ~\$120/month)"
    echo "  $0 cluster start    # Start stopped cluster"
    echo "  $0 costs            # Show detailed cost breakdown"
    echo "  $0 help             # Show full help documentation"
}

# Function to enable internet access
enable_internet() {
    print_status "Enabling internet access..."
    
    local current_type="${1%,*}"
    
    if [[ "$current_type" == "LoadBalancer" ]]; then
        print_warning "Internet access is already enabled"
        return 0
    fi
    
    run_kubectl patch svc traefik -n kube-system -p '{"spec":{"type":"LoadBalancer"}}'
    print_success "Internet access enabled!"
    
    # Wait briefly for IP assignment
    sleep 5
    local status_info
    status_info=$(get_current_status)
    local external_ip="${status_info#*,}"
    
    if [[ -n "$external_ip" && "$external_ip" != "null" ]]; then
        echo "External IP: $external_ip"
    else
        echo "External IP is being assigned..."
        echo "Check status with: $0 status"
    fi
}

# Function to disable internet access
disable_internet() {
    print_status "Disabling internet access..."
    
    local status_info="$1"
    local current_type="${status_info%,*}"
    local external_ip="${status_info#*,}"
    
    if [[ "$current_type" == "ClusterIP" ]]; then
        print_warning "Internet access is already disabled"
        return 0
    fi
    
    if [[ -n "$external_ip" && "$external_ip" != "null" ]]; then
        print_warning "Releasing external IP: $external_ip"
    fi
    
    run_kubectl patch svc traefik -n kube-system -p '{"spec":{"type":"ClusterIP"}}'
    print_success "Internet access disabled!"
}

# Function to stop cluster
stop_cluster() {
    print_status "Stopping AKS cluster to save costs..."
    print_warning "This will make the cluster inaccessible until started again"
    
    read -p "Are you sure you want to stop the cluster? (y/n): " confirm
    if [[ "${confirm,,}" != "y" ]]; then
        echo "Cancelled"
        return 0
    fi
    
    az aks stop \
        --resource-group "$RESOURCE_GROUP" \
        --name "$CLUSTER_NAME" \
        --no-wait
    
    print_success "Cluster stop initiated"
    echo "This may take a few minutes. The cluster will be inaccessible while stopped."
    echo "To restart: $0 cluster start"
}

# Function to start cluster
start_cluster() {
    print_status "Starting AKS cluster..."
    
    az aks start \
        --resource-group "$RESOURCE_GROUP" \
        --name "$CLUSTER_NAME" \
        --no-wait
    
    print_success "Cluster start initiated"
    echo "This may take 3-5 minutes. Check status with: $0 status"
}

# Function to check PIM permissions for cost management
check_cost_permissions() {
    print_status "Checking cost management permissions..."
    
    # Check if we have the required role for cost management
    local has_role=$(az role assignment list \
        --assignee $(az account show --query user.name -o tsv 2>/dev/null) \
        --scope "/subscriptions/$(az account show --query id -o tsv 2>/dev/null)" \
        --query "[?roleDefinitionName=='Contributor' || roleDefinitionName=='Cost Management Contributor' || roleDefinitionName=='Cost Management Reader']" \
        -o json 2>/dev/null | jq length 2>/dev/null || echo "0")
    
    if [[ "$has_role" == "0" ]]; then
        print_warning "Insufficient permissions for cost management API"
        echo
        echo "You need one of these roles:"
        echo "• Contributor"
        echo "• Cost Management Contributor" 
        echo "• Cost Management Reader"
        echo
        echo "To activate PIM role:"
        echo "1. Open: https://portal.azure.com/?feature.msaljs=true#view/Microsoft_Azure_PIMCommon/ActivationMenuBlade/~/azurerbac"
        echo "2. Find and activate appropriate role for subscription"
        echo "3. Wait 1-2 minutes for activation"
        echo "4. Run this command again"
        return 1
    fi
    
    print_success "Cost management permissions verified"
    return 0
}

# Function to get actual Azure costs
get_actual_costs() {
    print_status "Querying Azure Cost Management API..."
    
    # Check permissions first
    if ! check_cost_permissions; then
        return 1
    fi
    
    # Get current month dates
    local start_date=$(date -d "$(date +%Y-%m-01)" +%Y-%m-%d)
    local end_date=$(date -d "$(date +%Y-%m-%d) + 1 month" +%Y-%m-%d)
    
    print_status "Getting costs for resource group: $RESOURCE_GROUP"
    print_status "Period: $start_date to $end_date"
    
    # Query Azure costs for the resource group
    local cost_data
    if ! cost_data=$(az consumption usage list \
        --start-date "$start_date" \
        --end-date "$end_date" \
        --query "[?contains(instanceId, '$RESOURCE_GROUP')].[{name:meterName, cost:pretaxCost, currency:currency}]" \
        -o json 2>/dev/null); then
        
        print_warning "Failed to query detailed usage data"
        print_status "Trying alternative cost query..."
        
        # Try simpler cost query
        print_status "Trying cost management query..."
        if cost_data=$(az costmanagement query \
            --type "Usage" \
            --dataset-aggregation name="PreTaxCost" function="Sum" \
            --dataset-grouping name="ResourceGroup" type="Dimension" \
            --timeframe "MonthToDate" \
            --scope "/subscriptions/$(az account show --query id -o tsv)" \
            --query "rows[?[1]=='$RESOURCE_GROUP'][0]" \
            -o tsv 2>/dev/null); then
            
            if [[ -n "$cost_data" && "$cost_data" != "null" ]]; then
                echo "💰 Actual month-to-date cost: \$$(echo "$cost_data" | awk '{printf "%.2f", $1}')"
                return 0
            fi
        fi
        
        # Try different time periods and scopes
        print_status "Trying last 7 days query..."
        if cost_data=$(az costmanagement query \
            --type "Usage" \
            --dataset-aggregation name="PreTaxCost" function="Sum" \
            --dataset-grouping name="ResourceGroup" type="Dimension" \
            --timeframe "WeekToDate" \
            --scope "/subscriptions/$(az account show --query id -o tsv)" \
            --query "rows[?[1]=='$RESOURCE_GROUP'][0]" \
            -o tsv 2>/dev/null); then
            
            if [[ -n "$cost_data" && "$cost_data" != "null" ]]; then
                echo "💰 Week-to-date cost: \$$(echo "$cost_data" | awk '{printf "%.2f", $1}')"
                return 0
            fi
        fi
        
        # Try billing period
        print_status "Trying billing period query..."
        if cost_data=$(az costmanagement query \
            --type "Usage" \
            --dataset-aggregation name="PreTaxCost" function="Sum" \
            --dataset-grouping name="ResourceGroup" type="Dimension" \
            --timeframe "BillingMonthToDate" \
            --scope "/subscriptions/$(az account show --query id -o tsv)" \
            --query "rows[?[1]=='$RESOURCE_GROUP'][0]" \
            -o tsv 2>/dev/null); then
            
            if [[ -n "$cost_data" && "$cost_data" != "null" ]]; then
                echo "💰 Billing month-to-date cost: \$$(echo "$cost_data" | awk '{printf "%.2f", $1}')"
                return 0
            fi
        fi
        
        # Check subscription level costs
        print_status "Checking subscription-level costs..."
        if total_cost=$(az costmanagement query \
            --type "Usage" \
            --dataset-aggregation name="PreTaxCost" function="Sum" \
            --timeframe "MonthToDate" \
            --scope "/subscriptions/$(az account show --query id -o tsv)" \
            --query "rows[0][0]" \
            -o tsv 2>/dev/null); then
            
            if [[ -n "$total_cost" && "$total_cost" != "null" && "$total_cost" != "0" ]]; then
                echo "💰 Total subscription cost this month: \$$(echo "$total_cost" | awk '{printf "%.2f"}')"
                echo "ℹ️  (Unable to isolate costs for resource group: $RESOURCE_GROUP)"
                
                # If cluster is old enough, this might indicate a real issue
                local cluster_age_hours
                cluster_age_hours=$(get_cluster_age | grep -o '[0-9]\+' | head -1)
                if [[ -n "$cluster_age_hours" && "$cluster_age_hours" -gt 48 ]]; then
                    echo "⚠️  Cluster is $cluster_age_hours hours old but no specific cost data found"
                    echo "   This might indicate an Azure API issue or billing configuration problem"
                fi
                return 0
            fi
        fi
        
        # Since we can't get cluster age reliably, assume it's mature if we're trying costs
        print_warning "Azure Cost Management API has no data, but Portal likely does"
        echo "This is common - Azure Portal often has more recent cost data than the API."
        echo
        echo "💡 View actual costs in Azure Portal:"
        local subscription_id
        subscription_id=$(az account show --query id -o tsv 2>/dev/null)
        if [[ -n "$subscription_id" ]]; then
            echo "🔗 Direct link:"
            echo "   https://portal.azure.com/#view/Microsoft_Azure_CostManagement/Menu/~/costanalysis/scope/%2Fsubscriptions%2F${subscription_id}"
            echo
            echo "📊 Filter by Resource Group: $RESOURCE_GROUP"
            echo "📅 Time range: This month or last 30 days"
        else
            echo "🔗 Manual navigation:"
            echo "   1. Go to portal.azure.com"
            echo "   2. Search for 'Cost Management + Billing'"
            echo "   3. Go to Cost Analysis"
            echo "   4. Filter by Resource Group: $RESOURCE_GROUP"
        fi
        
        return 1
    fi
    
    if [[ "$cost_data" == "[]" ]] || [[ -z "$cost_data" ]]; then
        print_warning "No cost data found for resource group: $RESOURCE_GROUP"
        echo "This could be due to:"
        echo "• Very new cluster (costs not yet recorded)"
        echo "• No billable usage yet"
        return 1
    fi
    
    # Parse and display cost data
    print_success "Actual Azure costs found:"
    echo "$cost_data" | jq -r '.[] | "• " + .name + ": $" + (.cost | tostring) + " " + .currency' 2>/dev/null || {
        echo "Raw cost data: $cost_data"
    }
}

# Function to get cluster age
get_cluster_age() {
    local created_date
    created_date=$(az aks show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$CLUSTER_NAME" \
        --query "systemData.createdAt" -o tsv 2>/dev/null || echo "")
    
    if [[ -n "$created_date" && "$created_date" != "null" ]]; then
        # Convert to epoch time for calculation
        local created_epoch
        local current_epoch
        
        # Use a more portable date command
        if command -v gdate >/dev/null 2>&1; then
            # macOS with GNU date
            created_epoch=$(gdate -d "$created_date" +%s 2>/dev/null || echo "0")
        else
            # Linux date
            created_epoch=$(date -d "$created_date" +%s 2>/dev/null || echo "0")
        fi
        
        current_epoch=$(date +%s)
        
        if [[ "$created_epoch" != "0" && "$created_epoch" -lt "$current_epoch" ]]; then
            local age_seconds=$((current_epoch - created_epoch))
            local age_hours=$((age_seconds / 3600))
            local age_days=$((age_hours / 24))
            
            if [[ $age_days -gt 0 ]]; then
                echo "${age_days} days, $((age_hours % 24)) hours"
            else
                echo "${age_hours} hours"
            fi
            return 0
        fi
    fi
    
    echo "unknown"
    return 1
}

# Function to show cost information
show_costs() {
    print_section "Azure AKS Cost Analysis"
    
    # Check if we have required configuration
    if [[ -z "$RESOURCE_GROUP" ]] || [[ -z "$CLUSTER_NAME" ]]; then
        print_error "Missing cluster configuration"
        echo "Resource Group: ${RESOURCE_GROUP:-not set}"
        echo "Cluster Name: ${CLUSTER_NAME:-not set}"
        return 1
    fi
    
    echo "Cluster Configuration:"
    echo "  Resource Group: $RESOURCE_GROUP"
    echo "  Cluster Name: $CLUSTER_NAME"
    echo "  Nodes: $NODE_COUNT x $NODE_SIZE"
    echo "  Location: $LOCATION"
    
    # Get cluster age with error handling
    local cluster_age
    print_status "Getting cluster information..."
    if cluster_age=$(get_cluster_age 2>/dev/null); then
        echo "  Cluster Age: $cluster_age"
    else
        print_warning "Unable to determine cluster age"
        echo "  Cluster Age: unknown"
    fi
    echo
    
    # Try to get actual costs first
    print_section "📊 Actual Costs (Azure Cost Management)"
    if ! get_actual_costs; then
        echo
        print_section "📊 Cost Estimates (Fallback)"
        show_costs_summary
        echo
        echo "💡 To see actual costs:"
        echo "  • Check Azure Portal > Cost Management"
        echo "  • Ensure Cost Management API permissions"
        echo "  • Wait 24-48 hours for new resources"
    else
        echo
        print_section "📊 Cost Estimates (For Comparison)"
        show_costs_summary
    fi
    
    print_section "💰 Cost Optimization Commands"
    echo
    echo "1. Disable Internet Access (save ~\$20/month):"
    echo "   $0 internet off"
    echo
    echo "2. Stop Cluster When Not in Use (save ~\$120/month):"
    echo "   $0 cluster stop"
    echo
    echo "3. Start Cluster When Needed:"
    echo "   $0 cluster start"
    echo
    echo "4. Complete Cleanup (save all costs):"
    echo "   $SCRIPT_DIR/03-azure-aks-cleanup.sh --full"
    echo
    
    # Show budget recommendations
    print_section "💡 Cost Management Tips"
    echo "• Set up budget alerts in Azure Portal"
    echo "• Monitor costs daily during initial deployment"
    echo "• Use Azure Cost Management for detailed breakdowns"
    echo "• Consider Reserved Instances for long-term deployments"
    
    # Check current status for recommendations
    local cluster_state
    cluster_state=$(get_cluster_state)
    
    if [[ "$cluster_state" == "Running" ]]; then
        local status_info
        status_info=$(get_current_status)
        local service_type="${status_info%,*}"
        
        echo
        print_section "⚡ Immediate Savings Opportunities"
        
        if [[ "$service_type" == "LoadBalancer" ]]; then
            echo "• Internet access is enabled - disable when not needed"
            echo "  Command: $0 internet off"
        fi
        
        echo "• Cluster is running - stop during off-hours"
        echo "  Command: $0 cluster stop"
    fi
}

# Function to show cost summary (estimates only)
show_costs_summary() {
    local cluster_state
    cluster_state=$(get_cluster_state)
    
    local monthly_compute=120  # 2x Standard_B2ms
    local monthly_storage=30   # Managed disks
    local monthly_lb=20        # LoadBalancer
    
    echo "📊 Estimated Costs (rough approximation):"
    
    if [[ "$cluster_state" == "Stopped" ]]; then
        echo "💰 Current: ~\$${monthly_storage}/month (storage only)"
        echo "💤 Savings: ~\$${monthly_compute}/month (compute stopped)"
    else
        local status_info
        status_info=$(get_current_status)
        local service_type="${status_info%,*}"
        
        if [[ "$service_type" == "LoadBalancer" ]]; then
            local total=$((monthly_compute + monthly_storage + monthly_lb))
            echo "💰 Current: ~\$${total}/month"
            echo "   • Compute: ~\$${monthly_compute}/month"
            echo "   • Storage: ~\$${monthly_storage}/month"
            echo "   • LoadBalancer: ~\$${monthly_lb}/month"
        else
            local total=$((monthly_compute + monthly_storage))
            echo "💰 Current: ~\$${total}/month"
            echo "   • Compute: ~\$${monthly_compute}/month"
            echo "   • Storage: ~\$${monthly_storage}/month"
            echo "   ✅ Saving: ~\$${monthly_lb}/month (no LoadBalancer)"
        fi
    fi
    
    echo "ℹ️  For actual costs, run: $0 costs"
}

# Function to show help
show_help() {
    echo "Azure AKS Cluster Management Tool"
    echo
    echo "Usage: $0 [command] [options]"
    echo
    echo "Commands:"
    echo "  status           Show cluster and internet access status (default)"
    echo "  internet on      Enable internet access (LoadBalancer)"
    echo "  internet off     Disable internet access (ClusterIP only)"
    echo "  cluster stop     Stop the AKS cluster (save ~\$120/month)"
    echo "  cluster start    Start a stopped AKS cluster"
    echo "  costs           Show detailed cost information"
    echo "  help            Show this help message"
    echo
    echo "Examples:"
    echo "  $0                    # Show current status"
    echo "  $0 internet off       # Disable internet to save costs"
    echo "  $0 cluster stop       # Stop cluster overnight/weekend"
    echo "  $0 costs             # View cost breakdown"
    echo
    echo "Configuration:"
    echo "  Resource Group: ${RESOURCE_GROUP:-not set}"
    echo "  Cluster Name: ${CLUSTER_NAME:-not set}"
    echo "  Config File: $CONFIG_FILE"
}

# Main script logic
main() {
    local command="${1:-status}"
    local option="${2:-}"
    
    # Check configuration is loaded
    if [[ -z "$RESOURCE_GROUP" ]] || [[ -z "$CLUSTER_NAME" ]]; then
        print_error "Configuration not loaded. Check $CONFIG_FILE"
        exit 1
    fi
    
    case "$command" in
        "status")
            show_status
            ;;
        "internet")
            case "$option" in
                "on"|"enable")
                    local status_info
                    status_info=$(get_current_status)
                    enable_internet "$status_info"
                    ;;
                "off"|"disable")
                    local status_info
                    status_info=$(get_current_status)
                    disable_internet "$status_info"
                    ;;
                *)
                    print_error "Usage: $0 internet [on|off]"
                    exit 1
                    ;;
            esac
            ;;
        "cluster")
            case "$option" in
                "stop")
                    stop_cluster
                    ;;
                "start")
                    start_cluster
                    ;;
                *)
                    print_error "Usage: $0 cluster [stop|start]"
                    exit 1
                    ;;
            esac
            ;;
        "costs"|"cost")
            show_costs
            ;;
        "help"|"-h"|"--help")
            show_help
            ;;
        *)
            print_error "Unknown command: $command"
            echo "Use '$0 help' for usage information"
            exit 1
            ;;
    esac
}

# Run main function with all arguments
main "$@"