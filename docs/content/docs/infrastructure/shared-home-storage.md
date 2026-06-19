---
title: "Shared Home Storage (Proposed)"
weight: 10
bookToc: true
---

# Shared Home Storage for JupyterHub (Proposed)

> **Status: PROPOSED — not yet deployed.** This is a design/plan document.
> It is purely **additive**: it adds a new StorageClass alongside the existing
> `openebs-zfs` (ZFS LocalPV). Nothing about the current ZFS storage is removed
> or changed by adopting this.

## Problem

JupyterHub home directories currently use the `openebs-zfs` StorageClass
(ZFS LocalPV). ZFS LocalPV is **node-local**: a user's home PVC is provisioned
on one node's zpool, and the PVC's node affinity then **pins that user's pod to
that node forever**. Two consequences:

- A user can never move between nodes — if they ever land on a node, they're
  stuck there.
- `thelio` has no usable local pool for this (its disk is SMR HDD), so today all
  homes pin to `cirrus`'s `tank` SSD pool and `thelio` cannot serve notebook
  users at all (it would strand them).

We want users (and especially GPU notebooks) to be schedulable on **either**
node, with `/home/jovyan` following them.

## Approach: add a JuiceFS StorageClass (keep ZFS)

Add a [JuiceFS](https://juicefs.com/docs/community/introduction/) filesystem and
expose it as a **new** StorageClass, `juicefs-sc`. JuiceFS presents a POSIX
**ReadWriteMany** filesystem backed by an S3 object store (data) plus an external
metadata engine (the file index). Because the data lives in the object store and
is reached over the network, a JuiceFS PVC is **not node-pinned** — the pod can
run on any node and the home follows.

This is **not** a replacement for ZFS:

- `openebs-zfs` stays installed and is still the right choice for node-local
  scratch, databases, model caches, etc.
- The new JuiceFS backends actually **sit on top of ZFS**: the object store
  (RustFS) data volume and the metadata database both use `openebs-zfs` PVCs on
  `cirrus`'s `tank`. Each node's JuiceFS local cache uses that node's own disk.
- The only change to existing config is repointing JupyterHub's *home*
  StorageClass; existing ZFS home PVCs keep working and can be migrated at
  whatever pace we choose (or left in place via a hybrid profile).

### Architecture

```
 JupyterHub singleuser pod (cirrus OR thelio)
        │  /home/jovyan   (RWX PVC from juicefs-sc, not node-pinned)
        ▼
 JuiceFS CSI driver  ── per-node mount pod (local read cache on that node)
        │
        ├── metadata ──► PostgreSQL    (the file index — system of record)
        └── data ───────► RustFS (S3)  bucket: juicefs-homes
                          (RustFS + Postgres PVCs themselves use openebs-zfs)
```

## Decisions

| Decision | Recommendation | Rationale |
|---|---|---|
| Object store | **RustFS** (Apache-2.0, S3-compatible) | Our chosen S3 backend now that MinIO is source-available. JuiceFS treats it as a generic S3 endpoint. |
| Metadata engine | **PostgreSQL** (dedicated; *not* armada's) | The metadata DB *is* the filesystem — losing it orphans the data. Postgres gives ACID durability + trivial `pg_dump` backups. Redis is faster but loss-prone; revisit only if metadata ops bottleneck. |
| S3 endpoint | **in-cluster** RustFS service, **path-style** | Keeps the data path on the cluster network (fast, no ingress/TLS hop). RustFS is MinIO-compatible → path-style addressing. |
| Provisioning | **Dynamic** StorageClass, one subdir + **directory quota** per PVC | Mirrors today's `pvcNameTemplate`/quota model. |
| CSI mode | **mount-pod** mode (default) | Decouples the mount from the app pod; restarting the CSI driver doesn't kill live sessions. |
| Migration | **Additive + gradual** | Keep ZFS homes until each is migrated and verified; pilot on a throwaway user first. |

## Prerequisites (new stateful services — durability matters)

Homes will live here, so both backends need real durability:

1. **RustFS** (`rustfs/deployment.yaml`) backed by `cirrus`/`tank` (openebs-zfs),
   with its own redundancy/backup — it now holds home *data*, so a single-node
   RustFS is a data SPOF.
2. **Dedicated PostgreSQL** (e.g. a `juicefs` namespace) on `tank`, with WAL
   archiving / scheduled `pg_dump`. This DB is precious — back it up.

## Implementation steps

1. **Bucket + secret.** Create bucket `juicefs-homes` in RustFS with a scoped
   keypair. Store metadata URL, storage type, bucket, and keys in a k8s secret
   (`juicefs-secret`).

2. **Format the filesystem (one-time)** from a throwaway pod with the `juicefs`
   binary:
   ```
   juicefs format --storage s3 \
     --bucket http://rustfs.<ns>.svc:9000/juicefs-homes \
     --access-key $AK --secret-key $SK \
     "postgres://juicefs:***@<pg-svc>:5432/juicefs" jupyter-homes
   ```

3. **Deploy the JuiceFS CSI driver** (Helm, mount-pod mode):
   ```
   helm repo add juicefs https://juicedata.github.io/charts/
   helm upgrade -i juicefs-csi-driver juicefs/juicefs-csi-driver -n kube-system
   ```

4. **Create the new StorageClass** `juicefs-sc` referencing `juicefs-secret`,
   with mount options for local cache (`cache-dir`, `cache-size`) and per-volume
   directory quota driven by the PVC's requested size. `openebs-zfs` is left
   untouched.

5. **Repoint JupyterHub homes** (`jupyterhub/public-config.yaml`) — the only
   change to existing config:
   ```yaml
   singleuser:
     storage:
       type: dynamic
       capacity: 60Gi                 # becomes the JuiceFS directory quota
       dynamic:
         storageClass: juicefs-sc     # was: openebs-zfs
         pvcNameTemplate: claim-{escaped_user_server}
         storageAccessModes: [ReadWriteMany]   # was ReadWriteOnce
   ```
   Deploy with `cd jupyterhub && ./cirrus.sh`.

   *Hybrid option:* instead of flipping the hub-wide default, set
   `storageClass` per profile via `kubespawner_override` (e.g. a "thelio GPU"
   profile uses `juicefs-sc` while the default stays `openebs-zfs`).

6. **Migrate existing homes** (per user, while their server is stopped): a
   one-shot pod mounts the old `openebs-zfs` PVC and the new JuiceFS PVC and
   `rsync -aHAX /old/ /new/`. Pilot one user first.

7. **Cutover & clean up.** Keep the old `openebs-zfs` PVCs until each user is
   verified on JuiceFS; delete them only afterward.

## Validation (prove the friction is gone)

1. Spawn a server, write a file, stop it.
2. Force the next spawn onto **thelio** (temporary `singleuser.nodeSelector` or
   cordon `cirrus`) and confirm `/home/jovyan` mounts with the file present.
3. With GPU time-slicing already in place, a GPU notebook on `thelio` gets its
   RTX 2080 *and* its home over JuiceFS.

## Risks & mitigations

- **Metadata DB is a single point of catastrophic failure.** Back up Postgres
  (WAL + periodic dump); consider replication later. Losing it orphans all home
  data.
- **RustFS durability.** It now holds home data — give it redundant backing
  and/or a backup target.
- **Small-file / conda performance.** Networked FS is slow for thousands of tiny
  files (pip/conda envs, `.git`). Mitigations: per-node local cache; keep package
  caches/venvs on an `emptyDir` or in the image rather than `/home`; consider
  `--writeback` for write-heavy workloads (un-flushed writes are local until
  uploaded).
- **Two new stateful services to operate** (RustFS + metadata Postgres). Added
  surface area, justified by node mobility.

## Rollback

`openebs-zfs` and all existing home PVCs remain intact until cutover is
confirmed. To fall back, revert `storageClass` to `openebs-zfs` in
`public-config.yaml` and redeploy.

## Related

- [NVIDIA GPU Support]({{< relref "nvidia" >}}) — GPU time-slicing that this
  unblocks for `thelio`.
- [OpenEBS / ZFS LocalPV]({{< relref "openebs" >}}) — the node-local storage this
  complements.
