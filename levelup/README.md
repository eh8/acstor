# LevelUp demo: Using Azure Container Storage for a sample store application

Welcome to this LevelUp demo! Today, you will:

- Create a resource group
- Install an Azure CLI extension
- Create an AKS cluster with Azure Container Storage installed
- Connect to the new cluster
- Create a replica-enabled storage pool and persistent volumes
- Deploy and test a demo store application
- Simulate hardware failure to test storage resiliency

## Prerequisites

- This article requires the latest version (2.35.0 or later) of the Azure CLI
  with the `k8s-extension` extension installed. See
  [How to install the Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli).
  If you're using the Bash environment in Azure Cloud Shell, the latest version
  is already installed. If you plan to run the commands locally instead of in
  Azure Cloud Shell, be sure to run them with administrative privileges. For
  more information, see
  [Get started with Azure Cloud Shell](https://learn.microsoft.com/en-us/azure/cloud-shell/get-started).

- You'll need the Kubernetes command-line client, `kubectl`. It's already
  installed if you're using Azure Cloud Shell, or you can install it locally by
  running the `az aks install-cli` command.

- Check if your target region is supported in
  [Azure Container Storage regions](https://learn.microsoft.com/en-us/azure/storage/container-storage/container-storage-introduction#regional-availability).

## Getting started

- Take note of your Azure subscription ID.

- [Launch Azure Cloud Shell](https://shell.azure.com), or if you're using a
  local installation, sign in to the Azure CLI by using the
  [az login](https://learn.microsoft.com/en-us/cli/azure/reference-index#az-login)
  command.

- If you're using Azure Cloud Shell, you might be prompted to mount storage.
  Select the Azure subscription where you want to create the storage account and
  select **Create**.

## Install the required extension

Add or upgrade to the latest version of `k8s-extension` by running the following
command.

```bash
az extension add --upgrade --name k8s-extension
```

## Set subscription context

Set your Azure subscription context using the `az account set` command. You can
view the subscription IDs for all the subscriptions you have access to by
running the `az account list --output table` command. Remember to replace
`<subscription-id>` with your subscription ID.

```bash
az account set --subscription <subscription-id>
```

## Create a resource group

Create a resource group using the `az group create` command. Replace
`<resource-group-name>` with the name of the resource group you want to create,
and replace `<location>` with an Azure region such as _eastus_, _westus2_,
_westus3_, or _westeurope_.

```bash
az group create --name <resource-group-name> --location <location>
```

If the resource group was created successfully, you'll see output similar to
this:

```output
{
  "id": "/subscriptions/<guid>/resourceGroups/<resource-group-name>",
  "location": "eastus",
  "managedBy": null,
  "name": "<resource-group-name>",
  "properties": {
    "provisioningState": "Succeeded"
  },
  "tags": null
}
```

## Create a new AKS cluster and install Azure Container Storage

Run the following command to create a new AKS cluster, install Azure Container
Storage, and create a storage pool. Replace `<cluster-name>` and
`<resource-group>` with your own values, and specify which VM type you want to
use. For today's demo, we will be using Azure Container Storage with ephemeral
disks. We will specify `ephemeralDisk` with the
`--enable-azure-container-storage` flag. Note that when selecting
`ephemeralDisk`, you must also specify `--storage-pool-option`, and we will
specify `NVMe` accordingly.

```bash
az aks create -n <cluster-name> -g <resource-group> --node-vm-size Standard_L8s_v3 --node-count 3 --enable-azure-container-storage ephemeralDisk --storage-pool-option NVMe --generate-ssh-keys
```

The deployment will take 10-15 minutes. When it completes, you'll have an AKS
cluster with Azure Container Storage installed, the components for your chosen
storage pool type enabled, and a default storage pool.

## Connect to the new cluster

To connect to the cluster you just created, run the following using your own
cluster name and resource group name.

```bash
az aks get-credentials -n <cluster-name> -g <resource-group>
```

## Display available storage pools

Verify your connection by gathering some data about your cluster environment.

To show node status in your cluster, run the following command:

```bash
kubectl get nodes
```

To get the list of available storage pools, run the following command:

```bash
kubectl get sp -n acstor
```

To check the status of a storage pool, run the following command:

```bash
kubectl describe sp <storage-pool-name> -n acstor
```

If the `Message` doesn't say `StoragePool is ready`, then your storage pool is
still creating or ran into a problem. See
[Troubleshoot Azure Container Storage](https://learn.microsoft.com/en-us/azure/storage/container-storage/troubleshoot-container-storage).

## Create and attach persistent volumes

To create a persistent volume from an ephemeral disk storage pool, you must
include an annotation in your persistent volume claims (PVCs) as a safeguard to
ensure that you intend to use persistent volumes even when the data is
ephemeral. Additionally, you need to enable the `--ephemeral-disk-volume-type`
flag with the `PersistentVolumeWithAnnotation` value on your cluster before
creating your persistent volume claims.

Follow these steps to create and attach a persistent volume.

<!-- ### 1. Update your Azure Container Storage installation

Run the following command to update your Azure Container Storage installation to
allow the creation of persistent volumes from ephemeral disk storage pools.

```bash
az aks update -n <cluster-name> -g <resource-group> --enable-azure-container-storage ephemeralDisk --storage-pool-option NVMe --ephemeral-disk-volume-type PersistentVolumeWithAnnotation
``` -->

### 1. Create a storage pool with volume replication

Follow these steps to create a storage pool using local NVMe with replication.
Azure Container Storage currently supports three-replica and five-replica
configurations. If you specify three replicas, you must have at least three
nodes in your AKS cluster. If you specify five replicas, you must have at least
five nodes.

> Because Ephemeral Disk storage pools consume all the available NVMe disks, you
> must delete any existing local NVMe storage pools before creating a new
> storage pool.

1. Delete the default storage pool that was created during installation. We will
   recreate it with replication enabled.

   ```bash
   kubectl delete sp ephemeraldisk-nvme -n acstor
   ```

2. Use your favorite text editor to create a YAML manifest file such as
   `code acstor-storagepool.yaml`.

3. Paste in the following code and save the file. The storage pool **name**
   value can be whatever you want, but for today let's call it
   `ephemeraldisk-nvme`.

   ```yml
   apiVersion: containerstorage.azure.com/v1
   kind: StoragePool
   metadata:
     name: ephemeraldisk-nvme
     namespace: acstor
   spec:
     poolType:
       ephemeralDisk:
         diskType: nvme
         replicas: 3
   ```

4. Apply the YAML manifest file to create the storage pool.

   ```bash
   kubectl apply -f acstor-storagepool.yaml
   ```

   When storage pool creation is complete, you'll see a message like:

   ```output
   storagepool.containerstorage.azure.com/ephemeraldisk-nvme created
   ```

   You can also run this command to check the status of the storage pool.
   Replace `<storage-pool-name>` with your storage pool **name** value. For this
   example, the value would be **ephemeraldisk-nvme**.

   ```bash
   kubectl describe sp <storage-pool-name> -n acstor
   ```

When the storage pool is created, Azure Container Storage will create a storage
class on your behalf, using the naming convention `acstor-<storage-pool-name>`.

### 2. Display the available storage classes

When the storage pool is ready to use, you must select a storage class to define
how storage is dynamically created when creating and deploying volumes.

Run `kubectl get sc` to display the available storage classes. You should see a
storage class called `acstor-<storage-pool-name>`.

```output
$ kubectl get sc | grep "^acstor-"
acstor-azuredisk-internal        disk.csi.azure.com               Retain          WaitForFirstConsumer   true                   65m
acstor-ephemeraldisk-nvme        containerstorage.csi.azure.com   Delete          WaitForFirstConsumer   true                   2m27s
```

> Don't use the storage class that's marked **internal**. It's an internal
> storage class that's needed for Azure Container Storage to work.

<!-- ### 4. Create a persistent volume claim

A persistent volume claim (PVC) is used to automatically provision storage based
on a storage class. Follow these steps to create PVCs using the new storage
class.

1. We're going to create a namespace that will contain our PVCs and the pods for
   our sample app.

   ```bash
   kubectl create ns pets
   ```

2. Use your favorite text editor to create a YAML manifest file such as
   `code acstor-pvc.yaml`.

3. Paste in the following code and save the file. The PVC `name` value can be
   whatever you want, but for simplicity let's call them `ephemeralpvc-mongodb`
   and `ephemeralpvc-rabbitmq`

   ```yml
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
   name: ephemeralpvc-mongodb
   namespace: pets
   annotations:
     acstor.azure.com/accept-ephemeral-storage: "true"
   spec:
   accessModes:
     - ReadWriteOnce
   storageClassName: acstor-ephemeraldisk-nvme # replace with the name of your storage class if different
   resources:
     requests:
     storage: 10Gi
   ---
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
   name: ephemeralpvc-rabbitmq
   namespace: pets
   annotations:
     acstor.azure.com/accept-ephemeral-storage: "true"
   spec:
   accessModes:
     - ReadWriteOnce
   storageClassName: acstor-ephemeraldisk-nvme # replace with the name of your storage class if different
   resources:
     requests:
     storage: 10Gi
   ```

   When you change the storage size of your volumes, make sure the size is less
   than the available capacity of a single node's ephemeral disk. See
   [Check node ephemeral disk capacity](https://learn.microsoft.com/en-us/azure/storage/container-storage/use-container-storage-with-local-nvme-replication#check-node-ephemeral-disk-capacity).

4. Apply the YAML manifest file to create the PVC.

   ```bash
   kubectl apply -f acstor-pvc.yaml
   ```

   You should see output similar to:

   ```output
   persistentvolumeclaim/ephemeralpvc-mongodb created
   persistentvolumeclaim/ephemeralpvc-rabbitmq created
   ```

   You can verify the status of the PVC by running the following command:

   ```bash
   kubectl describe pvc
   ```

Once the PVC is created, it's ready for use by a pod. -->

### 3. Deploy a pod and attach a persistent volume

We will now deploy our store application with our MongoDB and RabbitMQ data held
in our newly created persistent volumes.

1. We're going to create a namespace that will contain our pods for our sample
   app.

   ```bash
   kubectl create ns pets
   ```

2. Use your favorite text editor to create a YAML manifest file such as
   `code aks-store.yaml`.

3. To preserve the readability of this markdown file, browse to the
   `aks-store.yaml` file in this repository to view the manifest file.

4. Apply the YAML manifest file to deploy the pod.

   ```bash
   kubectl apply -f aks-store.yaml -n pets
   ```

   You should see output similar to the following:

   ```output
   statefulset.apps/mongodb created
   service/mongodb created
   configmap/rabbitmq-enabled-plugins created
   statefulset.apps/rabbitmq created
   service/rabbitmq created
   deployment.apps/order-service created
   service/order-service created
   deployment.apps/makeline-service created
   service/makeline-service created
   deployment.apps/product-service created
   service/product-service created
   deployment.apps/store-front created
   service/store-front created
   deployment.apps/store-admin created
   service/store-admin created
   deployment.apps/virtual-customer created
   deployment.apps/virtual-worker created
   ```

5. To find the public IP address of your storefront and admin panel, wait a few
   minutes for the external IPs to be shown. Your IP addresses will differ from
   the ones shown below.

   ```bash
   kubectl get service -n pets --watch
   ```

   ```
   NAME               TYPE           CLUSTER-IP     EXTERNAL-IP     PORT(S)              AGE
   makeline-service   ClusterIP      10.0.84.147    <none>          3001/TCP             14h
   mongodb            ClusterIP      10.0.229.179   <none>          27017/TCP            14h
   order-service      ClusterIP      10.0.138.152   <none>          3000/TCP             14h
   product-service    ClusterIP      10.0.225.187   <none>          3002/TCP             14h
   rabbitmq           ClusterIP      10.0.159.142   <none>          5672/TCP,15672/TCP   14h
   store-admin        LoadBalancer   10.0.58.131    4.152.238.236   80:31022/TCP         14h
   store-front        LoadBalancer   10.0.26.134    4.152.238.193   80:30905/TCP         14h
   ```

Congratulations! 🙌🥳🎉

You've now deployed an application using Azure Kubernetes Service and Azure
Container Storage, backed by local NVMe drives with volume replication enabled!

> Remember to delete your resource groups once you have finished this activity!

## Appendix: managing volumes and storage pools

In this section, you'll learn how to check the available capacity of ephemeral
disk, how to detach and reattach a persistent volume, how to expand or delete a
storage pool, and how to optimize performance.

### Check node ephemeral disk capacity

An ephemeral volume is allocated on a single node. When you configure the size
of your ephemeral volumes, the size should be less than the available capacity
of the single node's ephemeral disk.

Run the following command to check the available capacity of ephemeral disk for
a single node.

```output
$ kubectl get diskpool -n acstor
NAME                                CAPACITY        AVAILABLE       USED          RESERVED      READY   AGE
ephemeraldisk-nvme-diskpool-beltf   1920383410176   1884552462336   35830947840   34893246464   True    14h
ephemeraldisk-nvme-diskpool-kbsnj   1920383410176   1884552454144   35830956032   34893246464   True    14h
ephemeraldisk-nvme-diskpool-ryiht   1920383410176   1884552454144   35830956032   34893246464   True    14h
```

In this example, the available capacity of ephemeral disk for a single node is
`1884552462336` bytes or 1.71 TiB.

<!-- ### Detach and reattach a persistent volume

To detach a persistent volume, delete the pod that the persistent volume is
attached to.

```bash
kubectl delete pods <pod-name>
```

To reattach a persistent volume, simply reference the persistent volume claim
name in the YAML manifest file as described in
[Deploy a pod and attach a persistent volume](https://learn.microsoft.com/en-us/azure/storage/container-storage/use-container-storage-with-local-nvme-replication#5-deploy-a-pod-and-attach-a-persistent-volume).

To check which persistent volume a persistent volume claim is bound to, run:

```bash
kubectl get pvc <persistent-volume-claim-name>
``` -->

### Expand a storage pool

You can expand storage pools backed by local NVMe to scale up quickly and
without downtime. Shrinking storage pools isn't currently supported.

Because a storage pool backed by Ephemeral Disk uses local storage resources on
the AKS cluster nodes (VMs), expanding the storage pool requires adding another
node to the cluster. Follow these instructions to expand the storage pool.

1. Run the following command to add a node to the AKS cluster. Replace
   `<cluster-name>`, `<nodepool name>`, and `<resource-group-name>` with your
   own values. To get the name of your node pool, run `kubectl get nodes`.

   ```bash
   az aks nodepool add --cluster-name <cluster name> --name <nodepool name> --resource-group <resource group> --node-vm-size Standard_L8s_v3 --node-count 1 --labels acstor.azure.com/io-engine=acstor
   ```

1. Run `kubectl get nodes` and you'll see that a node has been added to the
   cluster.

1. Run `kubectl get sp -A` and you should see that the capacity of the storage
   pool has increased.

### Delete a storage pool

If you want to delete a storage pool, run the following command. Replace
`<storage-pool-name>` with the storage pool name.

```bash
kubectl delete sp -n acstor <storage-pool-name>
```

### Optimize performance when using local NVMe

Depending on your workload’s performance requirements, you can choose from three
different performance tiers: **Basic**, **Standard**, and **Premium**. These
tiers offer a different range of IOPS, and your selection will impact the number
of vCPUs that Azure Container Storage components consume in the nodes where it's
installed. Standard is the default configuration if you don't update the
performance tier.

| **Tier**             | **Number of vCPUs**     |
| -------------------- | ----------------------- |
| `Basic`              | 12.5% of total VM cores |
| `Standard` (default) | 25% of total            |
| `Premium`            | 50% of total VM cores   |

> RAM and hugepages consumption will stay consistent across all tiers: 1 GiB of
> RAM and 2 GiB of hugepages.

Once you've identified the performance tier that aligns best to your needs, you
can run the following command to update the performance tier of your Azure
Container Storage installation. Replace `<performance tier>` with basic,
standard, or premium.

```bash
az aks update -n <cluster-name> -g <resource-group> --enable-azure-container-storage <storage-pool-type> --ephemeral-disk-nvme-perf-tier <performance-tier>
```
