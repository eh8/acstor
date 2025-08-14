#!/usr/bin/env bash

set -e

# Check if required parameters are provided
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <resource-group> <cluster-name>"
    echo "Example: $0 rg-ericcheng-3866bd66 aks-cluster-3866bd66"
    exit 1
fi

RESOURCE_GROUP="$1"
CLUSTER_NAME="$2"

echo "Post-installation setup for Azure Container Storage"
echo "Resource Group: ${RESOURCE_GROUP}"
echo "AKS Cluster: ${CLUSTER_NAME}"
echo ""

echo "Getting AKS credentials and connecting to cluster"
az aks get-credentials --resource-group "${RESOURCE_GROUP}" --name "${CLUSTER_NAME}" --overwrite-existing

echo "Verifying kubectl connection to cluster"
kubectl cluster-info

echo "Enabling Azure Container Storage with NVMe support"
az aks update -n "${CLUSTER_NAME}" -g "${RESOURCE_GROUP}" \
  --enable-azure-container-storage ephemeralDisk \
  --storage-pool-option NVMe \
  --ephemeral-disk-volume-type PersistentVolumeWithAnnotation

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

echo ""
echo "Post-installation setup complete!"
echo "Resource Group: ${RESOURCE_GROUP}"
echo "AKS Cluster: ${CLUSTER_NAME}"
echo ""
echo "To interact with your cluster:"
echo "  kubectl get pods"
echo "  kubectl get pvc"
echo "  kubectl get sc"
echo "  kubectl get sp -n acstor"
echo ""
echo "To clean up resources:"
echo "  kubectl delete pod fiopod"
echo "  kubectl delete sp ephemeraldisk-nvme -n acstor"
echo "  az group delete --name ${RESOURCE_GROUP} --yes --no-wait"