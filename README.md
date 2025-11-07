# Azure Container Storage Scripts and Examples

This repository contains automation scripts for deploying and testing Azure Container Storage with Azure Kubernetes Service (AKS).

## Contents

### Scripts

- **`automate.sh`** - Comprehensive AKS cluster automation with multiple test modes:
  - IOPS and bandwidth testing with fio
  - PostgreSQL benchmarking with CNPG (CloudNativePG) operator
  - Support for local NVMe and Azure Premium SSD v2 storage
  - Cluster cleanup and management capabilities
- **`nuke.sh`** - Destructive operations utility with two modes:
  - `contexts` - Clean up stale/unreachable kubectl contexts
  - `resources` - Delete all Azure resource groups matching pattern (ericcheng-*)
  - Supports preview mode by default for safe operations

## Quick Start

### Automated Setup Options

The `automate.sh` script supports multiple test modes. Run without arguments to see all options:

```bash
./automate.sh --help
```

**Available Test Modes:**

- `--iops` - Run IOPS test (4k block size) with fio
- `--bandwidth` - Run bandwidth test (128k block size) with fio  
- `--pgsql` - Run PostgreSQL benchmark on local NVMe + Azure Container Storage
- `--pgsql-azure-disk` - Run PostgreSQL benchmark on Azure Premium SSD v2 (80k IOPS, 1200 MBps)
- `--cleanup` - Reset cluster by removing stale PVCs and pods (keeps ACStor and storage classes)
- `--force-new-cluster` - Force creation of new AKS cluster (ignores existing cluster)

**Examples:**

```bash
./automate.sh --iops                    # Run IOPS test on existing or new cluster
./automate.sh --pgsql                   # Run PostgreSQL benchmark
./automate.sh --cleanup                 # Clean up stale resources
./automate.sh --iops --force-new-cluster # Force new cluster and run IOPS test
```

By default, the script will detect and reuse an existing AKS cluster with Azure Container Storage v2.0.0 if available.

## Kubernetes Manifests

All Kubernetes objects used by `automate.sh` now live under the `k8s/` directory so you can tweak and apply them manually:

- `k8s/storageclass-local.yaml` – Azure Container Storage local NVMe provisioner
- `k8s/storageclass-premium2-disk.yaml` – Azure Premium SSD v2 storage class
- `k8s/postgres-cnpg-local.yaml` and `k8s/postgres-cnpg-premium2disksc.yaml` – CNPG HA clusters plus superuser secrets
- `k8s/fio-pod.yaml` – fio benchmark pod with ephemeral volume

Use `kubectl apply -f <manifest>` to recreate any component outside of the automation script or to iterate on configuration changes.

## Cleanup Operations

### nuke.sh - Destructive Operations Utility

The `nuke.sh` script provides safe cleanup operations with preview mode by default:

```bash
# Preview context cleanup (SAFE - default behavior)
./nuke.sh contexts

# Preview Azure resource group deletion (SAFE - default behavior)
./nuke.sh resources

# Preview with detailed resource information
./nuke.sh resources --inspect

# Actually execute destructive operations (DANGEROUS!)
./nuke.sh contexts --delete
./nuke.sh resources --delete
```

**Safety Features:**

- Preview mode by default - no destructive actions unless `--delete` flag is used
- Detailed analysis of what will be affected
- Explicit confirmation required for destructive operations
- Resource counting and impact assessment
- Colored output for better visibility

## Features

- **Multiple Test Modes:**
  - IOPS testing with fio (4k block size)
  - Bandwidth testing with fio (128k block size)
  - PostgreSQL benchmarking with CloudNativePG (CNPG) operator
  - High Availability PostgreSQL with 3-instance CNPG clusters

- **Storage Options:**
  - Azure Container Storage with local NVMe ephemeral disk
  - Azure Premium SSD v2 with high performance (80k IOPS, 1200 MBps)
  
- **Automation Features:**
  - Automatic cluster detection and reuse
  - Comprehensive cluster cleanup capabilities
  - Safe preview mode for destructive operations
  - PostgreSQL benchmark initialization and warm-up

## Prerequisites

**Required Dependencies (must be installed first):**

- **Azure CLI (`az`)** version 2.77.0 or later with the `amg` and `k8s-extension` add-ons installed
  - Install: <https://docs.microsoft.com/en-us/cli/azure/install-azure-cli>
  - Verify: `az version`
  
- **kubectl** command-line tool
  - Install: <https://kubernetes.io/docs/tasks/tools/>
  - Verify: `kubectl version --client`
  
- **OpenSSL** (for generating random UUIDs)
  - Usually pre-installed on Linux/macOS
  - Verify: `openssl version`

- **jq** JSON processor (required for cluster cleanup operations)
  - Install: <https://stedolan.github.io/jq/download/>
  - Verify: `jq --version`

**Azure Requirements:**

- Valid Azure subscription with appropriate permissions to:
  - Create and manage AKS clusters
  - Create and manage resource groups
  - Install AKS extensions
- Supported Azure region (see [regional availability](https://learn.microsoft.com/en-us/azure/storage/container-storage/container-storage-introduction#regional-availability))
- Azure CLI logged in (`az login`)

## Additional Resources

For more information about Azure Container Storage:

- [Azure Container Storage Documentation](https://learn.microsoft.com/en-us/azure/storage/container-storage/)
- [CloudNativePG Documentation](https://cloudnative-pg.io/documentation/current/)
- [AKS Documentation](https://docs.microsoft.com/en-us/azure/aks/)
