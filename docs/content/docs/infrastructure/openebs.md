---
title: "Storage with OpenEBS"
weight: 3
bookToc: true
---

# Storage with OpenEBS

Configure persistent storage with disk quotas using OpenEBS ZFS LocalPV.

## Overview

OpenEBS provides cloud-native storage capabilities for Kubernetes, including:
- Dynamic provisioning of persistent volumes
- Disk quotas per volume
- ZFS-based storage with compression and snapshots
- Per-pod storage isolation

We use OpenEBS ZFS LocalPV to provide quota-enforced local storage backed by ZFS pools.

## Prerequisites

### ZFS Installation

Install ZFS utilities on the host system:

```bash
sudo apt update && sudo apt install zfsutils-linux -y
```

### Create ZFS Pool

Set up a ZFS pool on your storage devices:

```bash
# Example: Create a mirrored pool with two pairs of disks
sudo zpool create -f openebs-zpool mirror /dev/sda /dev/sdb mirror /dev/sdc /dev/sdd
```

**Important Notes**:
- Replace device names with your actual devices
- Use `lsblk` to identify available disks
- Consider your redundancy needs (mirror, raidz, etc.)
- The pool name (`openebs-zpool`) will be referenced in the StorageClass

### Verify ZFS Setup

```bash
# Check pool status
sudo zpool status openebs-zpool

# List ZFS filesystems
sudo zfs list
```

## Installation

### Install OpenEBS using Helm

```bash
# Add OpenEBS Helm repository
helm repo add openebs https://openebs.github.io/openebs
helm repo update

# Install OpenEBS
helm install openebs openebs/openebs -n openebs --create-namespace
```

Or use the provided script:

```bash
bash openebs/helm.sh
```

### Verify Installation

```bash
# Check OpenEBS pods are running
kubectl get pods -n openebs

# Verify ZFS CSI driver is deployed
kubectl get pods -n openebs | grep zfs
```

## Configuration

### Create ZFS StorageClass

Create a StorageClass that references your ZFS pool:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: openebs-zfs
parameters:
  recordsize: "128k"
  compression: "off"
  dedup: "off"
  fstype: "zfs"
  poolname: "openebs-zpool"
provisioner: zfs.csi.openebs.io
```

Apply the configuration:

```bash
kubectl apply -f openebs/zfs-storage.yml
```

**Configuration Parameters**:
- `fstype`: Must be `zfs` for ZFS LocalPV
- `poolname`: Must match your ZFS pool name
- `recordsize`: ZFS block size (default: 128k)
- `compression`: ZFS compression (off, lz4, gzip, etc.)
- `dedup`: ZFS deduplication (usually keep off for performance)

### Verify StorageClass

```bash
# List storage classes
kubectl get storageclass

# You should see openebs-zfs listed
```

## Usage

### In Persistent Volume Claims

Request storage in a PVC:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-pvc
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: openebs-zfs
  resources:
    requests:
      storage: 10Gi
```

```bash
kubectl apply -f my-pvc.yaml
```

### In JupyterHub

Configure JupyterHub to use OpenEBS ZFS for user home directories with disk quotas:

```yaml
singleuser:
  storage:
    type: dynamic
    capacity: 60Gi
    homeMountPath: /home/jovyan
    dynamic:
      storageClass: openebs-zfs
      pvcNameTemplate: claim-{escaped_user_server}
      volumeNameTemplate: volume-{escaped_user_server}
      storageAccessModes: [ReadWriteOnce]
```

This gives each user a 60Gi quota for their home directory.

### In Deployments

Use PVCs in pod specifications:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-pod
spec:
  containers:
  - name: my-container
    image: nginx
    volumeMounts:
    - name: storage
      mountPath: /data
  volumes:
  - name: storage
    persistentVolumeClaim:
      claimName: my-pvc
```

## Testing

### Test PVC Creation

Use the test manifest:

```bash
kubectl apply -f openebs/test-pvc.yml
```

This creates:
1. A PVC requesting storage from `openebs-zfs`
2. A pod that mounts the PVC and writes test data

Verify:

```bash
# Check PVC is bound
kubectl get pvc

# Check pod is running
kubectl get pods

# Verify on the host
sudo zfs list
```

You should see ZFS datasets created for each PVC.

## Management

### View ZFS Volumes

On the host system:

```bash
# List all ZFS datasets
sudo zfs list

# Check pool usage
sudo zpool status openebs-zpool

# View detailed pool information
sudo zpool list -v openebs-zpool
```

### Volume Snapshots

Create snapshots of ZFS volumes:

```bash
# List volumes
sudo zfs list

# Create a snapshot
sudo zfs snapshot openebs-zpool/pvc-xxxxx@snapshot-name

# List snapshots
sudo zfs list -t snapshot
```

### Quota Management

ZFS quotas are set automatically based on PVC size, but you can adjust them manually if needed:

```bash
# Check quota
sudo zfs get quota openebs-zpool/pvc-xxxxx

# Set a different quota (if needed)
sudo zfs set quota=100G openebs-zpool/pvc-xxxxx
```

## Monitoring

### Check Storage Usage

```bash
# Overall pool usage
sudo zpool list

# Per-dataset usage
sudo zfs list

# Available space
kubectl get pvc
```

### ZFS Health

```bash
# Pool status
sudo zpool status

# Check for errors
sudo zpool status -x

# Pool health history
sudo zpool history openebs-zpool
```

## Troubleshooting

### PVC Stuck in Pending

1. **Check ZFS driver pods**:
```bash
kubectl get pods -n openebs | grep zfs
kubectl logs -n openebs <zfs-controller-pod>
```

2. **Verify StorageClass**:
```bash
kubectl describe storageclass openebs-zfs
```

3. **Check pool exists**:
```bash
sudo zpool list
```

### Volume Not Mounting

1. **Check PVC status**:
```bash
kubectl describe pvc <pvc-name>
```

2. **Check pod events**:
```bash
kubectl describe pod <pod-name>
```

3. **Verify ZFS dataset**:
```bash
sudo zfs list | grep <pvc-name>
```

### Pool Performance Issues

1. **Check pool health**:
```bash
sudo zpool status -v
```

2. **Monitor I/O**:
```bash
sudo zpool iostat openebs-zpool 1
```

3. **Adjust ZFS parameters** (if needed):
```bash
# Enable compression for better performance
sudo zfs set compression=lz4 openebs-zpool

# Adjust record size for your workload
# (This must be set on the StorageClass for new volumes)
```

## Backup and Recovery

### Export Pool (for maintenance)

```bash
# Export pool (unmounts all datasets)
sudo zpool export openebs-zpool

# Import pool
sudo zpool import openebs-zpool
```

### Backup Volumes

Using ZFS send/receive:

```bash
# Create a snapshot
sudo zfs snapshot openebs-zpool/pvc-xxxxx@backup

# Send to a file
sudo zfs send openebs-zpool/pvc-xxxxx@backup > backup.zfs

# Send to another system
sudo zfs send openebs-zpool/pvc-xxxxx@backup | \
  ssh user@backup-host sudo zfs receive backup-pool/pvc-xxxxx
```

### Restore Volumes

```bash
# From a file
sudo zfs receive openebs-zpool/pvc-xxxxx < backup.zfs

# Rollback to a snapshot
sudo zfs rollback openebs-zpool/pvc-xxxxx@snapshot-name
```

## Best Practices

1. **Pool Redundancy**: Use mirrored or RAIDZ configurations for data protection
2. **Regular Scrubs**: Schedule regular ZFS scrubs to detect and repair corruption
   ```bash
   # Add to cron: 0 2 * * 0 /sbin/zpool scrub openebs-zpool
   sudo zpool scrub openebs-zpool
   ```
3. **Snapshots**: Take regular snapshots before major changes
4. **Monitoring**: Monitor pool capacity and health
5. **Quotas**: Set appropriate quotas to prevent storage exhaustion
6. **Compression**: Enable compression (lz4) for better space efficiency and performance

## Related Resources

- [OpenEBS Documentation](https://openebs.io/docs)
- [ZFS LocalPV Quickstart](https://github.com/openebs/zfs-localpv/blob/develop/docs/quickstart.md)
- [ZFS Administration Guide](https://openzfs.github.io/openzfs-docs/)
- [JupyterHub Storage Configuration]({{< relref "../services/jupyterhub" >}})
