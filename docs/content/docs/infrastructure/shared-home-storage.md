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
| Object store | **RustFS** (Apache-2.0, S3-compatible) | Our chosen S3 backend now that MinIO is source-available. JuiceFS treats it as a generic S3 endpoint. **Decoupled from the MinIO→RustFS migration:** we stand up a *dedicated* RustFS on `cirrus`/`tank` for the `juicefs-homes` bucket **now**, leaving the existing MinIO (`/mnt/nvme2,3` hostPath) fully untouched. Migrating MinIO's existing data to RustFS is a separate, later effort. |
| Metadata engine | **PostgreSQL** (dedicated; *not* armada's) | The metadata DB *is* the filesystem — losing it orphans the data. Postgres gives ACID durability + trivial `pg_dump` backups. Redis is faster but loss-prone; revisit only if metadata ops bottleneck. |
| S3 endpoint | **in-cluster** RustFS service, **path-style** | Keeps the data path on the cluster network (fast, no ingress/TLS hop). RustFS is MinIO-compatible → path-style addressing. |
| Provisioning | **Dynamic** StorageClass, one subdir + **directory quota** per PVC | Mirrors today's `pvcNameTemplate`/quota model. |
| CSI mode | **mount-pod** mode (default) | Decouples the mount from the app pod; restarting the CSI driver doesn't kill live sessions. |
| Migration | **Additive + gradual** | Keep ZFS homes until each is migrated and verified. |
| Pilot axis | **Named servers**, *not* image/profile | A *named server* already gets its own fresh, separate home today, so "new named server → JuiceFS RWX home" matches existing behavior. The **default** server (everyone's existing populated home) stays on `openebs-zfs` and is never touched. Storage is deliberately **decoupled from image choice** so picking the GPU image for a default server does not hide a user's files. |

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

5. **Route named servers to JuiceFS** (`jupyterhub/public-config.yaml`) — the
   only change to existing config, and it is *additive*: the hub-wide default
   stays `openebs-zfs`/RWO. A `pre_spawn_hook` switches storage **only for named
   servers** (non-empty `spawner.name`); the default server is untouched:
   ```yaml
   hub:
     extraConfig:
       10-juicefs-named-servers: |
         def pre_spawn_hook(spawner):
             # Named servers get a fresh RWX (node-mobile) home on JuiceFS.
             # The default server (empty name) keeps openebs-zfs + RWO.
             if spawner.name:
                 spawner.storage_class = "juicefs-sc"
                 spawner.storage_access_modes = ["ReadWriteMany"]
         c.KubeSpawner.pre_spawn_hook = pre_spawn_hook
   ```
   Deploy with `cd jupyterhub && ./cirrus.sh`.

   **Why named servers, not a profile/image option:** image choice
   (`profileList`) is orthogonal to home storage — a user may run the GPU image
   on their *default* server, and that server must keep its existing files.
   Keying on `spawner.name` instead means storage never depends on the image.

   **Safety property:** existing named-server PVCs (e.g. `claim-cboettig--test`)
   are already bound to `openebs-zfs`; a bound PVC's `storageClass` is immutable
   and kubespawner reuses an existing PVC rather than recreating it. So existing
   named servers keep their data on ZFS — **only named servers created after
   this change land on JuiceFS.** The pilot is exercised simply by spawning a
   *new* named server.

6. **Migrate existing homes** (per user, while their server is stopped): a
   one-shot pod mounts the old `openebs-zfs` PVC and the new JuiceFS PVC and
   `rsync -aHAX /old/ /new/`. Pilot one user first.

7. **Cutover & clean up.** Keep the old `openebs-zfs` PVCs until each user is
   verified on JuiceFS; delete them only afterward.

## Sizing & future NVMe pool

- **Size the RustFS data PVC generously up front (1Ti).** It is a thin/sparse
  ZFS claim, so the number is a quota ceiling, not a reservation, and `tank` has
  the headroom.
- **Enable volume expansion.** The live `openebs-zfs` StorageClass has
  `allowVolumeExpansion: false`, so a PVC can't be grown without recreating it.
  Flip it to `true` (a mutable SC field; ZFS-LocalPV supports online expansion)
  so future growth is a one-liner:
  ```
  kubectl patch sc openebs-zfs -p '{"allowVolumeExpansion": true}'
  ```

### When the new NVMe disks arrive

Do **not** add the NVMe as general data vdevs to the SSD `tank`: ZFS stripes
across all top-level vdevs (balanced by free space) and can't pin data to the
fast vdev, so you'd get blended, unpredictable performance and couple the pool's
redundancy across mismatched hardware. (The only sane "mix into one pool"
patterns are accelerator roles — `special`/`log`/`cache` vdevs — but object
*data* should live on the NVMe itself.)

Instead, build a **separate dedicated NVMe pool** (with redundancy — e.g. 2×
mirror vdevs or raidz1 across 4 disks; homes are precious). OpenEBS ZFS-LocalPV
selects the pool **per-StorageClass** via the `poolname` parameter (the same
mechanism behind `cirrus`/`tank` vs `thelio`/`openebs-zpool`), so the move is:

1. Create the NVMe zpool, add a new SC (e.g. `openebs-nvme`, `poolname: nvme`).
2. Stand a fresh RustFS PVC on `openebs-nvme` and `mc mirror` the bucket over.
3. Cut the RustFS Deployment to the new PVC, **keeping the in-cluster Service
   name and bucket stable** (`rustfs.rustfs.svc:9000` / `juicefs-homes`) so the
   JuiceFS backend reference never changes.

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
