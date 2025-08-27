#!/usr/bin/env bash

set -e

# Default values
RUN_MODE=""
FORCE_NEW_CLUSTER=false

# Function to display help
show_help() {
    cat << EOF
Azure Container Storage Test Automation Script

Usage: $0 [OPTIONS]

OPTIONS:
    --iops                Run IOPS test mode (4k block size)
    --bandwidth           Run bandwidth test mode (128k block size)
    --cleanup             Reset cluster by removing stale PVCs and pods (keeps ACStor and storage classes)
    --force-new-cluster   Force creation of new AKS cluster (ignores existing cluster)
    --help, -h           Show this help message

EXAMPLES:
    $0 --iops                    # Run IOPS test on existing or new cluster
    $0 --bandwidth               # Run bandwidth test on existing or new cluster
    $0 --cleanup                 # Clean up stale resources
    $0 --iops --force-new-cluster # Force new cluster and run IOPS test

NOTES:
    - If no option is provided, this help message is displayed
    - The script will reuse existing AKS clusters with Azure Container Storage v2.0.0
    - Use --force-new-cluster to always create a fresh cluster
    - Cleanup mode preserves ACStor components and storage classes

EOF
}

# Parse command line arguments
for arg in "$@"; do
    case $arg in
        --iops)
            RUN_MODE="iops"
            echo "Running in IOPS test mode (4k block size)"
            ;;
        --bandwidth)
            RUN_MODE="bandwidth"
            echo "Running in bandwidth test mode (128k block size)"
            ;;
        --cleanup)
            RUN_MODE="cleanup"
            echo "Running cleanup mode (removing stale PVCs and pods)"
            ;;
        --force-new-cluster)
            FORCE_NEW_CLUSTER=true
            echo "Force creating new cluster (ignoring existing cluster)"
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            echo "Error: Unknown argument: $arg"
            echo ""
            show_help
            exit 1
            ;;
    esac
done

# Show help if no mode is specified
if [[ -z "$RUN_MODE" ]]; then
    show_help
    exit 0
fi

# Function to cleanup stale PVCs and pods while keeping ACStor and storage classes
cleanup_cluster() {
    echo "Performing cluster cleanup..."
    
    if ! kubectl cluster-info &>/dev/null; then
        echo "Error: No active kubectl context found."
        exit 1
    fi
    
    # Delete all user pods (exclude system namespaces)
    echo "Cleaning up user pods..."
    kubectl get pods --all-namespaces -o json | \
        jq -r '.items[] | select(.metadata.namespace as $ns | ["kube-system","kube-public","kube-node-lease","azure-arc","gatekeeper-system"] | index($ns) | not) | "\(.metadata.namespace)/\(.metadata.name)"' | \
        while read -r pod; do
            [[ -n "$pod" ]] && kubectl delete pod "${pod##*/}" -n "${pod%%/*}" --ignore-not-found=true --grace-period=30
        done
    
    # Delete all PVCs
    echo "Cleaning up PVCs..."
    kubectl delete pvc --all --all-namespaces --ignore-not-found=true
    
    echo -e "\nCleanup completed. Remaining resources:"
    echo -e "\nStorage Classes (kept intact):"
    kubectl get sc
    echo -e "\nACStor components (kept intact):"
    kubectl get pods -n kube-system | grep -E "(acstor|local-csi)" || echo "No ACStor pods found"
}

# Function to check if kubectl is connected to an AKS cluster with Azure Container Storage v2.0.0
check_existing_cluster() {
    echo "Checking for existing AKS cluster with Azure Container Storage v2.0.0..."
    
    # Verify kubectl connection, ACStor provisioner, and AKS cluster
    kubectl cluster-info &>/dev/null || return 1
    kubectl get sc local -o jsonpath='{.provisioner}' 2>/dev/null | grep -q "localdisk.csi.acstor.io" || return 1
    kubectl get nodes -o jsonpath='{.items[0].spec.providerID}' | grep -q "azure" || return 1
    
    echo "Found existing AKS cluster with Azure Container Storage v2.0.0 extension!"
    return 0
}

# Function to apply storage class
apply_storage_class() {
    kubectl apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local
provisioner: localdisk.csi.acstor.io
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOF
}

# Function to create and run fio test pod
create_and_run_fio_pod() {
    local test_mode=$1
    
    # Delete existing fio pod if it exists
    kubectl delete pod fiopod --ignore-not-found=true
    kubectl wait --for=delete pod/fiopod --timeout=120s 2>/dev/null || true
    
    # Create fio pod with ephemeral volume
    kubectl apply -f - <<'EOF'
kind: Pod
apiVersion: v1
metadata:
  name: fiopod
spec:
  nodeSelector:
    "kubernetes.io/os": linux
  containers:
    - name: fio
      image: nixery.dev/shell/fio
      args: ["sleep", "1000000"]
      volumeMounts:
        - mountPath: "/volume"
          name: ephemeralvolume
  volumes:
    - name: ephemeralvolume
      ephemeral:
        volumeClaimTemplate:
          spec:
            resources:
              requests:
                storage: 10Gi
            volumeMode: Filesystem
            accessModes: ["ReadWriteOnce"]
            storageClassName: local
EOF
    
    echo "Waiting for pod to be ready..."
    kubectl wait --for=condition=Ready pod/fiopod --timeout=300s
    
    # Run fio benchmark
    local FIO_PARAMS="--name=benchtest --size=800m --filename=/volume/test --direct=1 --rw=randrw --ioengine=io_uring --iodepth=32 --numjobs=16 --time_based --runtime=60 --group_reporting --ramp_time=15"
    local BLOCK_SIZE=$([[ "$test_mode" == "bandwidth" ]] && echo "128k" || echo "4k")
    
    echo "Running fio benchmark test with block size: $BLOCK_SIZE"
    kubectl exec -it fiopod -- fio $FIO_PARAMS --bs=$BLOCK_SIZE
    
    echo -e "\nFio test completed successfully!\n"
    echo "To interact with your cluster:"
    echo "  kubectl get pods"
    echo "  kubectl get pvc"
    echo "  kubectl get sc"
}

# Function to create new AKS cluster
create_new_cluster() {
    RANDOM_UUID=$(openssl rand -hex 4)
    RESOURCE_GROUP="rg-ericcheng-${RANDOM_UUID}"
    CLUSTER_NAME="aks-cluster-${RANDOM_UUID}"
    LOCATION="eastus2"
    
    echo "Creating Azure resource group: ${RESOURCE_GROUP}"
    az group create --name "${RESOURCE_GROUP}" --location "${LOCATION}"
    
    echo "Creating AKS cluster: ${CLUSTER_NAME}"
    az aks create \
      --resource-group "${RESOURCE_GROUP}" \
      --name "${CLUSTER_NAME}" \
      --node-count 3 \
      --node-vm-size "Standard_L16s_v3" \
      --enable-managed-identity \
      --generate-ssh-keys
    
    echo "Getting AKS credentials"
    az aks get-credentials --resource-group "${RESOURCE_GROUP}" --name "${CLUSTER_NAME}"
    
    echo "Installing Azure Container Storage extension"
    az k8s-extension create \
      --cluster-type managedClusters \
      --cluster-name "${CLUSTER_NAME}" \
      --resource-group "${RESOURCE_GROUP}" \
      -n acstor \
      --extension-type microsoft.azurecontainerstoragev2 \
      --scope cluster \
      --release-train staging \
      --release-namespace kube-system \
      --auto-upgrade-minor-version false \
      --version 2.0.0-preview.2 \
      --verbose
    
    echo "Verifying cluster setup"
    kubectl cluster-info
    kubectl get sc
    
    echo -e "\nSetup complete!"
    echo "Resource Group: ${RESOURCE_GROUP}"
    echo "AKS Cluster: ${CLUSTER_NAME}"
    echo -e "\nTo clean up resources:"
    echo "  az group delete --name ${RESOURCE_GROUP} --yes --no-wait"
}

# Main execution flow
case $RUN_MODE in
    cleanup)
        cleanup_cluster
        ;;
    iops|bandwidth)
        if [[ "$FORCE_NEW_CLUSTER" == "false" ]] && check_existing_cluster; then
            echo "Using existing cluster, resetting and running fio test..."
            apply_storage_class
            create_and_run_fio_pod "$RUN_MODE"
        else
            echo "${FORCE_NEW_CLUSTER:+Forcing creation of new AKS cluster...}${FORCE_NEW_CLUSTER:-No existing AKS cluster with Azure Container Storage v2.0.0 found. Creating new cluster...}"
            create_new_cluster
            apply_storage_class
            create_and_run_fio_pod "$RUN_MODE"
        fi
        ;;
esac