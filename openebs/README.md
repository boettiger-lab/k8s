# OpenEBS ZFS Storage for Kubernetes

OpenEBS ZFS-LocalPV provides node-local persistent storage with per-PVC disk
quotas. **All cluster storage lives on cirrus** — see [`cirrus/`](cirrus/).

> **nimbus has no storage role.** It joined the cluster as a compute-only,
> tainted worker ([`k3s/nimbus-join/`](../k3s/nimbus-join/)), and nothing
> storage-related tolerates that taint on purpose. Its old file-backed
> `openebs-zpool` and the `openebs/nimbus/` configs were retired with the
> merge; the pool is still on disk, orphaned, and can be reclaimed with
> `sudo zpool destroy openebs-zpool`. The only stateful thing nimbus needs is
> the hostPath HuggingFace cache at `/home/cboettig/.cache/huggingface`.

## Install

```bash
bash cirrus/helm.sh                     # the lean zfs-localpv driver
kubectl apply -f cirrus/zfs-storage.yml # StorageClass openebs-zfs -> pool `tank`
```

`tank` is a pre-existing native ZFS pool on cirrus (and thelio); it is not
created here. Do **not** install the full `openebs/openebs` umbrella chart —
it drags in Mayastor, LVM LocalPV and their own etcd/MinIO/Loki stack, none of
which we use, and a previous install left orphaned PVCs and CRDs behind.

## Verify

```bash
kubectl get pods -n openebs        # zfs-localpv controller + node daemonset
kubectl get sc openebs-zfs
kubectl get zfsvolumes -n openebs  # one per bound PVC, ZPOOL=tank
sudo zpool status tank
```

## Using ZFS storage in JupyterHub

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

Note that a `ReadWriteOnce` ZFS-LocalPV volume ties its pod to the node holding
the dataset. For node-mobile home directories see [`../juicefs/`](../juicefs/).

## Troubleshooting

**Pool not imported after reboot:**
```bash
sudo zpool import tank
```

**Check pool health:**
```bash
sudo zpool status -v tank
```

See: https://github.com/openebs/zfs-localpv/blob/develop/docs/quickstart.md
