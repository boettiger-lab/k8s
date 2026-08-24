# OpenEBS ZFS storage — active cluster (cirrus + thelio)

Persistent storage for the active k3s cluster (cirrus control-plane, thelio worker)
via OpenEBS ZFS LocalPV, backed by the native ZFS pool `tank` on each node.

> **Note:** This is a *separate* cluster from `nimbus/`. The `nimbus/` configs describe
> a different k3s cluster (file-backed `openebs-zpool`) and do not apply here.

## What's deployed

- **Driver:** `zfs-localpv` Helm chart (lightweight ZFS CSI driver only).
- **StorageClass:** `openebs-zfs` → pool `tank`, lz4 compression, 128k recordsize.
- **Consumers:** JupyterHub singleuser home directories (`claim-*` PVCs in `jupyter`).

We deliberately do **not** run the full `openebs/openebs` umbrella chart. It pulls in
Mayastor (with its own etcd / MinIO / Loki stack) and LVM LocalPV, none of which we use.
A previous umbrella install left orphaned PVCs/PVs and LVM CRDs behind; those have been
removed. Stick to the two steps below.

## Setup

```bash
# 1. Install the ZFS LocalPV driver
bash openebs/cirrus/helm.sh

# 2. Apply the StorageClass
kubectl apply -f openebs/cirrus/zfs-storage.yml
```

The `tank` pool is a pre-existing native ZFS pool on the hosts; it is not created here.

## Verify

```bash
kubectl get pods -n openebs            # zfs-localpv controller + node daemonset
kubectl get sc openebs-zfs
kubectl get zfsvolumes -n openebs      # one per bound PVC, ZPOOL=tank
sudo zpool status tank
```
