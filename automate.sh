#!/usr/bin/env bash

set -e

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

echo "Enabling Azure Container Storage with NVMe support"
az aks update -n "${CLUSTER_NAME}" -g "${RESOURCE_GROUP}" \
  --enable-azure-container-storage ephemeralDisk \
  --storage-pool-option NVMe \
  --ephemeral-disk-volume-type PersistentVolumeWithAnnotation

echo "Verifying kubectl connection to cluster"
kubectl cluster-info

echo "Checking existing storage pools"
kubectl get sp -n acstor

echo "Creating ephemeral disk storage pool"
cat > acstor-storagepool.yaml << 'EOF'
apiVersion: containerstorage.azure.com/v1
kind: StoragePool
metadata:
  name: ephemeraldisk-nvme
  namespace: acstor
spec:
  poolType:
    ephemeralDisk:
      diskType: nvme
EOF

kubectl apply -f acstor-storagepool.yaml

echo "Waiting for storage pool to be ready..."
kubectl wait --for=condition=Ready sp/ephemeraldisk-nvme -n acstor --timeout=300s

echo "Checking storage pool status"
kubectl describe sp ephemeraldisk-nvme -n acstor

echo "Displaying available storage classes"
kubectl get sc | grep "^acstor-"

echo "Creating test pod with ephemeral volume"
cat > acstor-pod.yaml << 'EOF'
kind: Pod
apiVersion: v1
metadata:
  name: fiopod
spec:
  nodeSelector:
    acstor.azure.com/io-engine: acstor
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
          metadata:
            labels:
              type: my-ephemeral-volume
          spec:
            accessModes: [ "ReadWriteOnce" ]
            storageClassName: acstor-ephemeraldisk-nvme
            resources:
              requests:
                storage: 1Gi
EOF

kubectl apply -f acstor-pod.yaml

echo "Waiting for pod to be ready..."
kubectl wait --for=condition=Ready pod/fiopod --timeout=300s

echo "Checking pod status"
kubectl describe pod fiopod

echo "Running fio benchmark test"
kubectl exec -it fiopod -- fio --name=benchtest --size=800m --filename=/volume/test --direct=1 --rw=randrw --ioengine=libaio --bs=4k --iodepth=16 --numjobs=8 --time_based --runtime=60

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
