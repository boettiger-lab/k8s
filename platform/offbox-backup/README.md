# offbox-backup — the object store's primary data, copied to thelio

The S3 store on cirrus holds data that exists nowhere else: `private-*`, `shared-*`,
`backup-archive` and a few unprefixed buckets. This is its off-box copy: a daily
`rclone sync` to a ZFS dataset on thelio's HDD pool, a different machine from cirrus.

- **Scope:** every bucket except the `public-*` buckets in NRP's STAC catalog (those
  are mirrors of NRP and come back from there). New buckets are picked up
  automatically.
- **History:** objects overwritten or deleted at the source are kept under
  `history/<run>/` for 90 days.
- **Guards:** the run aborts if the source lists under half the buckets of the last
  good run (an emptied store must not be mirrored), plus a per-bucket `--max-delete`.
- **Source:** MinIO today, through the in-cluster Service. At the RustFS cutover,
  change `RCLONE_CONFIG_SRC_ENDPOINT` (and `PROVIDER`); the `offbox-read` key is
  carried over by the IAM import.

## thelio's drives are for this only

There is **no StorageClass** for thelio's pool, on purpose: one would let any workload
claim those drives. The single volume is provisioned statically (`ZFSVolume` →
dataset `openebs-zpool/offbox-data`, a `PersistentVolume` pre-bound to this
namespace's PVC, `Retain`). Don't add a class for it.

## Files

| file | |
|---|---|
| `offbox-backup.yaml` | static volume, PVC, sync script, daily CronJob (10:30 UTC) |
| `mint-minio-key.sh` | creates or rotates the read-only `offbox-read` key and the Secret |

## Set up

```bash
bash platform/offbox-backup/mint-minio-key.sh
kubectl apply -f platform/offbox-backup/offbox-backup.yaml
kubectl -n offbox-backup create job --from=cronjob/offbox-sync offbox-sync-first
```

Check: `kubectl -n offbox-backup logs -f job/<name>`; the last good run is recorded in
`/backup/state/last-success` on the volume.
