# JuiceFS shared (RWX) home storage — cirrus

Multi-node, **ReadWriteMany** JupyterHub home dirs that are *not* node-pinned, so
`/home/jovyan` follows a user to any node. Additive — `openebs-zfs` (ZFS LocalPV)
stays the hub-wide default and is untouched.

Full design + rationale: `docs/content/docs/infrastructure/shared-home-storage.md`.
Tracking issue: #7.

## Architecture

```
 JupyterHub NAMED-server pod (default server stays on openebs-zfs)
        │  /home/jovyan   (RWX PVC from juicefs-sc, not node-pinned)
        ▼
 JuiceFS CSI driver  ── per-node mount pod (local read cache)
        ├── metadata ──► PostgreSQL  (juicefs-pg, ns juicefs)   ← the file index
        └── data ───────► RustFS S3  (rustfs.rustfs.svc:9000, bucket juicefs-homes)
                          RustFS + Postgres PVCs both on cirrus/tank (openebs-zfs)
```

## Status: NOT yet deployed

These manifests are scaffolding. Nothing here has been applied to the cluster.
The existing MinIO (ns `minio`, `/mnt/nvme2,3`) is **untouched** by all of this.

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

5. **Install the JuiceFS CSI driver** (Helm, mount-pod mode is the default):
   ```
   helm repo add juicefs https://juicedata.github.io/charts/ && helm repo update
   helm upgrade -i juicefs-csi-driver juicefs/juicefs-csi-driver -n kube-system
   ```
   Then re-check the parameter/mountOption names in `storageclass.yaml` against
   the installed chart version before applying it.

6. **StorageClass.**
   ```
   kubectl apply -f storageclass.yaml
   ```

7. **Route named servers to JuiceFS.** Add to `jupyterhub/public-config.yaml`
   under `hub:` (additive — default server stays openebs-zfs/RWO):
   ```yaml
   hub:
     extraConfig:
       10-juicefs-named-servers: |
         def pre_spawn_hook(spawner):
             if spawner.name:        # named server -> fresh RWX JuiceFS home
                 spawner.storage_class = "juicefs-sc"
                 spawner.storage_access_modes = ["ReadWriteMany"]
         c.KubeSpawner.pre_spawn_hook = pre_spawn_hook
   ```
   Deploy: `cd ../jupyterhub && ./cirrus.sh`.

   Existing named-server PVCs are already bound to `openebs-zfs` and are reused
   as-is (storageClass is immutable on a bound PVC), so only **newly created**
   named servers land on JuiceFS. Test by spawning a brand-new named server.

## Recommended one-time tweak

Enable PVC expansion on the ZFS class so RustFS/Postgres can grow without
recreate (also eases the future NVMe-pool move):
```
kubectl patch sc openebs-zfs -p '{"allowVolumeExpansion": true}'
```

## Durability TODO before trusting real home data

- **Postgres**: scheduled `pg_dump` (CronJob) and/or WAL archiving. Losing this
  DB orphans all home data.
- **RustFS**: it now holds home *data* — give it a backup target (e.g. `mc mirror`
  to MinIO or off-cluster) and/or redundancy.

## Validation

1. Spawn a **new named server**, write a file, stop it.
2. Confirm the PVC used `juicefs-sc` (`kubectl -n jupyter get pvc | grep juicefs`)
   and the default server's home is still on `openebs-zfs`.
3. When a second node serves users again (thelio repaired, or the arm64 DGX
   Spark), force a spawn there and confirm `/home/jovyan` mounts with the file
   present — proving the home is no longer node-pinned.

## Migrating an existing default home to JuiceFS (later, per user, opt-in)

While the user's server is stopped: a one-shot pod mounts the old `openebs-zfs`
PVC and a new JuiceFS PVC and `rsync -aHAX /old/ /new/`. Keep the old PVC until
verified. Rollback = revert the storage routing; nothing destructive until you
delete the old PVC.
