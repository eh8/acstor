#!/usr/bin/env bash

# Function to print messages in color
print_message() {
    local color_code="$1"
    local message="$2"
    echo -e "\e[${color_code}m${message}\e[0m"
}

# Function to print centered text
print_centered() {
    local term_width=$(tput cols)
    local padding=$(printf '%*s' "$(((term_width - ${#1}) / 2))")
    echo "${padding// / }$1"
}

# Greeting banner
print_message "34" ""
print_centered "  ___                      "
print_centered " / _ \\                    "
print_centered "/ /_\\ \\_____   _ _ __ ___"
print_centered "|  _  |_  / | | | '__/ _ \\"
print_centered "| | | |/ /| |_| | | |  __/"
print_centered "\\_| |_/___|\\__,_|_|  \\___|"
print_message "34" ""
print_centered "Welcome to the Azure Container Storage quickstart script!"
print_message "34" ""

# Check if Azure CLI is installed
if ! command -v az &>/dev/null; then
    print_message "31" "Azure CLI not found. Please install Azure CLI and try again."
    exit 1
fi

# Check if kubectl is installed
if ! command -v kubectl &>/dev/null; then
    print_message "31" "kubectl not found. Please install kubectl and try again."
    exit 1
fi

# Check if the user is logged in to Azure
if ! az account show &>/dev/null; then
    print_message "31" "You are not logged in to Azure. Please run 'az login' to log in."
    exit 1
fi

# Prompt user for subscription, and switch to that subscription
IFS=$'\n' read -r -d '' -a valid_subscriptions < <(az account list --query "@[*].name" -o tsv | sort && printf '\0')
selected_subscription_index=0
start_index=0
while true; do
    end_index=$((start_index + 10))
    clear
    print_message "36" "🏷️ Select an Azure subscription to create your resources: "
    if [ ${#valid_subscriptions[@]} -eq 0 ]; then
        print_message "31" "No subscriptions found."
        break
    fi
    for ((i = start_index; i <= end_index && i < ${#valid_subscriptions[@]}; i++)); do
        if [ $i -eq $selected_subscription_index ]; then
            print_message "36" "➤ ${valid_subscriptions[$i]}"
        else
            echo "  ${valid_subscriptions[$i]}"
        fi
    done
    if [ $end_index -lt ${#valid_subscriptions[@]} ]; then
        print_message "36" "Press 'Down' or 'Right' arrow key to see more subscriptions"
    fi
    echo ""
    read -rsn3 key # Read up to 3 characters
    if [[ $key == $'\e[A' ]] || [[ $key == $'\e[D' ]]; then
        # Up or Left arrow key
        if [ $selected_subscription_index -gt 0 ]; then
            selected_subscription_index=$((selected_subscription_index - 1))
        fi
        if [ $selected_subscription_index -eq $start_index ] && [ $start_index -gt 0 ]; then
            start_index=$((start_index - 1))
        fi
    elif [[ $key == $'\e[B' ]] || [[ $key == $'\e[C' ]]; then
        # Down or Right arrow key
        if [ $selected_subscription_index -lt $((${#valid_subscriptions[@]} - 1)) ]; then
            selected_subscription_index=$((selected_subscription_index + 1))
        fi
        if [ $selected_subscription_index -eq $end_index ] && [ $end_index -lt ${#valid_subscriptions[@]} ]; then
            start_index=$((start_index + 1))
        fi
    elif [[ $key == $'\r' ]] || [[ $key == $'' ]]; then
        # Enter key
        SUBSCRIPTION_ID=${valid_subscriptions[$selected_subscription_index]}
        print_message "32" "Subscription: $SUBSCRIPTION_ID"
        break
    fi
done

print_message "34" ""
print_message "36" "👪 Please enter the name of the resource group to create:"
read -r RESOURCE_GROUP
print_message "32" "Resource group: $RESOURCE_GROUP"

DEFAULT_VM_SIZE="Standard_D4s_v5"
print_message "34" ""
print_message "36" "🤖 Please enter the VM SKU to use for the AKS Cluster (default: $DEFAULT_VM_SIZE):"
read -r VM_TYPE
VM_TYPE=${VM_TYPE:-$DEFAULT_VM_SIZE}
print_message "32" "VM SKU: $VM_TYPE"

DEFAULT_REGION="eastus2"
print_message "34" ""
print_message "36" "🌎 Please enter the region you would like your resources deployed in (default: $DEFAULT_REGION):"
read -r REGION
REGION=${REGION:-$DEFAULT_REGION}
print_message "32" "Region: $REGION"

# Show confirmation of the entered options
print_message "34" ""
print_message "34" "You have entered the following details:"
echo "Subscription: $SUBSCRIPTION_ID"
echo "Resource group name: $RESOURCE_GROUP"
echo "VM SKU: $VM_TYPE"
echo "Region: $REGION"

# Prompt user to continue
print_message "36" "Press any key to confirm deployment details, or Ctrl+C to cancel."
read -n 1 -s

# Set the Azure subscription
print_message "34" "Setting Azure Subscription to $SUBSCRIPTION_ID..."
az account set --subscription "$SUBSCRIPTION_ID"

# Create the Resource Group
print_message "34" "Creating Resource Group $RESOURCE_GROUP in region $REGION..."
az group create --name "$RESOURCE_GROUP" --location "$REGION"

# Create the AKS Cluster
print_message "34" "Deploying AKS Cluster in Resource Group $RESOURCE_GROUP with VM type $VM_TYPE..."
az aks create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$RESOURCE_GROUP-akscluster" \
    --node-vm-size "$VM_TYPE" \
    --node-count 3 \
    --enable-azure-container-storage azureDisk \
    --generate-ssh-keys

# Get AKS credentials
print_message "34" "Fetching AKS credentials..."
az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$RESOURCE_GROUP-akscluster"

# Final message
print_message "32" "AKS Cluster setup is complete!"
kubectl get sp -n acstor
kubectl describe sp azuredisk -n acstor
