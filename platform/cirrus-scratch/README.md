# cirrus-scratch — per-pod scratch space on cirrus

The `cirrus-scratch` StorageClass hands a pod a directory on cirrus's dedicated scratch disk,
mounted on the host at `/scratch`. Use it for large temporary files that should not land on
the node's root disk (which also holds the control plane and the container image store).

```bash
kubectl apply -f cirrus-scratch.yaml
```

## How to use it

As a [generic ephemeral volume](https://kubernetes.io/docs/concepts/storage/ephemeral-volumes/#generic-ephemeral-volumes):
the claim is created with the pod and deleted with it, and so is the data. The header of
[`cirrus-scratch.yaml`](cirrus-scratch.yaml) has the snippet. JupyterHub offers it as the
**Hardware → cirrus with /scratch** choice ([`../../services/jupyterhub/public-config.yaml`](../../services/jupyterhub/public-config.yaml)).

A pod that uses it is scheduled on cirrus (the class's `allowedTopologies`), so do not pair it
with anything that needs another node.

## `ci-work`: CI work directories

The same provisioner also serves `ci-work`, the class for the ARC runners' `_work` volumes
([`../../services/github-actions/`](../../services/github-actions/)). Runners prefer thelio and
spill to cirrus. On cirrus the volume goes to `/scratch`; on thelio it goes to the directory
K3s's local-path uses. Like any local-path volume, two pods on one node can both mount it
(runner and job pod), which the ZFS driver refuses.

## What it is not

- **Not durable.** The disk is a single, well-worn drive with no redundancy, chosen because
  nothing on it matters. Expect it to fail; keep results in a home directory or S3.
- **Not size-limited.** local-path ignores the requested size. One pod can fill the disk, but
  filling it cannot touch cirrus's root disk.
- **Not shared.** Each claim is its own directory; use JuiceFS (`../juicefs/`) for shared data.

## Why a second local-path instance

K3s bundles a local-path provisioner but owns its config (`kube-system/local-path-config`) and
rewrites it. This instance has its own namespace, provisioner name (`cirrus-scratch.local-path`),
RBAC and config. Each class has its own node map with no default entry, so a claim can never
fall back to an unlisted node's root disk.

## Host setup this depends on

`/scratch` is mounted from fstab with `nofail`, so a dead drive does not block boot. The bare
mountpoint is immutable (`chattr +i`), so if the drive is not mounted, provisioning fails
instead of writing to the root disk.
