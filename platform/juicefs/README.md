# JuiceFS shared (RWX) home storage — cirrus

Multi-node, **ReadWriteMany** JupyterHub home dirs that are *not* node-pinned, so
`/home/jovyan` follows a user to any node. Every **new** JupyterHub claim —
default or named server — gets a `juicefs-home` volume
(`../../services/jupyterhub/public-config.yaml`). Homes created before that switch
stay on `openebs-zfs` (ZFS LocalPV, pinned to cirrus): z2jh reuses an existing PVC
and a bound PVC's class is immutable, so nothing is migrated implicitly.

Tracking issue: #7.

## Architecture

```
 JupyterHub user pod (any node)
        │  /home/jovyan   (RWX PVC from juicefs-home, not node-pinned)
        ▼
 JuiceFS CSI driver  ── per-node mount pod (local read cache)
        ├── metadata ──► PostgreSQL  (juicefs-pg, ns juicefs)   ← the file index
        └── data ───────► RustFS S3  (rustfs.rustfs.svc:9000, bucket juicefs-homes)
                          RustFS + Postgres PVCs both on cirrus/tank (openebs-zfs)
```

## Storage classes

- **`juicefs-home`** — jupyter home directories. No `writeback`, so a write is not
  acknowledged until it reaches the object store and a node loss cannot lose saved
  work.
- **`juicefs-sc`** — general RWX data. Carries `writeback` (async upload), which is
  fine for data that can be regenerated but not for homes.

Both are defined in `storageclass.yaml`; the comments there explain the split.

## Design decisions

- **Object store: a dedicated RustFS** (Apache-2.0), not MinIO, which is no longer
  maintained upstream. JuiceFS treats it as a generic S3 endpoint.
- **Metadata engine: a dedicated PostgreSQL** (`juicefs-pg`), not shared with any
  other service and not Redis. The metadata DB *is* the filesystem: losing it orphans
  every object in the bucket. Postgres gives ACID durability and plain `pg_dump`
  backups; Redis is faster but loss-prone. Revisit only if metadata operations
  become the bottleneck.
- **In-cluster, path-style S3 endpoint** (`http://rustfs.rustfs.svc:9000`). The data
  path stays on the cluster network with no Traefik/TLS hop. RustFS's API has no
  Ingress for this reason. Keep that Service name and the bucket name stable across
  any backend move, so the reference stored in the JuiceFS format never changes.
- **CSI mount-pod mode** (the chart default). The FUSE mount lives in its own pod, so
  restarting or upgrading the CSI driver does not kill live notebook sessions.
- **Many small files are slow on any networked FS.** Package environments
  (conda/pip/venvs) and large `.git` trees belong in the image or on scratch, not in
  `/home`; the per-node local cache helps reads only.

### Three gotchas that bit us (don't repeat)

- **RustFS: do NOT set `RUSTFS_SERVER_DOMAINS`** — it forces virtual-host bucket
  parsing and breaks path-style in-cluster access (`InvalidBucketName`, buckets
  seem not to persist). Left unset in `rustfs/cirrus.yaml`.
- **Nodes need `fs.inotify.max_user_instances` raised** (default 128 is too low;
  the CSI plugin crash-loops with `too many open files`). Set to `8192` on
  `cirrus`, persisted in `/etc/sysctl.d/99-inotify-juicefs.conf`.
- **A stalled JuiceFS mount wedges the whole node, and then the shutdown.**
  When the metadata DB or RustFS stops answering, `juicefs` blocks in
  uninterruptible **D state** — unkillable by any signal. Because JuiceFS is a
  filesystem the block spreads to anything that stats the path (kubelet
  volume-stats, `df`, login shells), so load climbs while the CPUs idle and the
  node looks dead to SSH *and* to the console. The same unanswerable mount then
  strands `systemd-shutdown` in its final unmount loop, so the box never powers
  off. On `thelio` (2026-08-24) this ran for six hours and ended at the power
  button, which left the ZFS pool dirty and broke the following boot.

  Three things to know: **the trigger is usually not the wedged node** — check
  RustFS/Postgres on the master first. **`echo 1 > /sys/fs/fuse/connections/*/abort`
  releases every blocked process instantly**, no reboot needed. And a hardware
  watchdog does *not* help, because PID 1 stays healthy and keeps petting it.
  Deploy `node-shutdown-cleanup.yaml` (below) and see `../../cluster/nodes/`.

## Deploy order

1. **Secrets.** Copy `credentials.example.yaml`, fill in real keys, apply (the
   real copy must match the `*secret*.yaml` gitignore rule so it stays out of
   git). Creates `rustfs-secrets`, `juicefs-pg`, `juicefs-secret`.

2. **RustFS on cirrus/tank.**
   ```
   kubectl apply -f ../rustfs/cirrus.yaml
   ```
   Create the bucket `juicefs-homes` (via console at
   `rustfs.cirrus.carlboettiger.info`, or `mc mb`).

3. **Postgres metadata DB.**
   ```
   kubectl apply -f postgres.yaml
   ```

4. **Format the filesystem (one-time)** from a throwaway pod with the `juicefs`
   binary (values must match `juicefs-secret`):
   ```
   juicefs format --storage s3 \
     --bucket http://rustfs.rustfs.svc:9000/juicefs-homes \
     --access-key <AK> --secret-key <SK> \
     "postgres://juicefs:<PW>@juicefs-pg.juicefs.svc:5432/juicefs?sslmode=disable" \
     jupyter-homes
   ```
   (The CSI driver can also auto-format on first mount when the secret carries
   `metaurl`/`storage`/`bucket`/keys — explicit format is the safe path.)

5. **Node prerequisite:** raise `fs.inotify.max_user_instances` (default 128 is
   too low; the CSI plugin crash-loops with `too many open files`). Apply the
   DaemonSet that sets it to 8192 on every node:
   ```
   kubectl apply -f node-inotify.yaml
   ```

   Then install the shutdown teardown, or the node will hang on every power-off
   once JuiceFS is mounted (see gotcha 3):
   ```
   kubectl apply -f node-shutdown-cleanup.yaml
   ```

6. **Install the JuiceFS CSI driver** (Helm, mount-pod mode is the default).
   Pin the chart version we deployed for reproducibility:
   ```
   helm repo add juicefs https://juicedata.github.io/charts/ && helm repo update
   helm upgrade -i juicefs-csi-driver juicefs/juicefs-csi-driver \
     -n kube-system --version 0.31.10
   ```
   If you bump the version, re-check the parameter/mountOption names in
   `storageclass.yaml` against the new chart.

7. **StorageClass.**
   ```
   kubectl apply -f storageclass.yaml
   ```

8. **Point JupyterHub at it.** `singleuser.storage.dynamic.storageClass:
   juicefs-home` with `storageAccessModes: [ReadWriteMany]` in
   `../../services/jupyterhub/public-config.yaml`, then
   `cd ../../services/jupyterhub && ./up.sh`. Only claims created after this land
   on JuiceFS.

## Durability

- **Postgres**: `pg-backup.yaml` dumps it nightly, to a PVC on the same `tank` pool.
  That covers corruption or a bad migration, not loss of the pool; an off-box copy
  is still needed. Losing this DB orphans all home data.
- **RustFS**: a single replica on `tank`, with ZFS as the only redundancy layer.

## Validation

1. As a user with no existing home, spawn a server, write a file, stop it.
2. Confirm the PVC used `juicefs-home` (`kubectl -n jupyter get pvc | grep juicefs`).
3. Force the next spawn onto another node (e.g. the GB10 choice, or thelio) and
   confirm `/home/jovyan` mounts with the file present.

## Migrating an existing default home to JuiceFS (later, per user, opt-in)

While the user's server is stopped: a one-shot pod mounts the old `openebs-zfs`
PVC and a new JuiceFS PVC and `rsync -aHAX /old/ /new/`. Keep the old PVC until
verified. Rollback = revert the storage routing; nothing destructive until you
delete the old PVC.
