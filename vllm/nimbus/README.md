# vLLM on Nimbus (DGX Spark)

Nimbus is an NVIDIA DGX Spark (aarch64/arm64). All images must be built locally on Nimbus and pushed to GHCR — do not use GitHub Actions runners for these, as cross-compiling large images via QEMU is impractically slow.

## Images

### `ghcr.io/boettiger-lab/vllm-dgx-spark:latest`

Built from `Dockerfile`. Installs a prebuilt aarch64 vLLM wheel on top of `nvcr.io/nvidia/pytorch:26.01-py3`. Used by the Nemotron deployment.

```bash
docker build -t ghcr.io/boettiger-lab/vllm-dgx-spark:latest .
docker push ghcr.io/boettiger-lab/vllm-dgx-spark:latest
```

### `ghcr.io/boettiger-lab/vllm-gemma4-audio:latest`

Built from `Dockerfile.gemma4`. Extends `vllm/vllm-openai:gemma4-cu130` with `vllm[audio]` extras (librosa, soundfile, av, etc.) needed for audio input support in Gemma 4.

```bash
docker build -f Dockerfile.gemma4 -t ghcr.io/boettiger-lab/vllm-gemma4-audio:latest .
docker push ghcr.io/boettiger-lab/vllm-gemma4-audio:latest
```

## Deployments

| File | Model | Image |
|------|-------|-------|
| `deployment.yaml` | openai/gpt-oss-120b | `nvcr.io/nvidia/vllm:25.09-py3` |
| `deploy-nemotron.yaml` | nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | `ghcr.io/boettiger-lab/vllm-dgx-spark:latest` |
| `deploy-gemma4.yaml` | google/gemma-4-E2B-it | `ghcr.io/boettiger-lab/vllm-gemma4-audio:latest` |

Apply a deployment:

```bash
kubectl apply -f deploy-gemma4.yaml
kubectl rollout restart deployment/gemma4
```

The `ghcr-pull` secret must exist in the cluster to pull from GHCR.
