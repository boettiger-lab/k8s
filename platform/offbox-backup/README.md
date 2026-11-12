# offbox-backup — the object store's primary data, copied to thelio

Two things on cirrus's `tank` exist nowhere else: the S3 store's primary buckets
(`private-*`, `shared-*`, `backup-archive`, …) and the JuiceFS home directories (their
chunk bucket `juicefs-homes` on the pilot RustFS, and the Postgres metadata DB that
indexes it). This is their off-box copy, on a ZFS dataset on thelio's HDD pool, a
different machine from cirrus.

| job | when (UTC) | copies |
|---|---|---|
| `offbox-juicefs-meta` | 05:00 | `pg_dump -Fc` of the JuiceFS metadata DB → `juicefs/meta/`, 30 days |
| `offbox-sync` | 10:30 | S3 store buckets → `buckets/`; `juicefs-homes` → `juicefs/chunks/` |

The dump runs first, so every chunk it references is in that day's sync; chunks
deleted in between are in `history/`.

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
| `mint-minio-key.sh` | read-only `offbox-read` key on MinIO → Secret `offbox-source` |
| `mint-juicefs-access.sh` | read-only `offbox-read` key on the pilot RustFS (`juicefs-homes` only) and Postgres role `offbox_dump` (`pg_read_all_data`) → Secret `offbox-juicefs` |

## Set up

```bash
bash platform/offbox-backup/mint-minio-key.sh
bash platform/offbox-backup/mint-juicefs-access.sh
kubectl apply -f platform/offbox-backup/offbox-backup.yaml
kubectl -n offbox-backup create job --from=cronjob/offbox-sync offbox-sync-first
```

Check: `kubectl -n offbox-backup logs -f job/<name>`; the last good run is recorded in
`/backup/state/last-success` on the volume.

## Restoring the homes

A home restore needs both halves from the same day or earlier: `pg_restore` the dump
into a fresh database, then point the volume at the copied chunks (`juicefs config
<meta-url> --storage file --bucket /backup/juicefs/chunks/`) and mount read-only. If a
file's chunk is missing, look in `history/<run>/juicefs-homes/`.
