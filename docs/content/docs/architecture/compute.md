---
title: "Compute and GPUs"
weight: 1
---

# Compute and GPUs

## Node roles

Nodes fill one of three roles. The roles are defined by labels and taints, not
by hostnames, so a machine can be added or moved between roles without
touching workload manifests.

| Role | Hardware | Runs | How it's marked |
|---|---|---|---|
| **Control plane and storage** | amd64 workstation (64-core Threadripper), 2× Quadro RTX 8000 48 GB, NVMe and SSD storage | the K3s server, all persistent storage, ingress, most services, CI runners, speech-to-text, CPU and GPU notebooks | untainted |
| **GB10 pool** | NVIDIA GB10 (Grace Blackwell) machines: arm64, ~120 GB unified CPU/GPU memory each | LLM serving first; GPU notebooks on any machine not serving a model | taint `dedicated=gb10:NoSchedule`; label `node-class=gb10` |
| **General worker** | amd64 workstation, consumer GPU | notebooks, batch jobs, any workload that doesn't need storage on its own node | untainted |

Nothing schedules on a tainted node unless it tolerates the taint. LLM
deployments, the GB10 notebook option and Armada batch jobs tolerate
`dedicated=gb10`. DaemonSets that must run everywhere,
such as GPU plugins, exporters and the storage client, list each taint
explicitly.

Models come first on the GB10s. A model claims all 8 GPU slices of its machine
and runs at a higher scheduling priority than notebooks; a GB10 notebook claims
4. So notebooks use only machines serving no model, two to a machine, and
starting a model on a machine stops the notebooks there. Every GB10 runs the
shared-home storage client; none holds other cluster data.

A model's GPU memory on a GB10 isn't counted against its pod, so each model
requests its machine's whole memory. That keeps anything else from being
placed on a machine that only looks empty.

## Batch jobs

[Armada]({{< relref "/docs/using/batch-jobs" >}}) fills whatever capacity is
left on every node with queued batch jobs. Its jobs run at negative priority
and never preempt: notebooks, services and models evict them, and evicted jobs
go back in the queue. In practice batch jobs use the control-plane node, the
general worker, and any GB10 not serving a model.

## GPUs

GPUs are exposed by the
[NVIDIA device plugin](https://github.com/NVIDIA/k8s-device-plugin). Each node
picks a sharing mode with the label `nvidia.com/device-plugin.config`:

| Mode | Used on | Effect |
|---|---|---|
| `timeslice-cdi` | the RTX 8000s and the GB10s | each GPU is advertised as 8 `nvidia.com/gpu` slices, so pods can share a card. Slices are scheduling slots, not memory partitions: every pod sees the whole card. |
| `no-sharing` | the small consumer GPU | one pod per GPU |

The cards don't support MIG. The cluster doesn't use MPS: it can't be limited
to some GPUs, and memory-heavy LLM serving and light notebook work coexist
fine under time-slicing. On a GB10, GPU memory is the machine's unified RAM,
so memory limits for a model come from the model server's own settings, not
from Kubernetes.

GPU pods use the `nvidia` runtime class.

## Architectures

The GB10s are arm64; everything else is amd64. Images that may run on both
are built multi-arch: the lab images are built natively on amd64 and arm64
runners. Workloads that are amd64-only pin `kubernetes.io/arch: amd64`.
