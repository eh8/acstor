# Azure Container Storage Scripts and Examples

This repository contains automation scripts and example configurations for deploying and testing Azure Container Storage with Azure Kubernetes Service (AKS).

## Contents

### Scripts

- **`automate.sh`** - Automated AKS cluster creation with Azure Container Storage (simplified version)
- **`interact.sh`** - Interactive setup script with user prompts for subscription, backing storage options, VM SKUs, and regions  
- **`nuke.sh`** - Destructive operations utility with two modes:
  - `contexts` - Clean up stale/unreachable kubectl contexts
  - `resources` - Delete all Azure resource groups matching pattern (ericcheng-*)
  - Supports `--dry-run` mode for safe preview of operations

### Example Configurations (`levelup/`)

- **`acstor-storagepool.yaml`** - StoragePool configuration for ephemeral disk with NVMe and 3-replica setup
- **`acstor-pvc.yaml`** - PersistentVolumeClaim examples for MongoDB and RabbitMQ
- **`aks-store.yaml`** - Complete sample store application with MongoDB, RabbitMQ, and microservices
- **`README.md`** - Detailed walkthrough and demo instructions

## Quick Start

### Option 1: Interactive Setup (Recommended)

```bash
./interact.sh
```

This script provides a user-friendly interface to select your Azure subscription, backing storage type (Azure Disk, Elastic SAN, or Ephemeral Disk), VM SKU, region, and resource group.

### Option 2: Automated Setup

```bash
./automate.sh [--bandwidth] [--force-new-cluster]
```

Creates an AKS cluster with predefined settings using ephemeral disk storage.

**Parameters:**

- `--bandwidth` - Run fio test in bandwidth mode (128k block size) instead of IOPS mode (4k block size)
- `--force-new-cluster` - Force creation of a new cluster, ignoring any existing AKS cluster with Azure Container Storage

By default, the script will detect and reuse an existing AKS cluster with Azure Container Storage if available. Use `--force-new-cluster` to always create a fresh cluster.

### Option 3: Official Quickstart

```bash
bash -c "$(curl -fsSL aka.ms/acstor-quickstart)"
```

## Cleanup Operations

### nuke.sh - Destructive Operations Utility

The `nuke.sh` script provides safe cleanup operations with dry-run preview capability:

```bash
# Preview context cleanup (RECOMMENDED - always run dry-run first)
./nuke.sh contexts --dry-run

# Actually clean up stale kubectl contexts
./nuke.sh contexts

# Preview Azure resource group deletion
./nuke.sh resources --dry-run 

# Delete Azure resource groups matching pattern
./nuke.sh resources
```

**Safety Features:**

- `--dry-run` mode for safe preview without making changes
- Detailed analysis of what will be affected
- Explicit confirmation required for destructive operations
- Resource counting and impact assessment

## Features

- Support for multiple Azure Container Storage backing options:
  - Azure Disk
  - Elastic SAN  
  - Ephemeral Disk (NVMe and Temp SSD)
- Volume replication for high availability
- Sample applications demonstrating persistent storage usage
- Complete cleanup automation

## Prerequisites

- Azure CLI (`az`) version 2.35.0 or later
- `kubectl` command-line tool
- Valid Azure subscription with appropriate permissions
- Supported Azure region (see [regional availability](https://learn.microsoft.com/en-us/azure/storage/container-storage/container-storage-introduction#regional-availability))

## Documentation

See `levelup/README.md` for a comprehensive tutorial including:

- Step-by-step cluster setup
- Storage pool configuration  
- Application deployment
- Performance optimization
- Troubleshooting guidance
