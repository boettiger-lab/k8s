# NVIDIA GPU Configuration

Deploys the NVIDIA Kubernetes device plugin (Helm release `nvdp`, namespace
`nvidia-device-plugin`) so GPUs are visible to K3s and shareable across pods. One
release covers all three GPU nodes; how each node shares its GPU is a per-node label,
not a separate install.

```bash
bash nvidia-device-plugin.sh   # idempotent helm upgrade --install
```

## Per-node GPU sharing

Sharing is configured per node via the `nvidia.com/device-plugin.config` label
(see `nvidia-device-plugin-config.yaml`):

- **cirrus** (`timeslice`): time-slicing, 8 replicas/GPU → 16 `nvidia.com/gpu`
  slices. Time-slicing does **not** partition VRAM — a slice is just a
  bookkeeping slot capping how many pods share a GPU; every pod sees the full
  48 GB of its card. LLMs (vLLM) claim slice(s) and use the whole card; light
  notebooks claim 1 each.
- **nimbus** (`timeslice`): 8 replicas of the single GB10. Same label, different
  reason: the Spark has **unified memory** — CPU and GPU share one ~122 GiB pool, so
  there is no VRAM to divide and the replica count is purely a cap on how many GPU
  pods the scheduler will place here. vLLM takes 6 of the 8 slices and leaves 2 free.
- **thelio** (`no-sharing`): one whole GPU per pod. Its 8 GB RTX 2080 split eight ways
  is ~1 GB a pod with no isolation. (It advertised 8 slices until 2026-09-07 purely
  because it was unlabelled and inherited `config.default`.)

```bash
kubectl label node cirrus nvidia.com/device-plugin.config=timeslice  --overwrite
kubectl label node nimbus nvidia.com/device-plugin.config=timeslice  --overwrite
kubectl label node thelio nvidia.com/device-plugin.config=no-sharing --overwrite
```

**Label every GPU node explicitly.** An unlabelled node silently inherits
`config.default: timeslice`, which is rarely what you want on a small card. Check with:

```bash
kubectl get nodes -L nvidia.com/device-plugin.config,nvidia.com/gpu.count,nvidia.com/gpu.replicas
```

Switching a node's mode restarts the plugin there and renames the product label —
`NVIDIA-GeForce-RTX-2080` gains or loses a `-SHARED` suffix — so any pod pinning
`nvidia.com/gpu.product` in a nodeSelector must be updated to match.

No card in the cluster supports MIG (two Turing generations and a GB10). We use **time-slicing, not MPS**: MPS
would add hard per-slice VRAM caps but cannot be limited to one GPU (the plugin
ignores `devices`/`rename` for mps), so it would cap *all* GPUs — which a large
LLM (which needs ~a whole card) can't tolerate.

Full docs, including troubleshooting (post-restart "all GPUs unhealthy", MPS
sidecar crash-loop), are in `docs/content/docs/infrastructure/nvidia.md`.

Based on [NVIDIA's Improving GPU Utilization in K8s](https://developer.nvidia.com/blog/improving-gpu-utilization-in-kubernetes/).
