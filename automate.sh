#!/usr/bin/env bash

set -e

# Parse command line arguments
BANDWIDTH_MODE=false
FORCE_NEW_CLUSTER=false

for arg in "$@"; do
    case $arg in
        --bandwidth)
            BANDWIDTH_MODE=true
            echo "Running in bandwidth test mode (128k block size)"
            ;;
        --force-new-cluster)
            FORCE_NEW_CLUSTER=true
            echo "Force creating new cluster (ignoring existing cluster)"
            ;;
        *)
            echo "Unknown argument: $arg"
            echo "Usage: $0 [--bandwidth] [--force-new-cluster]"
            exit 1
            ;;
    esac
done

if [[ "$BANDWIDTH_MODE" == "false" ]]; then
    echo "Running in IOPS test mode (4k block size)"
fi

# Function to check if kubectl is connected to an AKS cluster with Azure Container Storage v2.0.0
check_existing_cluster() {
    echo "Checking for existing AKS cluster with Azure Container Storage v2.0.0..."
    
    # Check if kubectl is configured and can connect to a cluster
    if ! kubectl cluster-info &>/dev/null; then
        echo "No active kubectl context found."
        return 1
    fi
    
    # Check if Azure Container Storage extension is installed by looking for local storage class with acstor provisioner
    if ! kubectl get sc local -o jsonpath='{.provisioner}' 2>/dev/null | grep -q "localdisk.csi.acstor.io"; then
        echo "No Azure Container Storage v2.0.0 local storage class found in current cluster."
        return 1
    fi
    
    # Check if this is an AKS cluster by looking for AKS-specific resources
    if ! kubectl get nodes -o jsonpath='{.items[0].spec.providerID}' | grep -q "azure"; then
        echo "Current cluster is not an AKS cluster."
        return 1
    fi
    
    echo "Found existing AKS cluster with Azure Container Storage v2.0.0 extension!"
    return 0
}

# Function to reset and re-run fio test
reset_and_run_fio_test() {
    echo "Resetting existing environment and re-running fio test..."
    
    # Delete existing fio pod if it exists
    if kubectl get pod fiopod &>/dev/null; then
        echo "Deleting existing fio pod..."
        kubectl delete pod fiopod --ignore-not-found=true
        echo "Waiting for pod to be fully deleted..."
        kubectl wait --for=delete pod/fiopod --timeout=120s || true
    fi
    
    # Recreate the local storage class (idempotent)
    echo "Ensuring local StorageClass exists..."
    TEMP_DIR=$(mktemp -d)
    STORAGECLASS_YAML="${TEMP_DIR}/storageclass.yaml"
    
    cat > "${STORAGECLASS_YAML}" << 'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local
provisioner: localdisk.csi.acstor.io
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOF
    
    kubectl apply -f "${STORAGECLASS_YAML}"
    
    # Create new fio pod
    echo "Creating new fio test pod..."
    TEMP_YAML="${TEMP_DIR}/acstor-pod.yaml"
    
    cat > "${TEMP_YAML}" << 'EOF'
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
      args:
        - sleep
        - "1000000"
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
            accessModes:
              - ReadWriteOnce
            storageClassName: local
EOF
    
    kubectl apply -f "${TEMP_YAML}"
    
    # Clean up temporary files
    rm -rf "${TEMP_DIR}"
    
    echo "Waiting for pod to be ready..."
    kubectl wait --for=condition=Ready pod/fiopod --timeout=300s
    
    echo "Checking pod status"
    kubectl describe pod fiopod
    
    echo "Running fio benchmark test"
    if [[ "$BANDWIDTH_MODE" == "true" ]]; then
        kubectl exec -it fiopod -- fio --name=benchtest --size=800m --filename=/volume/test --direct=1 --rw=randrw --ioengine=io_uring --bs=128k --iodepth=32 --numjobs=16 --time_based --runtime=60 --group_reporting --ramp_time=15
    else
        kubectl exec -it fiopod -- fio --name=benchtest --size=800m --filename=/volume/test --direct=1 --rw=randrw --ioengine=io_uring --bs=4k --iodepth=32 --numjobs=16 --time_based --runtime=60 --group_reporting --ramp_time=15
    fi
    
    echo "Fio test completed successfully!"
    echo ""
    echo "To interact with your cluster:"
    echo "  kubectl get pods"
    echo "  kubectl get pvc"
    echo "  kubectl get sc"
    
    return 0
}

# Check if we should use existing cluster or force new one
if [[ "$FORCE_NEW_CLUSTER" == "false" ]] && check_existing_cluster; then
    reset_and_run_fio_test
    exit 0
fi

# If no existing cluster or forced to create new one, proceed with full setup
if [[ "$FORCE_NEW_CLUSTER" == "true" ]]; then
    echo "Forcing creation of new AKS cluster..."
else
    echo "No existing AKS cluster with Azure Container Storage v2.0.0 found. Creating new cluster..."
fi

RANDOM_UUID=$(openssl rand -hex 4)
RESOURCE_GROUP="rg-ericcheng-${RANDOM_UUID}"
CLUSTER_NAME="aks-cluster-${RANDOM_UUID}"
LOCATION="eastus2"
NODE_COUNT=3
NODE_VM_SIZE="Standard_L16s_v3"

echo "Creating Azure resource group: ${RESOURCE_GROUP}"
az group create --name "${RESOURCE_GROUP}" --location "${LOCATION}"

echo "Creating AKS cluster: ${CLUSTER_NAME}"
az aks create \
  --resource-group "${RESOURCE_GROUP}" \
  --name "${CLUSTER_NAME}" \
  --node-count "${NODE_COUNT}" \
  --node-vm-size "${NODE_VM_SIZE}" \
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

echo "Verifying kubectl connection to cluster"
kubectl cluster-info

echo "Displaying available storage classes"
kubectl get sc

echo "Creating custom StorageClass for local-csi-driver"
TEMP_DIR=$(mktemp -d)
STORAGECLASS_YAML="${TEMP_DIR}/storageclass.yaml"

cat > "${STORAGECLASS_YAML}" << 'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local
provisioner: localdisk.csi.acstor.io
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOF

kubectl apply -f "${STORAGECLASS_YAML}"

echo "Creating test pod with ephemeral volume using local StorageClass"
TEMP_YAML="${TEMP_DIR}/acstor-pod.yaml"

cat > "${TEMP_YAML}" << 'EOF'
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
      args:
        - sleep
        - "1000000"
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
            accessModes:
              - ReadWriteOnce
            storageClassName: local
EOF

kubectl apply -f "${TEMP_YAML}"

# Clean up temporary file
rm -rf "${TEMP_DIR}"

echo "Waiting for pod to be ready..."
kubectl wait --for=condition=Ready pod/fiopod --timeout=300s

echo "Checking pod status"
kubectl describe pod fiopod

echo "Running fio benchmark test"
if [[ "$BANDWIDTH_MODE" == "true" ]]; then
    kubectl exec -it fiopod -- fio --name=benchtest --size=800m --filename=/volume/test --direct=1 --rw=randrw --ioengine=io_uring --bs=128k --iodepth=32 --numjobs=16 --time_based --runtime=60 --group_reporting --ramp_time=15
else
    kubectl exec -it fiopod -- fio --name=benchtest --size=800m --filename=/volume/test --direct=1 --rw=randrw --ioengine=io_uring --bs=4k --iodepth=32 --numjobs=16 --time_based --runtime=60 --group_reporting --ramp_time=15
fi

echo "Setup complete!"
echo "Resource Group: ${RESOURCE_GROUP}"
echo "AKS Cluster: ${CLUSTER_NAME}"
echo ""
echo "To interact with your cluster:"
echo "  kubectl get pods"
echo "  kubectl get pvc"
echo "  kubectl get sc"
echo ""
echo "To clean up resources:"
echo "  az group delete --name ${RESOURCE_GROUP} --yes --no-wait"
