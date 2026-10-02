---
title: "Storage"
weight: 2
---

# Storage

All persistent storage lives on the control-plane node. There are four
layers, each for a different job.

| Layer | Backed by | Used for | Storage class |
|---|---|---|---|
| **ZFS LocalPV** | [OpenEBS ZFS-LocalPV](https://github.com/openebs/zfs-localpv) on a mirrored ZFS pool | databases, service state, older home directories | `openebs-zfs`, `openebs-zfs-ext4` |
| **Shared home directories** | [JuiceFS](https://juicefs.com/): metadata in PostgreSQL, data in an in-cluster [RustFS](https://rustfs.com/) S3 store | JupyterHub homes, mountable read-write from any node | `juicefs-home`, `juicefs-sc` |
| **Object storage** | MinIO on dedicated NVMe drives | user-facing S3 ([Object storage]({{< relref "/docs/using/object-storage" >}})) | — |
| **Scratch** | K3s `local-path` | CI runner workspaces | `local-path` |

## Why shared homes

ZFS LocalPV volumes are node-local. A notebook that uses one can only start on
the node holding its volume. JuiceFS splits storage from compute: the data
still sits on the storage node, but any node with the JuiceFS client can mount
a home. This is what lets a notebook land on a GB10 or the notebook node with
the same home directory. `juicefs-home` is the default for new homes.
`juicefs-sc` adds client-side write-back caching for workloads that can
tolerate it.

## Backups

The JuiceFS metadata database is backed up on a schedule. Details of the
physical drives and the backup targets are kept in the lab's internal
operations notes.
