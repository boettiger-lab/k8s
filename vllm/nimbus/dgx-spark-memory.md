# Kubernetes Memory and GPU Management on DGX Spark

## Background: Unified Memory Architecture

The NVIDIA DGX Spark (GB10 Grace Blackwell Superchip) uses a **unified memory architecture** — there is no discrete GPU VRAM. The CPU and GPU share a single 128 GiB LPDDR5X memory pool connected via NVLink-C2C. This is fundamentally different from datacenter GPUs like the H100, which have separate HBM VRAM (80 GiB) and host DRAM.

This distinction has significant implications for how Kubernetes memory management interacts with GPU workloads.

---

## How Kubernetes Memory Limits Work on Conventional Hardware

On a system with discrete GPU VRAM (e.g. H100):

- **CPU-side memory** (`memory` request/limit in the pod spec) is enforced by Linux cgroups. If a process exceeds the cgroup limit, the OOM killer terminates it.
- **GPU-side memory** (VRAM) is allocated via CUDA and is **invisible to cgroups**. It is not tracked or limited by the `memory` field in the pod spec.
- `nvidia.com/gpu: 1` grants access to the GPU device but imposes no memory limit on VRAM usage.

This means a pod on an H100 node can have `memory: 8Gi` in its spec while simultaneously allocating 70 GiB of GPU VRAM without any cgroup interference.

---

## How This Changes on DGX Spark

Because the DGX Spark has **no discrete VRAM**, all memory — whether used by the CPU, Python runtime, or CUDA kernels — comes from the same physical pool. The key question is: **does the Linux cgroup memory controller track CUDA allocations on unified memory?**

**Answer: No.** The NVIDIA container runtime on DGX Spark maps CUDA allocations outside the cgroup accounting domain, consistent with the behavior on discrete GPU systems. This was verified experimentally (see Testing section below).

This means:

- The `memory` limit in the pod spec only constrains **CPU-side allocations** (Python heap, OS buffers, page cache, etc.) — typically a few GiB for a vLLM process.
- GPU memory allocations (model weights, KV cache) via CUDA are **not subject to the cgroup limit** and will not trigger an OOM kill, regardless of what `memory` is set to.
- A pod with `memory: 32Gi` can load a 79 GiB model into the unified memory pool without being killed.

---

## Implications for Resource Management

Although the cgroup limit does not enforce GPU memory usage, the `memory` field in the pod spec still serves a critical function: **Kubernetes scheduler accounting**.

When a pod requests `memory: 85Gi`, the scheduler marks 85 GiB of the node's 128 GiB as allocated. This prevents other pods from being scheduled if they would push total memory requests beyond the node's capacity. Without an accurate memory request, Kubernetes has no way to know how much memory is actually in use and may schedule workloads that cause real OS-level OOM conditions.

**The memory request should reflect the actual expected unified memory consumption of the workload**, not just the CPU-side footprint. For a vLLM deployment loading a large model, this means accounting for:

- Model weights (e.g. ~34 GiB for a 120B NVFP4 model)
- KV cache allocation (controlled by `--gpu-memory-utilization`, applied against the full visible pool)
- Python/CPU-side overhead (~2–4 GiB)

For a deployment using `--gpu-memory-utilization 0.65` on a 121.69 GiB visible pool:
- vLLM reserves: 0.65 × 121.69 ≈ **79 GiB**
- CPU-side overhead: ~4 GiB
- Total request: **~83–85 GiB** is appropriate

Setting `memory: 32Gi` would be dangerously wrong — it would allow Kubernetes to schedule other large workloads concurrently, risking real OS OOM.

---

## GPU Slice Allocation and Concurrent Workloads

The DGX Spark exposes `nvidia.com/gpu: 8` logical GPU slices via the NVIDIA device plugin (time-sliced virtual GPUs, not MIG partitions). These slices share the same physical GPU compute and unified memory pool — they are scheduling units, not memory partitions.

**Claiming all 8 slices** for a single vLLM deployment would prevent any other GPU workload from running on the node, even when the LLM is idle.

**Claiming a subset** (e.g. 6 slices) leaves the remaining slices available for small concurrent workloads (classic ML training, inference jobs) that need minimal GPU memory.

With `--gpu-memory-utilization 0.65`, vLLM pre-allocates ~79 GiB at startup and holds it regardless of whether requests are being served. The remaining ~43 GiB of the unified pool is physically available for other workloads. Two additional GPU slice jobs requesting ~10–15 GiB each can run safely within this headroom.

**Recommended allocation for the vLLM deployment:**
- `nvidia.com/gpu: 6` — reserves 6 of 8 slices for the LLM
- `memory: 85Gi` — honest accounting of actual unified memory usage
- Remaining 2 slices + ~43 GiB available for concurrent small GPU jobs (which should request `memory: 10-15Gi` each to keep the scheduler honest)

This keeps the total memory requests at ~105–115 GiB out of 128 GiB, leaving a small buffer for the OS and system processes.

---

## Choosing `--gpu-memory-utilization`

This flag tells vLLM to reserve `utilization × total_visible_GPU_memory` for weights + KV cache combined. On DGX Spark, `total_visible_GPU_memory` is the full unified pool (~121.69 GiB), not the cgroup limit.

| Setting | Reserved by vLLM | KV cache headroom (after ~34 GiB weights) | Notes |
|---|---|---|---|
| 0.90 | ~109 GiB | ~75 GiB | Maximum context, leaves little room for other workloads |
| 0.65 | ~79 GiB | ~45 GiB | Balanced: good context, ~43 GiB free for concurrent jobs |
| 0.50 | ~61 GiB | ~27 GiB | Conservative, ample room for concurrent workloads |

For the Nemotron Super deployment at `--max-model-len 32768`, `0.65` provides far more KV cache than needed for that context length. If running with longer contexts or more concurrent requests, this can be raised.

---

## Testing

These conclusions were validated on the DGX Spark (GB10, DGX SW 7.4.0) on 2026-03-21.

**Test setup:**
- Image: `nvcr.io/nvidia/vllm:25.11-py3` (arm64)
- Model: `facebook/opt-125m` (tiny model, ~250 MB, chosen to minimize confounds)
- `--gpu-memory-utilization 0.3`
- Container `memory` limit: `32Gi`
- k3s 1.34.5 on Ubuntu 24.04

**Diagnostic design:**

The test was designed to distinguish two hypotheses:
- **H1 (cgroup-tracked)**: CUDA allocations count against the cgroup limit. With `0.3 × 128 GiB = ~38 GiB` target and a `32Gi` cgroup, the pod would OOMKill immediately.
- **H2 (not cgroup-tracked)**: CUDA allocations are invisible to cgroups. The pod would start successfully regardless of the `32Gi` limit.

**Result:** The pod started successfully and served requests. vLLM logs reported:

```
Initial free memory: 112.41 GiB
Free memory on device (112.41/121.69 GiB) on startup.
Desired GPU memory utilization is (0.3, 36.51 GiB).
```

vLLM saw **121.69 GiB** total (the unified pool, not the 32 GiB cgroup limit), reserved 36.51 GiB for the KV cache, and ran without incident — confirming **H2**: GPU memory allocations are not tracked by the cgroup memory controller on DGX Spark.

**Key takeaway:** On DGX Spark, set the pod `memory` request to reflect actual unified memory consumption for scheduler accuracy, but do not rely on it to prevent GPU memory overcommit — that must be managed through `--gpu-memory-utilization` and careful slice allocation across concurrent deployments.
