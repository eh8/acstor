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
    
    # Delete all CNPG clusters
    echo "Force deleting all CNPG clusters..."
    kubectl delete clusters.postgresql.cnpg.io --all --ignore-not-found=true --force --grace-period=0 &
    
    # Get user namespaces (excluding system namespaces and cnpg-system)
    USER_NAMESPACES=$(kubectl get namespaces -o json | \
        jq -r '.items[] | select(.metadata.name as $ns | ["kube-system","kube-public","kube-node-lease","azure-arc","gatekeeper-system","cnpg-system","default"] | index($ns) | not) | .metadata.name')
    
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
    echo -e "\nCNPG operator (kept intact):"
    kubectl get pods -n cnpg-system 2>/dev/null || echo "No CNPG operator found"
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

# Function to install CNPG operator
install_cnpg_operator() {
    echo "Installing CloudNativePG operator..."
    
    # Install CNPG using kubectl
    kubectl apply --server-side -f \
        https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.27/releases/cnpg-1.27.0.yaml
    
    # Wait for CNPG operator to be ready
    echo "Waiting for CNPG operator to be ready..."
    kubectl wait --for=condition=Available \
        --namespace cnpg-system \
        deployment/cnpg-controller-manager \
        --timeout=300s
    
    echo "CNPG operator installed successfully!"
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
      image: openeuler/fio
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
    local FIO_PARAMS="--name=benchtest --size=800m --filename=/volume/test --direct=1 --rw=randread --ioengine=io_uring --iodepth=32 --numjobs=16 --time_based --runtime=60 --group_reporting --ramp_time=15"
    local BLOCK_SIZE=$([[ "$test_mode" == "bandwidth" ]] && echo "128k" || echo "4k")
    
    echo "Running fio benchmark test with block size: $BLOCK_SIZE"
    kubectl exec -it fiopod -- fio $FIO_PARAMS --bs=$BLOCK_SIZE
    
    echo -e "\nFio test completed successfully!\n"
    echo "To interact with your cluster:"
    echo "  kubectl get pods"
    echo "  kubectl get pvc"
    echo "  kubectl get sc"
}

# Function to create CNPG PostgreSQL cluster with HA
create_cnpg_postgresql_cluster() {
    local storage_class=$1
    local cluster_name="postgres-cnpg-${storage_class//-/}"
    local instances=${2:-3}  # Default to 3 instances for HA
    local storage_size="100Gi"
    
    echo "Creating CNPG PostgreSQL cluster with storage class: $storage_class"
    echo "Cluster name: $cluster_name"
    echo "Instances: $instances (1 primary + $(($instances-1)) replicas)"
    
    # Ensure CNPG operator is installed
    install_cnpg_operator
    
    # Delete existing cluster if it exists
    kubectl delete cluster "$cluster_name" --ignore-not-found=true 2>/dev/null
    kubectl wait --for=delete cluster/"$cluster_name" --timeout=120s 2>/dev/null || true
    
    # Set storage size based on storage class
    if [[ "$storage_class" == "local" ]]; then
        storage_size="100Gi"
    elif [[ "$storage_class" == "premium2-disk-sc" ]]; then
        storage_size="1Ti"
    else
        storage_size="8Ti"
    fi
    
    # Create CNPG cluster with HA configuration
    # Add inheritedMetadata for local storage if needed
    local inherited_metadata=""
    if [[ "$storage_class" == "local" ]]; then
        inherited_metadata='inheritedMetadata:
    annotations:
      "localdisk.csi.acstor.io/accept-ephemeral-storage": "true"
  '
    fi
    
    kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: $cluster_name
spec:
  ${inherited_metadata}instances: $instances
  primaryUpdateStrategy: unsupervised
  
  postgresql:
    parameters:
      shared_buffers: "128MB"
      effective_cache_size: "256MB"
      max_connections: "500"
      checkpoint_completion_target: "0.5"
      wal_buffers: "1MB"
      default_statistics_target: "100"
      random_page_cost: "4.0"
      seq_page_cost: "1.0"
      effective_io_concurrency: "200"
      work_mem: "4MB"
      maintenance_work_mem: "256MB"
      min_wal_size: "1GB"
      max_wal_size: "4GB"
      checkpoint_timeout: "15min"
      checkpoint_flush_after: "0"
      max_worker_processes: "8"
      max_parallel_workers_per_gather: "4"
      max_parallel_workers: "8"
      max_parallel_maintenance_workers: "4"
      log_checkpoints: "on"
      log_statement: "none"
      log_min_duration_statement: "1000"
      synchronous_commit: "on"
      full_page_writes: "on"
      wal_compression: "off"
      commit_delay: "0"
      fsync: "on"
      
  bootstrap:
    initdb:
      database: benchmarkdb
      owner: postgres
      secret:
        name: ${cluster_name}-superuser
      dataChecksums: true
      
  storage:
    storageClass: $storage_class
    size: $storage_size
    pvcTemplate:
      accessModes:
        - ReadWriteOnce
      
  enablePDB: true
EOF

    # Create superuser secret
    kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${cluster_name}-superuser
type: kubernetes.io/basic-auth
stringData:
  username: postgres
  password: benchmark123
EOF
    
    echo "Waiting for CNPG cluster to be ready..."
    local retries=60
    while [ $retries -gt 0 ]; do
        if kubectl get cluster "$cluster_name" -o jsonpath='{.status.phase}' 2>/dev/null | grep -q "Cluster in healthy state"; then
            echo "CNPG cluster is ready!"
            break
        fi
        
        # Check if at least primary is ready
        local ready_instances=$(kubectl get cluster "$cluster_name" -o jsonpath='{.status.readyInstances}' 2>/dev/null)
        ready_instances=${ready_instances:-0}
        if [ "$ready_instances" -ge 1 ]; then
            echo "Primary instance is ready (${ready_instances}/${instances} instances ready)"
            break
        fi
        
        echo "Waiting for CNPG cluster... (retries left: $retries)"
        kubectl get cluster "$cluster_name" --no-headers 2>/dev/null || true
        sleep 10
        retries=$((retries - 1))
    done
    
    if [ $retries -eq 0 ]; then
        echo "Warning: CNPG cluster may not be fully ready"
        kubectl describe cluster "$cluster_name"
    fi
    
    # Show cluster status
    echo ""
    echo "CNPG Cluster Status:"
    kubectl get cluster "$cluster_name"
    kubectl get pods -l cnpg.io/cluster="$cluster_name"
    echo ""
}


# Function to initialize pgbench database for CNPG cluster
initialize_cnpg_pgbench_database() {
    local cluster_name=$1
    local scale_factor=${2:-1000}  # Large scale factor to overwhelm caching
    
    echo "Initializing pgbench database with scale factor $scale_factor..."
    
    # Get the primary pod name
    local primary_pod=$(kubectl get pods -l cnpg.io/cluster="$cluster_name",cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}')
    
    if [ -z "$primary_pod" ]; then
        echo "Error: Could not find primary pod for cluster $cluster_name"
        return 1
    fi
    
    echo "Using primary pod: $primary_pod"
    kubectl exec -it "$primary_pod" -- pgbench -i -s "$scale_factor" -U postgres benchmarkdb
}

# Function to run pgbench benchmark on CNPG cluster
run_cnpg_pgbench_test() {
    local cluster_name=$1
    local test_name=$2
    local clients=${3:-8}  # Moderate clients to avoid CPU bottleneck
    local duration=${4:-300}  # 5 minutes
    
    echo "=== PostgreSQL CNPG HA Benchmark Test: $test_name ==="
    echo "Cluster: $cluster_name"
    echo "Clients: $clients"
    echo "Duration: ${duration}s"
    
    # Get the primary pod name
    local primary_pod=$(kubectl get pods -l cnpg.io/cluster="$cluster_name",cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}')
    
    if [ -z "$primary_pod" ]; then
        echo "Error: Could not find primary pod for cluster $cluster_name"
        return 1
    fi
    
    echo "Primary pod: $primary_pod"
    echo "Storage class: $(kubectl get cluster "$cluster_name" -o jsonpath='{.spec.storage.storageClass}')"
    echo ""
    
    # Run a 120-second warm-up
    echo "Running 120-second warm-up..."
    kubectl exec -it "$primary_pod" -- pgbench -c "$clients" -j "$clients" -T 120 -U postgres benchmarkdb >/dev/null 2>&1
    
    echo ""
    echo "Starting main benchmark test..."
    echo "Monitor PostgreSQL activity in another terminal with:"
    echo "  kubectl exec -it $primary_pod -- psql -U postgres -d benchmarkdb -c 'SELECT * FROM pg_stat_activity;'"
    echo "  kubectl exec -it $primary_pod -- psql -U postgres -d benchmarkdb -c 'SELECT * FROM pg_stat_replication;'"
    echo ""
    
    # Run main benchmark with live reporting
    kubectl exec -it "$primary_pod" -- pgbench \
        -c "$clients" \
        -j "$clients" \
        -T "$duration" \
        -P 10 \
        -U postgres \
        benchmarkdb
    
    echo ""
    echo "=== Running Read-Only Test ==="
    kubectl exec -it "$primary_pod" -- pgbench \
        -c "$clients" \
        -j "$clients" \
        -T "$duration" \
        -P 10 \
        -S \
        -U postgres \
        benchmarkdb
    
    echo ""
    echo "=== Running Write-Only Test ==="
    kubectl exec -it "$primary_pod" -- pgbench \
        -c "$clients" \
        -j "$clients" \
        -T "$duration" \
        -P 10 \
        -N \
        -U postgres \
        benchmarkdb
    
    echo ""
    echo "=== Test Complete: $test_name ==="
    echo ""
}

# Function to run single PostgreSQL benchmark with CNPG HA
run_single_postgresql_benchmark() {
    cleanup_cluster
    apply_storage_class
    create_cnpg_postgresql_cluster "local" 3  # 3 instances for HA
    initialize_cnpg_pgbench_database "postgres-cnpg-local"
    run_cnpg_pgbench_test "postgres-cnpg-local" "Local NVMe + Azure Container Storage (CNPG HA)"
    
    echo ""
    echo "PostgreSQL CNPG HA benchmark completed successfully!"
    echo ""
    echo "Useful monitoring commands:"
    local primary_pod=$(kubectl get pods -l cnpg.io/cluster="postgres-cnpg-local",cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}')
    echo "  kubectl exec -it $primary_pod -- psql -U postgres -d benchmarkdb -c 'SELECT * FROM pg_stat_activity;'  # Monitor active queries"
    echo "  kubectl exec -it $primary_pod -- psql -U postgres -d benchmarkdb -c 'SELECT * FROM pg_stat_replication;'  # Monitor replication"
    echo "  kubectl top pod -l cnpg.io/cluster=postgres-cnpg-local       # Monitor CPU/memory usage"
    echo "  kubectl logs $primary_pod -f                                 # View PostgreSQL logs"
    echo "  kubectl get cluster postgres-cnpg-local                      # View cluster status"
    echo "  kubectl get pods -l cnpg.io/cluster=postgres-cnpg-local      # View all cluster pods"
    echo "  kubectl get pvc                                              # View storage claims"
}

# Function to run Azure Premium SSD v2 PostgreSQL benchmark with CNPG HA
run_comparative_postgresql_benchmark() {
    cleanup_cluster
    apply_storage_class
    apply_premium_v2_storage_class
    
    echo "=== Starting Azure Premium SSD v2 PostgreSQL CNPG HA Benchmark ==="
    echo "This will test PostgreSQL HA performance on Azure Premium SSD v2 with maximal performance (80k IOPS, 1200 MBps)"
    echo ""
    
    # Test: Premium SSD v2 with high performance settings and CNPG HA
    echo "=== Azure Premium SSD v2 CNPG HA Test ==="
    create_cnpg_postgresql_cluster "premium2-disk-sc" 3  # 3 instances for HA
    initialize_cnpg_pgbench_database "postgres-cnpg-premium2disksc"
    run_cnpg_pgbench_test "postgres-cnpg-premium2disksc" "Azure Premium SSD v2 (80k IOPS, 1200 MBps) with CNPG HA"
    
    echo ""
    echo "=== Azure Premium SSD v2 PostgreSQL CNPG HA Benchmark Complete ==="
    echo ""
    echo "PostgreSQL CNPG HA cluster is running. You can:"
    local primary_pod=$(kubectl get pods -l cnpg.io/cluster="postgres-cnpg-premium2disksc",cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}')
    echo "  kubectl top pod -l cnpg.io/cluster=postgres-cnpg-premium2disksc     # Monitor Premium SSD v2 resource usage"
    echo "  kubectl get cluster postgres-cnpg-premium2disksc                    # View cluster status"
    echo "  kubectl get pods -l cnpg.io/cluster=postgres-cnpg-premium2disksc    # View all cluster pods"
    echo "  kubectl get pvc                                                     # View storage claims"
    echo "  kubectl describe pv                                                 # View persistent volume details"
    echo ""
    echo "To run additional tests:"
    echo "  kubectl exec -it $primary_pod -- pgbench -c 8 -j 8 -T 60 -P 10 -U postgres benchmarkdb"
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