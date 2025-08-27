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
    --pgsql               Run PostgreSQL benchmark on local NVMe + Azure Container Storage
    --pgsql-azure-disk    Run PostgreSQL benchmark on Azure Premium SSD v2 (80k IOPS, 1200 MBps)
    --cleanup             Reset cluster by removing stale PVCs and pods (keeps ACStor and storage classes)
    --force-new-cluster   Force creation of new AKS cluster (ignores existing cluster)
    --help, -h           Show this help message

EXAMPLES:
    $0 --iops                    # Run IOPS test on existing or new cluster
    $0 --bandwidth               # Run bandwidth test on existing or new cluster
    $0 --pgsql                   # Run PostgreSQL benchmark on local NVMe storage
    $0 --pgsql-azure-disk        # Run PostgreSQL benchmark on Azure Premium SSD v2
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
        --pgsql)
            RUN_MODE="pgsql"
            echo "Running PostgreSQL benchmark on local NVMe + Azure Container Storage"
            ;;
        --pgsql-azure-disk)
            RUN_MODE="pgsql-azure-disk"
            echo "Running PostgreSQL benchmark on Azure Premium SSD v2 (80k IOPS, 1200 MBps)"
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
    echo "Performing aggressive cluster cleanup..."
    
    if ! kubectl cluster-info &>/dev/null; then
        echo "Error: No active kubectl context found."
        exit 1
    fi
    
    # Get user namespaces (excluding system namespaces)
    USER_NAMESPACES=$(kubectl get namespaces -o json | \
        jq -r '.items[] | select(.metadata.name as $ns | ["kube-system","kube-public","kube-node-lease","azure-arc","gatekeeper-system","default"] | index($ns) | not) | .metadata.name')
    
    # Force delete all deployments in user namespaces
    echo "Force deleting all deployments..."
    for ns in $USER_NAMESPACES; do
        kubectl delete deployments --all -n "$ns" --ignore-not-found=true --force --grace-period=0 &
    done
    kubectl delete deployments --all -n default --ignore-not-found=true --force --grace-period=0 &
    
    # Force delete all services in user namespaces  
    echo "Force deleting all services..."
    for ns in $USER_NAMESPACES; do
        kubectl delete services --all -n "$ns" --ignore-not-found=true --force --grace-period=0 &
    done
    kubectl delete services --all -n default --ignore-not-found=true --force --grace-period=0 &
    
    # Force delete all pods in parallel
    echo "Force deleting all user pods..."
    kubectl get pods --all-namespaces -o json | \
        jq -r '.items[] | select(.metadata.namespace as $ns | ["kube-system","kube-public","kube-node-lease","azure-arc","gatekeeper-system"] | index($ns) | not) | "\(.metadata.namespace) \(.metadata.name)"' | \
        while read -r ns pod; do
            [[ -n "$pod" ]] && kubectl delete pod "$pod" -n "$ns" --ignore-not-found=true --force --grace-period=0 &
        done
    
    # Wait a moment for parallel deletions to start
    sleep 2
    
    # Force delete all PVCs with finalizer removal
    echo "Force deleting all PVCs..."
    kubectl get pvc --all-namespaces -o json | \
        jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name)"' | \
        while read -r ns pvc; do
            # Remove finalizers and force delete
            kubectl patch pvc "$pvc" -n "$ns" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null &
            kubectl delete pvc "$pvc" -n "$ns" --ignore-not-found=true --force --grace-period=0 2>/dev/null &
        done
    
    # Wait for background processes to complete
    echo "Waiting for cleanup processes to complete..."
    wait
    
    # Final cleanup - remove stuck resources
    echo "Removing any stuck resources..."
    kubectl get pods --all-namespaces --field-selector=status.phase!=Running -o json | \
        jq -r '.items[] | select(.metadata.namespace as $ns | ["kube-system","kube-public","kube-node-lease","azure-arc","gatekeeper-system"] | index($ns) | not) | "\(.metadata.namespace) \(.metadata.name)"' | \
        while read -r ns pod; do
            kubectl patch pod "$pod" -n "$ns" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null
        done
    
    echo -e "\nAggressive cleanup completed. Remaining resources:"
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

# Function to apply Premium SSD v2 storage class
apply_premium_v2_storage_class() {
    kubectl apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: premium2-disk-sc
parameters:
  cachingMode: None
  skuName: PremiumV2_LRS
  DiskIOPSReadWrite: "80000"
  DiskMBpsReadWrite: "1200"
provisioner: disk.csi.azure.com
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
EOF
}

# Note: managed-csi-premium storage class is provided by the preinstalled Azure Disk CSI driver

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

# Function to create PostgreSQL deployment with specific storage class
create_postgresql_deployment() {
    local storage_class=$1
    local deployment_name="postgres-${storage_class//-/}"
    local service_name="${deployment_name}-service"
    
    echo "Creating PostgreSQL deployment with storage class: $storage_class"
    
    # Delete existing deployment if it exists
    kubectl delete deployment "$deployment_name" --ignore-not-found=true
    kubectl delete service "$service_name" --ignore-not-found=true
    kubectl delete pvc "${deployment_name}-pvc" --ignore-not-found=true
    kubectl wait --for=delete deployment/"$deployment_name" --timeout=120s 2>/dev/null || true
    kubectl wait --for=delete pvc/"${deployment_name}-pvc" --timeout=120s 2>/dev/null || true
    
    # Create PVC with annotation for local storage class
    if [[ "$storage_class" == "local" ]]; then
        kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${deployment_name}-pvc
  annotations:
    localdisk.csi.acstor.io/accept-ephemeral-storage: "true"
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: $storage_class
  resources:
    requests:
      storage: 100Gi
EOF
    elif [[ "$storage_class" == "premium2-disk-sc" ]]; then
        kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${deployment_name}-pvc
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: $storage_class
  resources:
    requests:
      storage: 1Ti
EOF
    else
        kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${deployment_name}-pvc
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: $storage_class
  resources:
    requests:
      storage: 8Ti
EOF
    fi
    
    # Create PostgreSQL deployment
    kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $deployment_name
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $deployment_name
  template:
    metadata:
      labels:
        app: $deployment_name
    spec:
      nodeSelector:
        "kubernetes.io/os": linux
      securityContext:
        fsGroup: 999
      containers:
      - name: postgres
        image: postgres:15
        securityContext:
          runAsUser: 999
          runAsGroup: 999
          runAsNonRoot: true
        env:
        - name: POSTGRES_PASSWORD
          value: "benchmark123"
        - name: POSTGRES_DB
          value: "benchmarkdb"
        - name: POSTGRES_USER
          value: "postgres"
        - name: PGDATA
          value: "/var/lib/postgresql/data/pgdata"
        ports:
        - containerPort: 5432
        volumeMounts:
        - name: postgres-storage
          mountPath: /var/lib/postgresql/data
        # Start PostgreSQL with optimized configuration
        # Note: monitoring tools install skipped since container runs as non-root
        args:
        - postgres
        - -c
        - shared_buffers=2GB
        - -c
        - effective_cache_size=4GB
        - -c
        - synchronous_commit=on
        - -c
        - full_page_writes=on
        - -c
        - wal_compression=off
        - -c
        - checkpoint_timeout=15min
        - -c
        - max_wal_size=2GB
        - -c
        - wal_buffers=16MB
        - -c
        - log_checkpoints=on
        - -c
        - log_statement=none
        - -c
        - log_min_duration_statement=1000
      volumes:
      - name: postgres-storage
        persistentVolumeClaim:
          claimName: ${deployment_name}-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: $service_name
spec:
  selector:
    app: $deployment_name
  ports:
  - port: 5432
    targetPort: 5432
  type: ClusterIP
EOF
    
    echo "Waiting for PostgreSQL to be ready..."
    kubectl wait --for=condition=Available deployment/"$deployment_name" --timeout=600s
    
    # Wait for PostgreSQL to be accepting connections
    echo "Waiting for PostgreSQL to accept connections..."
    local retries=30
    while [ $retries -gt 0 ]; do
        if kubectl exec -it deployment/"$deployment_name" -- pg_isready -U postgres >/dev/null 2>&1; then
            echo "PostgreSQL is ready!"
            break
        fi
        echo "Waiting for PostgreSQL... (retries left: $retries)"
        sleep 5
        retries=$((retries - 1))
    done
    
    if [ $retries -eq 0 ]; then
        echo "Error: PostgreSQL did not become ready in time"
        return 1
    fi
}

# Function to initialize pgbench database
initialize_pgbench_database() {
    local deployment_name=$1
    local scale_factor=${2:-1000}  # Large scale factor to overwhelm caching
    
    echo "Initializing pgbench database with scale factor $scale_factor..."
    kubectl exec -it deployment/"$deployment_name" -- pgbench -i -s "$scale_factor" -U postgres benchmarkdb
}

# Function to run pgbench benchmark
run_pgbench_test() {
    local deployment_name=$1
    local test_name=$2
    local clients=${3:-8}  # Moderate clients to avoid CPU bottleneck
    local duration=${4:-60}  # 1 minute
    
    echo "=== PostgreSQL Benchmark Test: $test_name ==="
    echo "Deployment: $deployment_name"
    echo "Clients: $clients"
    echo "Duration: ${duration}s"
    echo "Storage class: $(kubectl get pvc "${deployment_name}-pvc" -o jsonpath='{.spec.storageClassName}')"
    echo ""
    
    # Run a 30-second warm-up
    echo "Running 30-second warm-up..."
    kubectl exec -it deployment/"$deployment_name" -- pgbench -c "$clients" -j "$clients" -T 30 -U postgres benchmarkdb >/dev/null 2>&1
    
    echo ""
    echo "Starting main benchmark test..."
    echo "Monitor PostgreSQL activity in another terminal with:"
    echo "  kubectl exec -it deployment/$deployment_name -- psql -U postgres -d benchmarkdb -c 'SELECT * FROM pg_stat_activity;'"
    echo ""
    
    # Run main benchmark with live reporting
    kubectl exec -it deployment/"$deployment_name" -- pgbench \
        -c "$clients" \
        -j "$clients" \
        -T "$duration" \
        -P 3 \
        --progress-timestamp \
        -U postgres \
        benchmarkdb
    
    echo ""
    echo "=== Test Complete: $test_name ==="
    echo ""
}

# Function to run single PostgreSQL benchmark
run_single_postgresql_benchmark() {
    apply_storage_class
    create_postgresql_deployment "local"
    initialize_pgbench_database "postgres-local"
    run_pgbench_test "postgres-local" "Local NVMe + Azure Container Storage"
    
    echo ""
    echo "PostgreSQL benchmark completed successfully!"
    echo ""
    echo "Useful monitoring commands:"
    echo "  kubectl exec -it deployment/postgres-local -- psql -U postgres -d benchmarkdb -c 'SELECT * FROM pg_stat_activity;'  # Monitor active queries"
    echo "  kubectl top pod -l app=postgres-local                        # Monitor CPU/memory usage"
    echo "  kubectl logs deployment/postgres-local -f                    # View PostgreSQL logs"
    echo "  kubectl get pvc                                              # View storage claims"
}

# Function to run Azure Premium SSD v2 PostgreSQL benchmark
run_comparative_postgresql_benchmark() {
    apply_storage_class
    apply_premium_v2_storage_class
    
    echo "=== Starting Azure Premium SSD v2 PostgreSQL Benchmark ==="
    echo "This will test PostgreSQL performance on Azure Premium SSD v2 with maximal performance (80k IOPS, 1200 MBps)"
    echo ""
    
    # Test: Premium SSD v2 with high performance settings
    echo "=== Azure Premium SSD v2 Test ==="
    create_postgresql_deployment "premium2-disk-sc"
    initialize_pgbench_database "postgres-premium2disksc"
    run_pgbench_test "postgres-premium2disksc" "Azure Premium SSD v2 (80k IOPS, 1200 MBps)"
    
    echo ""
    echo "=== Azure Premium SSD v2 PostgreSQL Benchmark Complete ==="
    echo ""
    echo "PostgreSQL instance is running. You can:"
    echo "  kubectl top pod -l app=postgres-premium2disksc                     # Monitor Premium SSD v2 resource usage"
    echo "  kubectl get pvc                                                     # View storage claims"
    echo "  kubectl describe pv                                                 # View persistent volume details"
    echo ""
    echo "To run additional tests:"
    echo "  kubectl exec -it deployment/postgres-premium2disksc -- pgbench -c 8 -j 8 -T 60 -P 3 --progress-timestamp -U postgres benchmarkdb"
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
      --generate-ssh-keys \
      --zones 1 2 3
    
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
    pgsql)
        if [[ "$FORCE_NEW_CLUSTER" == "false" ]] && check_existing_cluster; then
            echo "Using existing cluster, running PostgreSQL benchmark..."
            run_single_postgresql_benchmark
        else
            echo "${FORCE_NEW_CLUSTER:+Forcing creation of new AKS cluster...}${FORCE_NEW_CLUSTER:-No existing AKS cluster with Azure Container Storage v2.0.0 found. Creating new cluster...}"
            create_new_cluster
            run_single_postgresql_benchmark
        fi
        ;;
    pgsql-azure-disk)
        if [[ "$FORCE_NEW_CLUSTER" == "false" ]] && check_existing_cluster; then
            echo "Using existing cluster, running Azure Premium SSD v2 PostgreSQL benchmark..."
            run_comparative_postgresql_benchmark
        else
            echo "${FORCE_NEW_CLUSTER:+Forcing creation of new AKS cluster...}${FORCE_NEW_CLUSTER:-No existing AKS cluster with Azure Container Storage v2.0.0 found. Creating new cluster...}"
            create_new_cluster
            run_comparative_postgresql_benchmark
        fi
        ;;
esac