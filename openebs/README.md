# OpenEBS ZFS Storage for Kubernetes

OpenEBS provides ZFS-based persistent storage with disk quotas for Kubernetes pods.

## Quick Setup

### Option 1: Single-Disk Setup (e.g., nimbus with NVMe)

For servers with a single disk already in use, use a file-backed ZFS pool:

```bash
# Install ZFS and create a 2TB pool
sudo bash setup-zfs-pool.sh 2000
```

This creates a sparse file at `/var/lib/openebs/zfs/openebs-zpool.img` and configures auto-import on boot.

### Option 2: Multi-Disk Setup (mirror)

For servers with multiple disks, create a mirrored pool:

```bash
sudo apt update && sudo apt install zfsutils-linux -y
sudo zpool create -f openebs-zpool mirror /dev/sda /dev/sdb
```

---

## Install OpenEBS

```bash
bash helm.sh
```

Then apply the storage class:

```bash
kubectl apply -f zfs-storage.yml
```

---

## Verify Setup

```bash
sudo zpool status openebs-zpool
sudo zfs list
kubectl get storageclass
```

---

## Using ZFS Storage in JupyterHub

Add to your JupyterHub config:

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

---

## Troubleshooting

**Pool not imported after reboot:**
```bash
sudo zpool import -d /var/lib/openebs/zfs openebs-zpool
sudo systemctl enable zfs-import-openebs.service
```

**Check pool health:**
```bash
sudo zpool status -v openebs-zpool
```

See: https://github.com/openebs/zfs-localpv/blob/develop/docs/quickstart.md
