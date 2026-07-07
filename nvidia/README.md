# NVIDIA GPU Configuration

Deploys the NVIDIA Kubernetes device plugin (Helm release `nvdp`, namespace
`nvidia-device-plugin`) so GPUs are visible to K3s and shareable across pods.

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
- **thelio** (`no-sharing`): 1 whole GPU per pod (8 GB RTX 2080 is too small to slice).

```bash
kubectl label node cirrus nvidia.com/device-plugin.config=timeslice  --overwrite
kubectl label node thelio nvidia.com/device-plugin.config=no-sharing --overwrite
```

Neither card supports MIG (both Turing). We use **time-slicing, not MPS**: MPS
would add hard per-slice VRAM caps but cannot be limited to one GPU (the plugin
ignores `devices`/`rename` for mps), so it would cap *all* GPUs — which a large
LLM like qwen3-6 (needs ~a whole card) can't tolerate.

Full docs, including troubleshooting (post-restart "all GPUs unhealthy", MPS
sidecar crash-loop), are in `docs/content/docs/infrastructure/nvidia.md`.

Based on [NVIDIA's Improving GPU Utilization in K8s](https://developer.nvidia.com/blog/improving-gpu-utilization-in-kubernetes/).
