---
title: "vLLM"
weight: 4
bookToc: true
---

# vLLM

Deploy vLLM for high-throughput LLM inference with GPU acceleration.

## Overview

[vLLM](https://github.com/vllm-project/vllm) is a fast and easy-to-use library for LLM inference and serving. It features:
- State-of-the-art serving throughput
- Efficient memory management with PagedAttention
- Continuous batching of requests
- Optimized CUDA kernels
- Support for popular models (Llama, Mistral, GPT, etc.)

## Live deployments

cirrus serves **one** LLM at a time, always at the same address:

> **`https://vllm-cirrus.carlboettiger.info`**

The URL names the machine, not the model — mirroring
`vllm-nimbus.carlboettiger.info`. Ask the endpoint which model is loaded rather
than encoding it in a hostname:

```bash
curl -s -H "Authorization: Bearer $VLLM_API_KEY" \
  https://vllm-cirrus.carlboettiger.info/v1/models | jq '.data[].id'
```

The `vllm/cirrus/` directory holds one manifest per model, plus `endpoint.yaml`
with the shared Service, Ingress, and certificate. Every model Deployment
carries the pod label `vllm-endpoint: cirrus`, which the shared Service selects
— so switching models is just scaling one down and the next up. No new Ingress,
DNS record, or certificate is involved.

| Model | `model` name | Manifest | State |
|-------|--------------|----------|-------|
| Qwen3.8-27B (AWQ INT4, MTP) | `qwen3-8` | `deploy-qwen3-8.yaml` | **live** |
| Gemma 4 | `gemma4` | `deploy-gemma4.yaml` | scaled to 0 |

Whisper (audio transcription) is a separate, non-vLLM server on its own host,
`whisper-cirrus.carlboettiger.info` (`deploy-whisper.yaml`); it is not part of
the single-LLM slot and can run alongside it.

All endpoints are OpenAI-compatible and **require an API key** (see
[Authentication](#authentication)). They run on the time-sliced GPUs of the
`cirrus` node (Quadro RTX 8000, Turing).

## Prerequisites

1. [K3s installed]({{< relref "../infrastructure/k3s" >}})
2. [NVIDIA GPU support configured]({{< relref "../infrastructure/nvidia" >}})
3. Sufficient GPU memory for your chosen model

## Deployment

The `vllm/` directory contains Kubernetes manifests for deploying vLLM.

### Quick Start

```bash
cd vllm/cirrus

# Create the namespace + secrets (HF token, API key) and deploy a model
./up.sh

# Or apply a single model manifest directly
kubectl apply -f deploy-qwen3-8.yaml

# Check status
kubectl get pods -n vllm

# View logs (use the deployment name for the model, e.g. qwen3-8)
kubectl logs -n vllm deployment/qwen3-8 -f

# List the model endpoints
kubectl get ingress -n vllm
```

### Configuration Files

Under `vllm/cirrus/`:

- `endpoint.yaml` - the shared Service, Ingress, and cert for `vllm-cirrus.carlboettiger.info`
- `deploy-<model>.yaml` - a Deployment only, labelled `vllm-endpoint: cirrus` (e.g. `deploy-qwen3-8.yaml`)
- `secrets.sh` - creates the `vllm-huggingface-token` and `vllm-api-key` secrets
- `up.sh` / `down.sh` - deploy / cleanup scripts

### Deployment Configuration

Each model manifest:
- Requests GPU(s) and pins to the `cirrus` node
- Mounts the shared Hugging Face cache from the host (`/home/cboettig/.cache/huggingface`)
- Reads the HF token and API key from Kubernetes secrets
- Exposes the OpenAI-compatible API on port 8000
- Uses `strategy.type: Recreate` so a redeploy frees the GPUs before the new pod starts

See `vllm/cirrus/deploy-qwen3-8.yaml` for the full reference. Key arguments:

```yaml
args:
  - --model
  - shawnw3i/Qwen3.8-27B-AWQ-MTP
  - --served-model-name
  - qwen3-8
  - --max-model-len
  - "131072"
  - --enable-auto-tool-choice
  - --tool-call-parser
  - qwen3_coder          # qwen3_xml is an alias for the same engine parser
  - --reasoning-parser
  - qwen3
  # cirrus is a Quadro RTX 8000 (Turing, cc 7.5). The default FlashInfer
  # backend crashes in its prefill kernel for this model's head_dim 256, and
  # FLASH_ATTN needs compute capability >= 8, so pin Triton. NOTE: the
  # VLLM_ATTENTION_BACKEND env var was removed in vLLM 0.23.0 - use this flag.
  - --attention-backend
  - TRITON_ATTN
  # Hybrid GDN model: recurrent state is ~150MB/sequence, and CUDA graph
  # capture needs max_num_seqs <= available Mamba cache blocks.
  - --max-num-seqs
  - "16"
  # The checkpoint ships mtp.* weights, so speculative decoding works here.
  - --speculative-config
  - '{"method":"mtp","num_speculative_tokens":3}'
```

## Authentication

Every endpoint requires a bearer token. The key is stored in the `vllm-api-key`
secret (key `api-key`) in the `vllm` namespace and injected into the pod as
`VLLM_API_KEY`. Retrieve it with:

```bash
kubectl get secret vllm-api-key -n vllm -o jsonpath='{.data.api-key}' | base64 -d
```

Pass it as `Authorization: Bearer <key>` (curl) or `api_key=...` (OpenAI client).
Avoid hard-coding it — read it from an environment variable, e.g.
`export VLLM_API_KEY=$(kubectl get secret vllm-api-key -n vllm -o jsonpath='{.data.api-key}' | base64 -d)`.

## Usage

### API Examples

Using curl:

```bash
curl https://vllm-cirrus.carlboettiger.info/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $VLLM_API_KEY" \
  -d '{
    "model": "qwen3-8",
    "messages": [{"role": "user", "content": "San Francisco is a"}],
    "max_tokens": 50,
    "temperature": 0.7
  }'
```

Using Python with the OpenAI client:

```python
import os
from openai import OpenAI

client = OpenAI(
    base_url="https://vllm-cirrus.carlboettiger.info/v1",
    api_key=os.environ["VLLM_API_KEY"],
)

response = client.chat.completions.create(
    model="qwen3-8",
    messages=[{"role": "user", "content": "What is the capital of France?"}],
    max_tokens=100,
)

print(response.choices[0].message.content)
```

> `qwen3-8` is a reasoning model: in streamed responses the chain-of-thought
> arrives in `delta.reasoning` and the final answer in `delta.content`.

### Streaming Responses

```python
response = client.chat.completions.create(
    model="qwen3-8",
    messages=[{"role": "user", "content": "Tell me a story"}],
    max_tokens=200,
    stream=True,
)

for chunk in response:
    if not chunk.choices:
        continue
    delta = chunk.choices[0].delta
    text = delta.content or getattr(delta, "reasoning", None)
    if text:
        print(text, end="")
```

## Configuration

### Change Model

Copy an existing `deploy-<model>.yaml` and edit its `--model` / `--served-model-name`
(and host in the Ingress) to serve a different model:

```yaml
args:
  - --model
  - mistralai/Mistral-7B-Instruct-v0.2  # Change this
  - --dtype
  - float16
```

Popular models:
- `meta-llama/Llama-2-7b-chat-hf`
- `meta-llama/Llama-2-13b-chat-hf`
- `mistralai/Mistral-7B-Instruct-v0.2`
- `tiiuae/falcon-7b-instruct`

**Note**: Ensure your GPU has sufficient memory for the model.

### Persistent Model Cache

Use a PersistentVolumeClaim to cache models:

```yaml
volumes:
- name: cache
  persistentVolumeClaim:
    claimName: vllm-cache
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: vllm-cache
  namespace: vllm
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: openebs-zfs
  resources:
    requests:
      storage: 50Gi
```

### Quantization

Use quantization for larger models:

```yaml
args:
  - --model
  - meta-llama/Llama-2-13b-chat-hf
  - --quantization
  - awq  # or 'gptq', 'squeezellm'
  - --dtype
  - float16
```

### Tensor Parallelism

For multi-GPU setups:

```yaml
args:
  - --model
  - meta-llama/Llama-2-70b-chat-hf
  - --tensor-parallel-size
  - "4"
resources:
  limits:
    nvidia.com/gpu: 4
```

## Monitoring

### Check Logs

```bash
kubectl logs -n vllm deployment/qwen3-8 -f
```

### GPU Usage

```bash
# On the host
nvidia-smi

# Or from the pod
kubectl exec -n vllm deployment/qwen3-8 -- nvidia-smi
```

### Metrics

vLLM exposes metrics at `/metrics`:

```bash
curl https://vllm-cirrus.carlboettiger.info/metrics
```

## Troubleshooting

### Pod Not Starting

```bash
# Check pod status
kubectl describe pod -n vllm <pod-name>

# Common issues:
# - GPU not available
# - Insufficient GPU memory
# - Model download failure
```

### Out of Memory

1. **Use smaller model**: Switch to 7B instead of 13B
2. **Enable quantization**: Use AWQ or GPTQ
3. **Adjust max tokens**: Limit `max_model_len`

```yaml
args:
  - --model
  - meta-llama/Llama-2-7b-chat-hf
  - --max-model-len
  - "2048"
```

### Model Download Issues

1. **Check internet connectivity**:
```bash
kubectl exec -n vllm deployment/qwen3-8 -- ping huggingface.co
```

2. **Use Hugging Face token** for gated models:
```yaml
env:
- name: HF_TOKEN
  valueFrom:
    secretKeyRef:
      name: hf-token
      key: token
```

3. **Pre-download models**: Download models to persistent volume first

### API Not Responding

1. **Check service**:
```bash
kubectl get svc -n vllm
kubectl describe svc vllm-service -n vllm
```

2. **Check ingress**:
```bash
kubectl get ingress -n vllm
kubectl describe ingress vllm-ingress -n vllm
```

3. **Test internally**:
```bash
kubectl run -it --rm test --image=curlimages/curl --restart=Never -- \
  curl http://vllm-service.vllm.svc.cluster.local:8000/health
```

## Advanced Configuration

### Enable Authentication

Add API key authentication:

```yaml
args:
  - --model
  - meta-llama/Llama-2-7b-chat-hf
  - --api-key
  - $(API_KEY)
env:
- name: API_KEY
  valueFrom:
    secretKeyRef:
      name: vllm-secret
      key: api-key
```

### Custom Ingress Rules

Restrict access by IP:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: vllm-ingress
  annotations:
    traefik.ingress.kubernetes.io/router.middlewares: default-ipwhitelist@kubernetescrd
```

### Resource Limits

Adjust CPU and memory:

```yaml
resources:
  limits:
    nvidia.com/gpu: 1
    memory: "16Gi"
    cpu: "4"
  requests:
    nvidia.com/gpu: 1
    memory: "8Gi"
    cpu: "2"
```

## Performance Tuning

### Batch Size

```yaml
args:
  - --max-num-batched-tokens
  - "4096"
  - --max-num-seqs
  - "256"
```

### GPU Memory Utilization

```yaml
args:
  - --gpu-memory-utilization
  - "0.9"  # Use 90% of GPU memory
```

### Speculative Decoding

```yaml
args:
  - --model
  - meta-llama/Llama-2-70b-chat-hf
  - --speculative-model
  - meta-llama/Llama-2-7b-chat-hf
  - --num-speculative-tokens
  - "5"
```

## Cleanup

```bash
cd vllm
./down.sh
```

Or manually:

```bash
kubectl delete namespace vllm
```

## Related Resources

- [vLLM Documentation](https://docs.vllm.ai/)
- [vLLM GitHub](https://github.com/vllm-project/vllm)
- [OpenAI API Reference](https://platform.openai.com/docs/api-reference)
- [NVIDIA GPU Support]({{< relref "../infrastructure/nvidia" >}})
