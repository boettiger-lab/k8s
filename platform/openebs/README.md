# OpenEBS ZFS LocalPV — node-local persistent storage

Backs `ReadWriteOnce` PersistentVolumeClaims with datasets on the native ZFS pool
`tank`. This is the *node-local* storage layer; for home directories that follow a
user between nodes, see [`../juicefs/`](../juicefs/).

## What is deployed

- **Driver:** the lightweight `zfs-localpv` Helm chart (ZFS CSI driver only).
- **StorageClasses:** `openebs-zfs` (ZFS dataset, 128k recordsize) and
  `openebs-zfs-ext4` (ext4 on a zvol, 16k — for workloads that need real block
  semantics). Both use pool `tank`, lz4 compression, and allow volume expansion.
- **Consumers:** JupyterHub singleuser homes (`claim-*` PVCs in `jupyter`), the JuiceFS
  Postgres metadata DB and its backups, RustFS data, Prometheus and Grafana, and
  hash-archive (the one `openebs-zfs-ext4` user — LevelDB needs block semantics).

**All cluster storage lives on cirrus.** Only cirrus runs a zfs-localpv node plugin, so
a PVC on these classes pins its pod there.

> **nimbus has no storage role.** It joined as a compute-only, tainted worker
> ([`../../cluster/nodes/nimbus/join/`](../../cluster/nodes/nimbus/join/)) and nothing
> storage-related tolerates that taint, on purpose. Its old file-backed `openebs-zpool`
> and the `openebs/nimbus/` configs were retired with the merge; the pool is still on
> disk, orphaned, and can be reclaimed with `sudo zpool destroy openebs-zpool`. The one
> stateful thing nimbus needs is the hostPath HuggingFace cache at
> `/home/cboettig/.cache/huggingface`.

We deliberately do **not** run the full `openebs/openebs` umbrella chart — it pulls in
Mayastor (with its own etcd / MinIO / Loki stack) and LVM LocalPV, none of which we use.
An earlier umbrella install left orphaned PVCs/PVs and LVM CRDs behind; those are gone.

## Setup

```bash
bash platform/openebs/helm.sh                          # 1. install the driver
kubectl apply -f platform/openebs/storageclass.yaml    # 2. create the StorageClasses
```

`tank` is a pre-existing native ZFS pool on cirrus (and thelio); it is not created here.

## Verify

```bash
kubectl get pods -n openebs         # zfs-localpv controller + node daemonset
kubectl get sc | grep openebs
kubectl get zfsvolumes -n openebs   # one per bound PVC, ZPOOL=tank
sudo zpool status tank
```

## Using it

```yaml
spec:
  storageClassName: openebs-zfs
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 60Gi
```

The requested size is a real ZFS quota, so it is an enforced ceiling rather than a hint.

## Troubleshooting

**PVC stuck `Pending`** — the pod may have landed on a node with no pool. Check
`kubectl describe pvc` and confirm the node runs `zfs-localpv-node`.

Upstream quickstart: <https://github.com/openebs/zfs-localpv/blob/develop/docs/quickstart.md>
