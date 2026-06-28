---
title: "Node Placement & Cirrus Pinning"
weight: 5
bookToc: true
---

# Node Placement: keep the data path on cirrus

The active cluster has two nodes:

| Node | Role | Hardware | Status |
|------|------|----------|--------|
| **cirrus** | control-plane + **primary data/compute node** | Threadripper, ECC RAM, 2× Quadro RTX 8000, NVMe | Always schedulable — **never cordon** |
| **thelio** | expansion worker | Ryzen 9, RTX 2080, ZFS pool (HDD/SMR, problematic) | Currently **cordoned / parked** pending zpool repair |

thelio was only ever meant to be an expansion node. All stateful and
bandwidth-critical services live on **cirrus**, where the data physically is
(NVMe object store, the `tank` ZFS pool that backs every JupyterHub home).

## Why this matters: the MinIO ↔ JupyterHub hairpin

JupyterHub user pods reach the object store over the public S3 endpoint
`minio.carlboettiger.info` (HTTPS), which resolves to cirrus's own IP. The data
path is:

```
user pod ──> minio.carlboettiger.info ──> Traefik (TLS) ──> minio-svc ──> MinIO pod
```

If **Traefik** or **MinIO** is scheduled on thelio while the user pods are on
cirrus, that path crosses the 1 Gb physical link (one or two VXLAN hops) and is
capped at **~0.94 Gb/s**. With all three co-located on cirrus the traffic never
leaves the box and runs at **~3 Gb/s** (limited by TLS/MinIO CPU, not the wire).

This is exactly what happened when cirrus got cordoned during a k3s upgrade:
CoreDNS/Traefik were evicted onto thelio and the S3 path silently dropped to
1 Gb. See the cordon policy below.

## The invariants (and where they're encoded)

### 1. cirrus must never be cordoned

The k3s **system-upgrade-controller** plans (`k3s/upgrade/plans.yml`) are set to
`cordon: false`. With `cordon: true`, a k3s upgrade cordons cirrus and restarts
k3s, evicting CoreDNS/Traefik onto thelio and frequently leaving cirrus stuck
`SchedulingDisabled`. **Never re-enable cordon on the server-plan.**

If cirrus is ever found cordoned: `kubectl uncordon cirrus`, then confirm
`kubectl -n system-upgrade get plan server-plan -o jsonpath='{.spec.cordon}'`
is `false`.

### 2. MinIO is pinned to cirrus

`minio/minio.yaml` sets `nodeSelector: kubernetes.io/hostname: cirrus` and
`strategy: Recreate`. Two reasons:

- **Data safety.** MinIO's data lives in `hostPath` dirs (`/mnt/nvme2`,
  `/mnt/nvme3`) that exist **only on cirrus**, with `type: DirectoryOrCreate`.
  Without the pin, the scheduler could place MinIO on thelio, where it would
  silently create *empty* data dirs and serve an empty object store.
- **Throughput.** Keeps the S3 endpoint on-node with the user pods (above).

`Recreate` prevents a rolling update from briefly running two MinIO pods against
the same data dirs (they would collide on MinIO's file locks).

### 3. Traefik is pinned to cirrus

`traefik/helmchartconfig.yaml` is a `HelmChartConfig` that overrides the
k3s-bundled Traefik chart with `nodeSelector: kubernetes.io/hostname: cirrus`.

> **Known issue (2026-06):** Traefik is stuck mid 39→40 chart upgrade — k3s
> wants chart `40.1.3` but the `traefik-crd` release is still `39.x`, so the
> 40.x CRD validation fails and the helm upgrade never completes. The running
> Traefik 39.x is healthy. Because the HelmChartConfig can't apply until that
> upgrade is unblocked, the live `traefik` Deployment was **also patched
> directly** with the same nodeSelector as an interim measure (failing helm
> upgrades don't revert it; a future successful upgrade supplies the identical
> value). **Follow-up:** unblock the Traefik 39→40 upgrade (sync the
> `traefik-crd` chart), after which the HelmChartConfig becomes the sole source
> of truth and the manual patch is redundant.

### CoreDNS

Left floating (only an `os: linux` selector). DNS is not bandwidth-bound, so its
node placement doesn't affect throughput. It is k3s-addon-managed, which makes
pinning awkward; not worth it.

## Bringing thelio back without regressing

When thelio's storage is fixed and you uncordon it (`kubectl uncordon thelio`):

- MinIO and Traefik stay on cirrus because they are pinned (items 2 & 3).
- Do **not** cordon cirrus to do it.
- Only per-node DaemonSets (storage/GPU/proxy agents) run on thelio; that is
  expected and unavoidable while it is a cluster member.
- To fully decommission thelio instead:
  `kubectl drain thelio --ignore-daemonsets --delete-emptydir-data` then
  `kubectl delete node thelio` and stop the k3s agent on it.
