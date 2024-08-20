#!/usr/bin/env bash

set -e -u -o pipefail

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
    print_message "31" "Azure CLI not found. Please install Azure CLI to continue."
    exit 1
fi

# Check if the user is logged in to Azure
if ! az account show &>/dev/null; then
    print_message "31" "You are not logged in to Azure. Please run 'az login' to log in."
    exit 1
fi

# Prompt user for inputs with default values
print_message "36" "Please enter your Azure Subscription ID:"
read -r SUBSCRIPTION_ID

print_message "36" "Please enter the name of the Resource Group to create:"
read -r RESOURCE_GROUP

DEFAULT_VM_SIZE="Standard_D4s_v5"
print_message "36" "Please enter the type of VM to use for the AKS Cluster (default: $DEFAULT_VM_SIZE):"
read -r VM_TYPE
VM_TYPE=${VM_TYPE:-$DEFAULT_VM_SIZE}

DEFAULT_REGION="eastus2"
print_message "36" "Please enter the region you would like your resources deployed in (default: $DEFAULT_REGION):"
read -r REGION
REGION=${REGION:-$DEFAULT_REGION}

# Show confirmation of the entered options
print_message "34" "You have entered the following details:"
echo "Subscription ID: $SUBSCRIPTION_ID"
echo "Resource Group: $RESOURCE_GROUP"
echo "VM Type: $VM_TYPE"
echo "Region: $REGION"

# Prompt user to continue
print_message "36" "Press any key to continue with the deployment, or Ctrl+C to cancel."
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
    --name myAKSCluster \
    --node-vm-size "$VM_TYPE" \
    --enable-managed-identity \
    --generate-ssh-keys

# Get AKS credentials
print_message "34" "Fetching AKS credentials..."
az aks get-credentials --resource-group "$RESOURCE_GROUP" --name myAKSCluster

# Final message
print_message "32" "AKS Cluster setup is complete!"
