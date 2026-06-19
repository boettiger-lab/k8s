---
title: "NVIDIA GPU Support"
weight: 2
bookToc: true
---

# NVIDIA GPU Support

GPU access in the K3s cluster is provided by the [NVIDIA Kubernetes device
plugin](https://github.com/NVIDIA/k8s-device-plugin), deployed with Helm. It
advertises GPUs to the scheduler and configures **GPU sharing** so multiple
pods can use a GPU at once.

## Live deployment (at a glance)

| | |
|---|---|
| Helm release | `nvdp` |
| Namespace | `nvidia-device-plugin` |
| Chart / app version | `nvidia-device-plugin-0.19.2` |
| Install/upgrade script | `nvidia/nvidia-device-plugin.sh` |
| Values | `nvidia/nvidia-device-plugin-config.yaml` |

> Older docs referenced namespace `kube-system` and a daemonset named
> `nvidia-device-plugin-daemonset`. That is **not** how it is deployed — it is a
> Helm release named `nvdp` in namespace `nvidia-device-plugin`.

### GPU nodes and sharing strategy

| Node | GPU(s) | VRAM | Sharing | Result |
|------|--------|------|---------|--------|
| `cirrus` | 2× Quadro RTX 8000 | 48 GB each | **time-slicing**, 8 replicas/GPU | 16 `nvidia.com/gpu` slices; no VRAM cap |
| `thelio` | 1× GeForce RTX 2080 | 8 GB | **none** | 1 whole GPU per pod (8 GB is too small to slice) |

Neither GPU supports **MIG** (both are Turing; MIG needs A100/H100/A30-class
cards — `nvidia.com/mig.capable=false` on both nodes).

## GPU sharing: time-slicing vs MPS vs MIG

The device plugin supports three sharing modes:

- **Time-slicing** — what we use on `cirrus`. The GPU round-robins compute
  between processes. A "slice" is **pure bookkeeping**: it does *not* partition
  VRAM, so every pod sees and may allocate the full 48 GB of whatever physical
  GPU it lands on. The `replicas` count just caps how many pods can share a GPU.
  A pod may claim **multiple** slices (we leave `failRequestsGreaterThanOne`
  false) — e.g. an LLM can claim several to crowd notebooks off its card, since
  the count is a co-tenancy cap, not a memory cap. No protection against one pod
  exhausting a card's VRAM (fine for cooperative / light workloads).
- **MPS (Multi-Process Service)** — adds a hard per-client VRAM cap
  (`total_VRAM ÷ replicas`). We do **not** use it: see the warning below.
- **MIG** — hardware-partitioned compute+memory. Strongest isolation, but
  unavailable on our Turing cards.

> ⚠️ **Why not MPS, despite the hard VRAM caps?** MPS would cap each slice at
> `48 GB ÷ replicas`, but the plugin **cannot limit MPS to a single GPU** — it
> ignores the per-resource `devices:` and `rename:` fields for `mps` sharing
> (logged: *"Customizing the 'devices' field in sharing.mps.resources is not yet
> supported … Ignoring"*). So MPS caps **all** GPUs on the node uniformly, and a
> large model like qwen3-6 (needs ~a whole 48 GB card) then no longer fits. A
> per-GPU MPS split would require hiding one GPU from the plugin via
> `NVIDIA_VISIBLE_DEVICES` (no Helm lever → a second release + post-upgrade
> patch) and running the LLM unmanaged. Not worth it; time-slicing is simpler and
> our shared GPU work is light. See [vLLM]({{< relref "../services/vllm" >}}).

## Configuration

Sharing is configured **per node** using the device plugin's named-config
feature. `nvidia/nvidia-device-plugin-config.yaml` defines a `config.map` with
two entries — `timeslice` and `no-sharing` — and each node selects one via the
`nvidia.com/device-plugin.config` label:

```bash
kubectl label node cirrus nvidia.com/device-plugin.config=timeslice  --overwrite
kubectl label node thelio nvidia.com/device-plugin.config=no-sharing --overwrite
```

`config.default` is `timeslice`; both real nodes are labelled explicitly.

### Applying changes

Edit `nvidia/nvidia-device-plugin-config.yaml`, then re-run the install script
(it is an idempotent `helm upgrade --install`):

```bash
bash nvidia/nvidia-device-plugin.sh
```

### Requesting GPUs in a pod

A slice is requested like any other resource. Pods also need the `nvidia`
runtime class:

```yaml
spec:
  runtimeClassName: nvidia
  containers:
  - name: cuda
    image: nvcr.io/nvidia/cuda:12.4.1-base-ubuntu22.04
    resources:
      limits:
        nvidia.com/gpu: 1   # one slice (full card VRAM on cirrus or thelio)
```

A large LLM can request several slices (e.g. `nvidia.com/gpu: 2`) — it still gets
the full VRAM of its card, but reserves bookkeeping slots so fewer other pods
land on the same GPU.

> **JupyterHub GPU profiles** in `jupyterhub/public-config.yaml` set
> `extra_resource_limits: {nvidia.com/gpu: "1"}` so notebooks claim a slice and
> are scheduled/accounted by k8s (rather than seeing all GPUs unmanaged via the
> nvidia runtime's "visible-devices" behaviour).

## Verifying

```bash
# GPUs advertised + strategy per node
kubectl get nodes -o custom-columns=\
'NODE:.metadata.name,ALLOC:.status.allocatable.nvidia\.com/gpu,\
STRATEGY:.metadata.labels.nvidia\.com/gpu\.sharing-strategy,\
REPLICAS:.metadata.labels.nvidia\.com/gpu\.replicas'
# cirrus -> 16 / time-slicing / 8 ;  thelio -> 1 / none

# Plugin pods (expect all Running; no mps-control-daemon under time-slicing)
kubectl get pods -n nvidia-device-plugin
```

## Troubleshooting

### All GPUs show `unhealthy` / allocatable drops to 0 after a reboot or K3s restart

**Symptom:** `kubectl get node cirrus -o jsonpath='{.status.allocatable.nvidia\.com/gpu}'`
returns `0` while `capacity` still shows the full count. The device-plugin log
shows every device `marked unhealthy: ERROR_NO_PERMISSION` / `ERROR_OPERATING_SYSTEM`.

**Cause:** a kubelet/K3s restart (e.g. an upgrade) forces the plugin to
re-register, and its XID-event health check can come up in a stale state and
falsely mark every GPU unhealthy. The GPUs themselves are fine (compute and
`nvidia-smi` still work); kubelet just keeps the last `capacity` while setting
`allocatable` to the count of *healthy* devices — which is now 0. Already-running
GPU pods keep their slices; no **new** GPU pod can schedule.

**Fix:** restart the plugin pod on the affected node (non-disruptive to running
GPU workloads):

```bash
kubectl delete pod -n nvidia-device-plugin <nvdp-nvidia-device-plugin-...>
# allocatable returns to its full count within a few seconds
```

### (Historical) MPS `config-manager` sidecar crash-loop

We no longer run MPS, but for the record: under MPS, the
`mps-control-daemon`'s `config-manager` sidecar (device-plugin 0.19.2) panics
with `index out of range [0] … findPidToSignal` if it has to *transition* the MPS
daemon between configs at startup. The workaround was to make the MPS node's
config the `config.default` so it never transitions. Not relevant under
time-slicing (no MPS daemon).

### Pod can't access a GPU

1. Confirm it requests `nvidia.com/gpu` **and** sets `runtimeClassName: nvidia`.
2. `kubectl describe pod <pod>` — check it scheduled onto a GPU node with free slices.
3. Check K3s containerd config at `/var/lib/rancher/k3s/agent/etc/containerd/config.toml`.

## Related Resources

- [NVIDIA Device Plugin](https://github.com/NVIDIA/k8s-device-plugin)
- [Time-Slicing / MPS / MIG sharing docs](https://github.com/NVIDIA/k8s-device-plugin?tab=readme-ov-file#shared-access-to-gpus)
- [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)
- [JupyterHub GPU Configuration]({{< relref "../services/jupyterhub" >}})
- [vLLM]({{< relref "../services/vllm" >}})
