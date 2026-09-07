---
title: "Node Placement"
weight: 5
bookToc: true
---

# Node Placement: where a pod can actually run

The cluster has three nodes, and they are **not interchangeable**:

| Node | Role | Hardware | Taint |
|------|------|----------|-------|
| **cirrus** | control plane + **primary data/compute node** | Threadripper 3990X, ECC RAM, 2× Quadro RTX 8000, NVMe, ZFS `tank` | none — always schedulable, **never cordon** |
| **thelio** | jupyter user pods only | Ryzen 9 3900X, RTX 2080 8 GB | `hub.jupyter.org/dedicated=user:NoSchedule` |
| **nimbus** | GPU worker, sanctioned workloads only | DGX Spark GB10, **arm64**, 121 GiB unified memory | `dedicated=nimbus:NoSchedule` |

Three constraints decide placement, and a pod must satisfy all of them:

**Architecture.** nimbus is **arm64**; cirrus and thelio are amd64. Most images in this
cluster (including the JupyterHub profile images) are amd64-only, so anything destined
for nimbus needs an arm64 image and usually
`nodeSelector: kubernetes.io/arch: arm64`.

**Taints.** Both workers are tainted, so nothing lands on them by accident — a pod needs
the matching toleration. Only DaemonSets with blanket tolerations (node-exporter, the
GPU plugins, the JuiceFS shutdown unit) run everywhere.

**Storage.** `openebs-zfs` volumes are node-local and only cirrus runs a zfs-localpv
node plugin, so a PVC on that class pins its pod to cirrus. Home directories are the
exception: JuiceFS is ReadWriteMany over the network, so a notebook can start on any
node — see [Shared home storage]({{< relref "shared-home-storage" >}}).

All stateful and bandwidth-critical services live on **cirrus**, where the data
physically is (the NVMe object store and the `tank` ZFS pool).

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

The k3s **system-upgrade-controller** plans (`cluster/upgrade/plans.yml`) are set to
`cordon: false`. With `cordon: true`, a k3s upgrade cordons cirrus and restarts
k3s, evicting CoreDNS/Traefik onto another node and frequently leaving cirrus stuck
`SchedulingDisabled`. **Never re-enable cordon on the server-plan.**

If cirrus is ever found cordoned: `kubectl uncordon cirrus`, then confirm
`kubectl -n system-upgrade get plan server-plan -o jsonpath='{.spec.cordon}'`
is `false`.

### 2. MinIO is pinned to cirrus

`services/minio/minio.yaml` sets `nodeSelector: kubernetes.io/hostname: cirrus` and
`strategy: Recreate`. Two reasons:

- **Data safety.** MinIO's data lives in `hostPath` dirs (`/mnt/nvme2`,
  `/mnt/nvme3`) that exist **only on cirrus**, with `type: DirectoryOrCreate`.
  Without the pin, the scheduler could place MinIO on thelio, where it would
  silently create *empty* data dirs and serve an empty object store.
- **Throughput.** Keeps the S3 endpoint on-node with the user pods (above).

`Recreate` prevents a rolling update from briefly running two MinIO pods against
the same data dirs (they would collide on MinIO's file locks).

### 3. Traefik is pinned to cirrus

`platform/traefik/helmchartconfig.yaml` is a `HelmChartConfig` that overrides the
k3s-bundled Traefik chart with `nodeSelector: kubernetes.io/hostname: cirrus`.
The helm-controller merges it on every reconcile, so the pin survives k3s
upgrades and reboots.

> **History (2026-06):** Traefik had been stuck mid 39→40 chart upgrade — k3s
> wanted chart `40.1.3` but the `traefik-crd` release lagged at `39.x`, so the
> 40.x chart's CRD validation failed and the `traefik` upgrade never completed
> (the running 39.x stayed healthy). The stale `helm-install-traefik-crd` job
> had completed and would not re-run. Fix: delete `helm-install-traefik-crd`
> (helm-controller recreates it and upgrades the CRD chart to 40.x first), then
> delete the stuck `helm-install-traefik` job. Traefik is now `40.1.3`
> (app v3.7.1) and the HelmChartConfig nodeSelector applies cleanly. This
> delete-the-stale-job trick is the general remedy for a wedged k3s HelmChart
> reconcile.

### 4. nimbus is tainted, not cordoned

nimbus is the one node that is deliberately *not* generally available. It
registers with `node-taint: dedicated=nimbus:NoSchedule` set in
`/etc/rancher/k3s/config.yaml`, so it is never schedulable for general work —
not even for the moment between joining and being configured.

A taint rather than a cordon, because the two are not the same tool:

- **Cordon** is an operational, temporary state (`unschedulable: true`), and
  anything that reconciles the node — an upgrade plan, an accidental
  `kubectl uncordon` — clears it. It is also cluster-wide and all-or-nothing.
- **A taint** is declarative and selective. It is part of the node's
  registration, survives reboots and upgrades, and lets specific workloads opt
  in with a matching toleration.

Two reasons nimbus needs that:

1. **Architecture.** nimbus is arm64; cirrus and thelio are amd64. Most of the
   cluster's images are amd64-only, so a pod that lands on nimbus by accident
   does not fail politely — it `CrashLoopBackOff`s with an exec-format error.
2. **Unified memory.** The GB10 has no discrete VRAM. GPU allocations come out
   of the same 121 GiB pool as the OS and every other pod, cgroup limits do not
   bound CUDA, and over-committing it has twice wedged the NVIDIA driver hard
   enough to need a physical power cycle. Co-tenancy on this node is a hazard,
   not a feature. See
   [`cluster/nodes/nimbus/`](https://github.com/boettiger-lab/k8s/tree/main/cluster/nodes/nimbus).

Sanctioned workloads declare it twice — a toleration to get past the taint, a
`nodeSelector` to actually land there:

```yaml
nodeSelector:
  kubernetes.io/hostname: nimbus
tolerations:
- key: dedicated
  operator: Equal
  value: nimbus
  effect: NoSchedule
```

A toleration alone is not enough: it grants *permission* to schedule on a
tainted node, it does not *attract* the pod there. Today the list is vLLM
(`services/vllm/qwen38-nimbus.yaml`), the GPU MCP data server (`services/mcp/`), and the GPU/feature
DaemonSets that must cover every GPU node — the NVIDIA device plugin,
node-feature-discovery and dcgm-exporter, whose chart values carry the
toleration.

Because Traefik is pinned to cirrus (item 3), `vllm-nimbus.carlboettiger.info`
and `gpu-mcp-nimbus.carlboettiger.info` resolve to **cirrus's** IP and hairpin
across the LAN to nimbus. That is the accepted trade for one uniform
ingress/cert/DNS path; the extra hop is irrelevant to token streaming, but it
does make cirrus a hard dependency for nimbus's endpoints.

nimbus holds no cluster storage. `tank`, OpenEBS ZFS-LocalPV, JuiceFS and RustFS
are all cirrus-side, and nothing storage-related tolerates the taint on purpose.
Its only stateful need is a hostPath model cache.

### CoreDNS

Left floating (only an `os: linux` selector). DNS is not bandwidth-bound, so its
node placement doesn't affect throughput. It is k3s-addon-managed, which makes
pinning awkward; not worth it.

## Scheduling onto the workers

### thelio — jupyter user pods only

thelio returned to service tainted `hub.jupyter.org/dedicated=user:NoSchedule`, so it
takes jupyter *user* pods and nothing else. That needs no per-workload configuration:
z2jh already puts a matching toleration on user pods, hub core pods tolerate `=core` and
stay on cirrus, and ARC is pinned to cirrus by nodeSelector. Its RTX 2080 is exposed as
**one exclusive GPU**, not time-sliced — 8 GB does not divide usefully.

New homes go on JuiceFS (`juicefs-home`) rather than `openebs-zfs`. A node-local volume
pins its pod to one node forever; RWX on JuiceFS removes the pin, so a server lost with
thelio restarts on cirrus with its home intact. Existing claims are untouched and stay on
cirrus.

Two things still hold now that it is schedulable again:

- MinIO and Traefik stay on cirrus because they are pinned (items 2 & 3).
- Do **not** cordon cirrus to move work onto thelio.

### nimbus — sanctioned workloads only

A workload meant for nimbus needs all three of an arm64 image,
`nodeSelector: kubernetes.io/hostname: nimbus` (or the arch label), and:

```yaml
tolerations:
- key: dedicated
  operator: Equal
  value: nimbus
  effect: NoSchedule
```

Its GPU is time-sliced 8 ways — on unified memory that is a cap on how many GPU pods land
there, not a memory partition. See [NVIDIA GPU support]({{< relref "nvidia" >}}).

To decommission a worker: `kubectl drain <node> --ignore-daemonsets
--delete-emptydir-data`, then `kubectl delete node <node>` and stop the k3s agent on it.
