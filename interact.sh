#!/usr/bin/env bash

set -euo pipefail

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
print_centered "    ___                      "
print_centered "   /   |____  __  __________ "
print_centered "  / /| /_  / / / / / ___/ _ \\"
print_centered " / ___ |/ /_/ /_/ / /  /  __/"
print_centered "/_/  |_/___/\\__,_/_/   \\___/ "
echo ""
print_centered "This script helps you create an AKS cluster with Azure Container Storage installed."
echo ""
print_centered "Have fun!"
echo ""
print_centered "https://aka.ms/acstor"

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
    end_index=$((start_index + 19))
    clear -x
    print_message "36" "🏷️   Select an Azure subscription to create your resources: "
    if [ ${#valid_subscriptions[@]} -eq 0 ]; then
        print_message "31" "No subscriptions found."
        break
    fi
    for ((i = start_index; i <= end_index && i < ${#valid_subscriptions[@]}; i++)); do
        if [ $i -eq $selected_subscription_index ]; then
            print_message "32" "  ➤ ${valid_subscriptions[$i]}"
        else
            echo "    ${valid_subscriptions[$i]}"
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
        else
            selected_subscription_index=$((${#valid_subscriptions[@]} - 1))
            start_index=$((${#valid_subscriptions[@]} - 19))
        fi
        if [ $selected_subscription_index -eq $start_index ] && [ $start_index -gt 0 ]; then
            start_index=$((start_index - 1))
        fi
    elif [[ $key == $'\e[B' ]] || [[ $key == $'\e[C' ]]; then
        # Down or Right arrow key
        if [ $selected_subscription_index -lt $((${#valid_subscriptions[@]} - 1)) ]; then
            selected_subscription_index=$((selected_subscription_index + 1))
        else
            selected_subscription_index=0
            start_index=0
        fi
        if [ $selected_subscription_index -eq $end_index ] && [ $end_index -lt ${#valid_subscriptions[@]} ]; then
            start_index=$((start_index + 1))
        fi
    elif [[ $key == $'\r' ]] || [[ $key == $'' ]]; then
        SUBSCRIPTION_ID=${valid_subscriptions[$selected_subscription_index]}
        print_message "32" "Subscription: $SUBSCRIPTION_ID"
        break
    fi
done

# Multiple choice for backing storage option
backing_options=("Azure Disk" "Elastic SAN" "Ephemeral Disk (with local NVMe)" "Ephemeral Disk (with temporary SSD)")
selected_backing_option_index=0
start_index=0
while true; do
    end_index=$((start_index + 3))
    clear -x
    print_message "36" "💾  Select the backing storage option for the AKS cluster: "
    for ((i = start_index; i <= end_index && i < ${#backing_options[@]}; i++)); do
        if [ $i -eq $selected_backing_option_index ]; then
            print_message "32" "  ➤ ${backing_options[$i]}"
        else
            echo "    ${backing_options[$i]}"
        fi
    done
    if [ $end_index -lt ${#backing_options[@]} ]; then
        print_message "36" "Press 'Down' or 'Right' arrow key to see more options"
    fi
    echo ""
    read -rsn3 key # Read up to 3 characters
    if [[ $key == $'\e[A' ]] || [[ $key == $'\e[D' ]]; then
        # Up or Left arrow key
        if [ $selected_backing_option_index -gt 0 ]; then
            selected_backing_option_index=$((selected_backing_option_index - 1))
        fi
        if [ $selected_backing_option_index -eq $start_index ] && [ $start_index -gt 0 ]; then
            start_index=$((start_index - 1))
        fi
    elif [[ $key == $'\e[B' ]] || [[ $key == $'\e[C' ]]; then
        # Down or Right arrow key
        if [ $selected_backing_option_index -lt $((${#backing_options[@]} - 1)) ]; then
            selected_backing_option_index=$((selected_backing_option_index + 1))
        fi
        if [ $selected_backing_option_index -eq $end_index ] && [ $end_index -lt ${#backing_options[@]} ]; then
            start_index=$((start_index + 1))
        fi
    elif [[ $key == $'\r' ]] || [[ $key == $'' ]]; then
        BACKING_OPTION=${backing_options[$selected_backing_option_index]}
        print_message "32" "Backing storage option: $BACKING_OPTION"
        break
    fi
done

# Multiple choice for VM SKU
if [[ $BACKING_OPTION == "Azure Disk" || $BACKING_OPTION == "Elastic SAN" ]]; then
    vm_options=(
        "Standard_D4s_v5"
        "Standard_D8s_v5"
        "Standard_D16s_v5"
        "Standard_D32s_v5"
        "Standard_D64s_v5"
        "Standard_D4s_v4"
        "Standard_D8s_v4"
        "Standard_D16s_v4"
        "Standard_D32s_v4"
        "Standard_D64s_v4"
        "Standard_D4s_v3"
        "Standard_D8s_v3"
        "Standard_D16s_v3"
        "Standard_D32s_v3"
        "Standard_D64s_v3"
    )
elif [[ $BACKING_OPTION == "Ephemeral Disk (with local NVMe)" ]]; then
    vm_options=(
        "Standard_L8s_v3"
        "Standard_L16s_v3"
        "Standard_L32s_v3"
        "Standard_L64s_v3"
        "Standard_L80s_v3"
        "Standard_L96s_v3"
        "Standard_L8s_v2"
        "Standard_L16s_v2"
        "Standard_L32s_v2"
        "Standard_L64s_v2"
    )
elif [[ $BACKING_OPTION == "Ephemeral Disk (with temporary SSD)" ]]; then
    vm_options=(
        "Standard_E4s_v3"
        "Standard_E8s_v3"
        "Standard_E16s_v3"
        "Standard_E20s_v3"
        "Standard_E32s_v3"
        "Standard_E64s_v3"
        "Standard_E4s_v4"
        "Standard_E8s_v4"
        "Standard_E16s_v4"
        "Standard_E20s_v4"
        "Standard_E32s_v4"
        "Standard_E64s_v4"
    )
fi

selected_vm_option_index=0
start_index=0
while true; do
    end_index=$((start_index + 9))
    clear -x
    print_message "36" "💻  Select the VM SKU for the AKS cluster: "
    for ((i = start_index; i <= end_index && i < ${#vm_options[@]}; i++)); do
        if [ $i -eq $selected_vm_option_index ]; then
            print_message "32" "  ➤ ${vm_options[$i]}"
        else
            echo "    ${vm_options[$i]}"
        fi
    done
    if [ $end_index -lt ${#vm_options[@]} ]; then
        print_message "36" "Press 'Down' or 'Right' arrow key to see more options"
    fi
    echo ""
    read -rsn3 key # Read up to 3 characters
    if [[ $key == $'\e[A' ]] || [[ $key == $'\e[D' ]]; then
        # Up or Left arrow key
        if [ $selected_vm_option_index -gt 0 ]; then
            selected_vm_option_index=$((selected_vm_option_index - 1))
        fi
        if [ $selected_vm_option_index -eq $start_index ] && [ $start_index -gt 0 ]; then
            start_index=$((start_index - 1))
        fi
    elif [[ $key == $'\e[B' ]] || [[ $key == $'\e[C' ]]; then
        # Down or Right arrow key
        if [ $selected_vm_option_index -lt $((${#vm_options[@]} - 1)) ]; then
            selected_vm_option_index=$((selected_vm_option_index + 1))
        fi
        if [ $selected_vm_option_index -eq $end_index ] && [ $end_index -lt ${#vm_options[@]} ]; then
            start_index=$((start_index + 1))
        fi
    elif [[ $key == $'\r' ]] || [[ $key == $'' ]]; then
        VM_SKU=${vm_options[$selected_vm_option_index]}
        print_message "32" "VM SKU: $VM_SKU"
        break
    fi
done

# note: https://learn.microsoft.com/en-us/azure/storage/container-storage/container-storage-introduction#regional-availability
regions=(
    "eastus"
    "eastus2"
    "westeurope"
    "northcentralus"
    "westus2"
    "centralus"
    "uksouth"
    "japaneast"
    "australiaeast"
    "southeastasia"
    "westus"
    "southcentralus"
    "francecentral"
    "germanywestcentral"
    "northeurope"
    "centralindia"
    "eastasia"
    "koreacentral"
    "canadacentral"
    "swedencentral"
    "southafricanorth"
    "westus3"
    "uaenorth"
    "switzerlandnorth"
    "canadaeast"
    "brazilsouth"
    "westcentralus"
)

region_names=(
    "East US"
    "East US 2"
    "West Europe"
    "North Central US"
    "West US 2"
    "Central US"
    "UK South"
    "Japan East"
    "Australia East"
    "Southeast Asia"
    "West US"
    "South Central US"
    "France Central"
    "Germany West Central"
    "North Europe"
    "Central India"
    "East Asia"
    "Korea Central"
    "Canada Central"
    "Sweden Central"
    "South Africa North"
    "West US 3"
    "UAE North"
    "Switzerland North"
    "Canada East"
    "Brazil South"
    "West Central US"
)

selected_region_index=0
start_index=0
while true; do
    end_index=$((start_index + 19)) # Adjusted to display 10 items at a time
    clear -x
    print_message "36" "🌎  Select the region your resources will be deployed in (https://aka.ms/acstor/regions): "
    for ((i = start_index; i <= end_index && i < ${#regions[@]}; i++)); do
        if [ $i -eq $selected_region_index ]; then
            print_message "32" "  ➤ ${region_names[$i]} (${regions[$i]})"
        else
            echo "    ${region_names[$i]} (${regions[$i]})"
        fi
    done
    if [ $end_index -lt $((${#regions[@]} - 1)) ]; then
        print_message "36" "Press 'Down' or 'Right' arrow key to see more regions"
    fi
    echo ""
    read -rsn3 key # Read up to 3 characters
    if [[ $key == $'\e[A' ]] || [[ $key == $'\e[D' ]]; then
        # Up or Left arrow key
        if [ $selected_region_index -gt 0 ]; then
            selected_region_index=$((selected_region_index - 1))
        fi
        if [ $selected_region_index -eq $start_index ] && [ $start_index -gt 0 ]; then
            start_index=$((start_index - 1))
        fi
    elif [[ $key == $'\e[B' ]] || [[ $key == $'\e[C' ]]; then
        # Down or Right arrow key
        if [ $selected_region_index -lt $((${#regions[@]} - 1)) ]; then
            selected_region_index=$((selected_region_index + 1))
        fi
        if [ $selected_region_index -eq $end_index ] && [ $end_index -lt $((${#regions[@]} - 1)) ]; then
            start_index=$((start_index + 1))
        fi
    elif [[ $key == $'\r' ]] || [[ $key == $'' ]]; then
        REGION=${regions[$selected_region_index]}
        print_message "32" "Region: $REGION"
        break
    fi
done

print_message "34" ""
print_message "36" "👪  Please enter the name of the resource group to create:"
read -r RESOURCE_GROUP
print_message "32" "Resource group: $RESOURCE_GROUP"

# Show confirmation of the entered options
echo ""
print_message "36" "🧾  You have entered the following details:"
echo ""
print_message "32" "Subscription: $SUBSCRIPTION_ID"
print_message "32" "Backing option: $BACKING_OPTION"
print_message "32" "VM SKU: $VM_SKU"
print_message "32" "Region: $REGION"
print_message "32" "Resource group: $RESOURCE_GROUP"
echo ""

# Prompt user to continue
print_message "36" "Press any key to confirm deployment details, or Ctrl+C to cancel."
read -n 1 -s

# Set the Azure subscription
clear -x
print_message "34" "Setting Azure Subscription to $SUBSCRIPTION_ID..."
az account set --subscription "$SUBSCRIPTION_ID"

# Create the Resource Group
print_message "34" "Creating Resource Group $RESOURCE_GROUP in region $REGION..."
az group create --name "$RESOURCE_GROUP" --location "$REGION"

# Determine the appropriate backing storage option
case "$BACKING_OPTION" in
"Azure Disk")
    STORAGE_OPTION="azureDisk"
    ;;
"Elastic SAN")
    STORAGE_OPTION="elasticSan"
    ;;
"Ephemeral Disk (with local NVMe)")
    STORAGE_OPTION="ephemeralDisk"
    STORAGE_POOL_OPTION="NVMe"
    ;;
"Ephemeral Disk (with temporary SSD)")
    STORAGE_OPTION="ephemeralDisk"
    STORAGE_POOL_OPTION="Temp"
    ;;
esac

# Create the AKS Cluster with the appropriate backing storage option
az aks create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$RESOURCE_GROUP-akscluster" \
    --node-vm-size "$VM_SKU" \
    --node-count 3 \
    --enable-azure-container-storage "$STORAGE_OPTION" \
    ${STORAGE_POOL_OPTION:+--storage-pool-option "$STORAGE_POOL_OPTION"} \
    --generate-ssh-keys \
    --ephemeral-disk-volume-type PersistentVolumeWithAnnotation

# Get AKS credentials
print_message "34" "Fetching AKS credentials..."
az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$RESOURCE_GROUP-akscluster"

# Final message
print_message "32" "AKS Cluster setup is complete!"
kubectl get sp -n acstor
