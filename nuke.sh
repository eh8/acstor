#!/usr/bin/env bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# Global variables for caching cluster status
declare -A CLUSTER_STATUS_CACHE
declare -A CLUSTER_LAST_CHECKED
CACHE_TIMEOUT=300  # 5 minutes

# Global variables for script behavior
DRY_RUN=true  # Default to dry-run for safety
SCRIPT_MODE=""
INSPECT_MODE=false

# Function to print colored messages
print_color() {
    local color="$1"
    local message="$2"
    echo -e "${color}${message}${NC}"
}

# Function to show usage information
show_usage() {
    echo "Usage: $0 [OPTIONS] [MODE]"
    echo ""
    print_color "$CYAN" "🚀 Nuke Script - Destructive Operations Utility"
    echo ""
    print_color "$WHITE" "MODES:"
    print_color "$YELLOW" "  contexts     Clean up stale/unreachable kubectl contexts"
    print_color "$YELLOW" "  resources    Delete all Azure resource groups matching pattern"
    echo ""
    print_color "$WHITE" "OPTIONS:"
    print_color "$RED" "  --delete         Actually execute destructive operations (DANGEROUS!)"
    print_color "$YELLOW" "  --inspect        Show detailed resource information (use with resources)"
    print_color "$YELLOW" "  --help, -h       Show this help message"
    echo ""
    print_color "$WHITE" "EXAMPLES:"
    print_color "$GREEN" "  $0 contexts              # Preview context cleanup (SAFE - default)"
    print_color "$GREEN" "  $0 resources             # Preview resource deletion (SAFE - default)"
    print_color "$GREEN" "  $0 resources --inspect   # Preview with detailed resource information"
    print_color "$RED" "  $0 contexts --delete     # Actually remove stale contexts (DANGEROUS!)"
    print_color "$RED" "  $0 resources --delete    # Actually delete resource groups (DANGEROUS!)"
    echo ""
    print_color "$GREEN" "💡 TIP: By default, operations run in preview mode (dry-run)"
    echo ""
    print_color "$RED" "⚠️  WARNING: Operations with --delete are DESTRUCTIVE and cannot be undone!"
    echo ""
}

# Function to check if in dry-run mode
is_dry_run() {
    [ "$DRY_RUN" = true ]
}

# Function to print dry-run banner
show_dry_run_banner() {
    if is_dry_run; then
        print_color "$GREEN" "┌─────────────────────────────────────────────────────────┐"
        print_color "$GREEN" "│                 🔍 PREVIEW MODE (DEFAULT)               │"
        print_color "$GREEN" "│              No changes will be made                    │"
        print_color "$GREEN" "└─────────────────────────────────────────────────────────┘"
        echo ""
    else
        print_color "$RED" "┌─────────────────────────────────────────────────────────┐"
        print_color "$RED" "│              ⚠️  DESTRUCTIVE MODE ACTIVE ⚠️             │"
        print_color "$RED" "│           Changes WILL be made and are PERMANENT        │"
        print_color "$RED" "└─────────────────────────────────────────────────────────┘"
        echo ""
    fi
}

# Function to format dry-run messages
dry_run_message() {
    local message="$1"
    if is_dry_run; then
        print_color "$GREEN" "🔍 PREVIEW: $message"
    else
        print_color "$YELLOW" "⚠️  EXECUTING: $message"
    fi
}

# Function to parse command line arguments
parse_arguments() {
    local args=()
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --delete)
                DRY_RUN=false
                shift
                ;;
            --inspect)
                INSPECT_MODE=true
                shift
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            contexts|resources)
                if [ -n "$SCRIPT_MODE" ]; then
                    print_color "$RED" "❌ Multiple modes specified: $SCRIPT_MODE and $1"
                    exit 1
                fi
                SCRIPT_MODE="$1"
                shift
                ;;
            *)
                print_color "$RED" "❌ Unknown option: $1"
                echo ""
                show_usage
                exit 1
                ;;
        esac
    done
    
    if [ -z "$SCRIPT_MODE" ]; then
        show_usage
        exit 0
    fi
}

# Function to get all kubectl contexts
get_contexts() {
    kubectl config get-contexts -o name 2>/dev/null || true
}

# Function to get current context
get_current_context() {
    kubectl config current-context 2>/dev/null || echo "none"
}

# Function to extract resource group and cluster name from context
parse_aks_context() {
    local context="$1"
    if [[ "$context" =~ ^(.+)_(.+)_(.+)$ ]]; then
        local cluster_name="${BASH_REMATCH[1]}"
        local resource_group="${BASH_REMATCH[2]}"
        echo "RG: $resource_group | Cluster: $cluster_name"
    fi
}

# Function to test cluster connectivity
test_cluster_connectivity() {
    local context="$1"
    local timeout="${2:-3}"
    local original_context=$(get_current_context)
    local status="unknown"
    
    # Check cache first
    local current_time=$(date +%s)
    if [[ -n "${CLUSTER_LAST_CHECKED[$context]:-}" ]]; then
        local last_check="${CLUSTER_LAST_CHECKED[$context]}"
        local time_diff=$((current_time - last_check))
        if [ $time_diff -lt $CACHE_TIMEOUT ]; then
            echo "${CLUSTER_STATUS_CACHE[$context]}"
            return 0
        fi
    fi
    
    # Test connectivity
    if kubectl config use-context "$context" &>/dev/null; then
        if timeout "$timeout" kubectl cluster-info &>/dev/null; then
            status="active"
        else
            status="unreachable"
        fi
    else
        status="error"
    fi
    
    # Cache the result
    CLUSTER_STATUS_CACHE[$context]="$status"
    CLUSTER_LAST_CHECKED[$context]="$current_time"
    
    # Switch back to original context
    kubectl config use-context "$original_context" &>/dev/null 2>&1 || true
    
    echo "$status"
}

# Function to clean up stale kubectl contexts
nuke_stale_contexts() {
    show_dry_run_banner
    
    if is_dry_run; then
        print_color "$CYAN" "🔍 Kubectl Context Cleanup Preview"
    else
        print_color "$RED" "💥 Kubectl Context Cleanup - DESTRUCTIVE MODE"
    fi
    echo ""
    
    # Check prerequisites
    if ! command -v kubectl &>/dev/null; then
        print_color "$RED" "❌ kubectl is not installed or not in PATH"
        exit 1
    fi
    
    # Get all contexts
    mapfile -t contexts < <(get_contexts)
    
    if [ ${#contexts[@]} -eq 0 ]; then
        print_color "$RED" "❌ No kubectl contexts found!"
        exit 1
    fi
    
    dry_run_message "Scanning ${#contexts[@]} kubectl contexts for stale/unreachable clusters..."
    echo ""
    
    local stale_contexts=()
    local active_contexts=()
    local current=0
    
    # Find stale/unreachable clusters
    for context in "${contexts[@]}"; do
        current=$((current + 1))
        printf "\r  [%d/%d] Testing: %s" $current ${#contexts[@]} "$context"
        
        local status=$(test_cluster_connectivity "$context" 3)
        if [[ "$status" == "unreachable" || "$status" == "error" ]]; then
            stale_contexts+=("$context")
        else
            active_contexts+=("$context")
        fi
    done
    
    echo ""
    echo ""
    
    if [ ${#stale_contexts[@]} -eq 0 ]; then
        print_color "$GREEN" "🎉 No stale contexts found!"
        print_color "$BLUE" "All ${#contexts[@]} kubectl contexts are reachable."
        exit 0
    fi
    
    # Show detailed analysis
    if is_dry_run; then
        print_color "$GREEN" "📊 ANALYSIS RESULTS:"
        echo ""
        print_color "$WHITE" "Contexts Summary:"
        print_color "$GREEN" "  ✅ Active contexts: ${#active_contexts[@]}"
        print_color "$RED" "  ❌ Stale contexts: ${#stale_contexts[@]}"
        echo ""
        
        if [ ${#active_contexts[@]} -gt 0 ]; then
            print_color "$WHITE" "Active contexts (will be kept):"
            for context in "${active_contexts[@]}"; do
                print_color "$GREEN" "  ✅ $context"
            done
            echo ""
        fi
        
        print_color "$WHITE" "Stale contexts (would be deleted):"
    else
        print_color "$RED" "⚠️  WARNING: Stale Context Cleanup"
        echo ""
        print_color "$YELLOW" "Found ${#stale_contexts[@]} stale/unreachable contexts that will be deleted:"
    fi
    
    echo ""
    for context in "${stale_contexts[@]}"; do
        if is_dry_run; then
            print_color "$YELLOW" "  🔍 $context"
        else
            print_color "$RED" "  ❌ $context"
        fi
        local context_info=$(parse_aks_context "$context")
        if [ -n "$context_info" ]; then
            print_color "$BLUE" "     $context_info"
        fi
    done
    
    echo ""
    
    if is_dry_run; then
        print_color "$GREEN" "🔍 PREVIEW SUMMARY:"
        print_color "$GREEN" "  • Would delete ${#stale_contexts[@]} stale context(s)"
        print_color "$GREEN" "  • Would keep ${#active_contexts[@]} active context(s)"
        print_color "$BLUE" "  • Run with --delete to execute these changes"
        exit 0
    else
        echo ""
        print_color "$YELLOW" "Deleting stale contexts..."
        local success_count=0
        for context in "${stale_contexts[@]}"; do
            if kubectl config delete-context "$context" &>/dev/null; then
                print_color "$GREEN" "✅ Deleted: $context"
                success_count=$((success_count + 1))
                # Clear from cache
                unset CLUSTER_STATUS_CACHE["$context"]
                unset CLUSTER_LAST_CHECKED["$context"]
            else
                print_color "$RED" "❌ Failed to delete: $context"
            fi
        done
        echo ""
        print_color "$GREEN" "Successfully deleted $success_count context(s)."
    fi
}

# Function to delete Azure resource groups
nuke_azure_resources() {
    show_dry_run_banner
    
    if is_dry_run; then
        print_color "$CYAN" "🔍 Azure Resource Group Deletion Preview"
    else
        print_color "$RED" "💥 Azure Resource Group Deletion - DESTRUCTIVE MODE"
    fi
    echo ""
    
    # Check prerequisites
    if ! command -v az &>/dev/null; then
        print_color "$RED" "❌ Azure CLI is not installed or not in PATH"
        exit 1
    fi
    
    # Check if logged into Azure
    if ! az account show &>/dev/null; then
        print_color "$RED" "❌ Not logged into Azure CLI"
        print_color "$BLUE" "Run 'az login' to authenticate with Azure."
        exit 1
    fi
    
    # Get resource groups matching pattern
    dry_run_message "Scanning for resource groups matching pattern 'ericcheng-*'..."
    
    mapfile -t resource_groups < <(az group list --query "[?contains(name, 'ericcheng-')].name" -o tsv)
    
    if [ ${#resource_groups[@]} -eq 0 ]; then
        print_color "$GREEN" "🎉 No matching resource groups found!"
        print_color "$BLUE" "No resource groups matching 'ericcheng-*' pattern."
        exit 0
    fi
    
    echo ""
    
    # Show detailed analysis
    if is_dry_run; then
        print_color "$GREEN" "📊 ANALYSIS RESULTS:"
        echo ""
        print_color "$WHITE" "Found ${#resource_groups[@]} resource groups matching pattern:"
    else
        print_color "$RED" "⚠️  WARNING: Resource Group Deletion"
        echo ""
        print_color "$YELLOW" "Found ${#resource_groups[@]} resource groups that will be PERMANENTLY deleted:"
    fi
    
    echo ""
    
    local total_resources=0
    local detailed_info=()
    
    for rg in "${resource_groups[@]}"; do
        if [ "$INSPECT_MODE" = true ]; then
            # Show detailed info when --inspect is used
            local location=$(az group show --name "$rg" --query location -o tsv 2>/dev/null || echo "unknown")
            local resource_count=$(az resource list --resource-group "$rg" --query "length(@)" -o tsv 2>/dev/null || echo "0")
            
            # Safely add to total (handle non-numeric values)
            if [[ "$resource_count" =~ ^[0-9]+$ ]]; then
                total_resources=$((total_resources + resource_count))
            fi
            
            if is_dry_run; then
                print_color "$YELLOW" "  🔍 $rg"
                print_color "$BLUE" "     Location: $location | Resources: $resource_count"
                
                # Get more detailed resource information in inspect mode
                if [[ "$resource_count" =~ ^[0-9]+$ ]] && [ "$resource_count" -gt 0 ]; then
                    local resource_types=$(az resource list --resource-group "$rg" --query "[].type" -o tsv 2>/dev/null | sort | uniq -c | sort -nr)
                    if [ -n "$resource_types" ]; then
                        print_color "$BLUE" "     Resource types:"
                        while IFS= read -r type_info; do
                            print_color "$BLUE" "       • $type_info"
                        done <<< "$resource_types"
                    fi
                fi
            else
                print_color "$RED" "  💥 $rg"
                print_color "$BLUE" "     Location: $location | Resources: $resource_count"
            fi
            echo ""
        else
            # Show only resource group name by default (faster)
            if is_dry_run; then
                print_color "$YELLOW" "  🔍 $rg"
            else
                print_color "$RED" "  💥 $rg"
            fi
        fi
    done
    
    if is_dry_run; then
        print_color "$GREEN" "🔍 PREVIEW SUMMARY:"
        print_color "$GREEN" "  • Would delete ${#resource_groups[@]} resource group(s)"
        if [ "$INSPECT_MODE" = true ]; then
            print_color "$GREEN" "  • Total resources affected: $total_resources"
            print_color "$YELLOW" "  • Estimated cost impact: Run 'az consumption usage list' for cost analysis"
        fi
        print_color "$RED" "  • Run with --delete to execute these deletions"
        if [ "$INSPECT_MODE" = false ]; then
            print_color "$BLUE" "  • Use --inspect to see detailed resource information"
        fi
        echo ""
        print_color "$RED" "⚠️  Remember: Resource group deletion is PERMANENT and IRREVERSIBLE!"
        exit 0
    else
        print_color "$RED" "⚠️  This will DELETE ALL RESOURCES in these groups!"
        if [ "$INSPECT_MODE" = true ]; then
            print_color "$RED" "⚠️  Total resources to be deleted: $total_resources"
        fi
        echo ""
        print_color "$YELLOW" "Deleting resource groups (no-wait mode)..."
        local success_count=0
        
        for rg in "${resource_groups[@]}"; do
            if az group delete --name "$rg" --yes --no-wait &>/dev/null; then
                print_color "$GREEN" "✅ Deletion initiated: $rg"
                success_count=$((success_count + 1))
            else
                print_color "$RED" "❌ Failed to delete: $rg"
            fi
        done
        
        echo ""
        print_color "$GREEN" "Successfully initiated deletion of $success_count resource group(s)."
        print_color "$BLUE" "Note: Deletions are running in the background and may take several minutes to complete."
    fi
}

# Main function
main() {
    parse_arguments "$@"
    
    case "$SCRIPT_MODE" in
        contexts)
            nuke_stale_contexts
            ;;
        resources)
            nuke_azure_resources
            ;;
        *)
            print_color "$RED" "❌ Unknown mode: $SCRIPT_MODE"
            echo ""
            show_usage
            exit 1
            ;;
    esac
}

# Run the script
main "$@"