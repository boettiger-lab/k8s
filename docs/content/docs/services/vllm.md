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

## Models we have running

**This is a catalogue of what we have working, not a fixed fleet.** What is actually
up at any moment varies — models are scaled up and down as needed, and a node serves
one model at a time. Ask the endpoint what it is serving rather than assuming:

```bash
curl -s -H "Authorization: Bearer $VLLM_API_KEY" \
  https://vllm-nimbus.carlboettiger.info/v1/models | jq '.data[].id'
```

### Working, with a manifest

| Model | Where it runs | Served as | Manifest / notes |
|---|---|---|---|
| Qwen3.8-Flash-Next NVFP4 | nimbus (1× GB10) | `qwen`, `qwen3.8` | `qwen38-flashnext-nimbus.yaml`. ~20–22 tok/s single stream |
| DeepSeek-V4-Flash | nimbus2 + nimbus4 (**2× GB10, TP2**) | `deepseek-v4-flash` | `deepseek-v4-flash-gb10pair.yaml`. ~23 tok/s single stream with MTP |
| Qwen3.8-27B AWQ INT4, MTP | cirrus (2× Quadro RTX 8000) | `qwen3-8` | `qwen3-8-cirrus.yaml`, **scaled to 0** since cirrus became an ASR node |
| Gemma 4 | cirrus | — | `gemma4-cirrus.yaml`, normally scaled to 0 |

**cirrus serves speech-to-text now, not an LLM.** Since 2026-09-21 the two Quadro
RTX 8000s — Turing cards that the GB10s comfortably beat at LLM inference, but that are
very good at speech recognition — run the ASR server described in
[Speech-to-text](#speech-to-text-on-cirrus) instead. `vllm-cirrus.carlboettiger.info`
has no backend and returns 503; its Service, Ingress and certificate are kept so
scaling `qwen3-8` back to 1 restores it.

### Endpoints are named for machines, not models

| Endpoint | Node | Serving |
|---|---|---|
| `https://vllm-nimbus.carlboettiger.info` | nimbus | one LLM at a time |
| `https://whisper-cirrus.carlboettiger.info` | cirrus | speech-to-text, several models at once |
| `https://vllm-cirrus.carlboettiger.info` | cirrus | nothing — kept for the rollback |

`services/vllm/endpoints.yaml` holds these — Services, Ingresses and the Traefik
transport. Each model is a Deployment beside it carrying the pod label
`vllm-endpoint: cirrus` (or `nimbus`), which the matching Service selects. Switching
models is scaling one down and the next up: no new Ingress, DNS record or certificate.

### Multi-node (TP2) endpoints

DeepSeek-V4-Flash runs **tensor-parallel across nimbus2 and nimbus4** over the
direct-attach ConnectX-7 fabric, served at `https://vllm-nimbus2.carlboettiger.info`
(the hostname names the node running the API server, as elsewhere).

`deepseek-v4-flash-gb10pair.yaml` carries the Service, the Ingress and **two**
Deployments. It is two rather than one with `replicas: 2` because TP ranks are not
interchangeable: rank 0 runs the API server, rank 1 is `--headless`, and each needs a
fixed `--node-rank` pinned to a fixed node. Only the head carries
`vllm-endpoint: nimbus2`, so the Service never selects the worker.

The fabric must be up before either pod starts — NCCL *and* Gloo are pinned to
`enp1s0f1np1` in the manifest. See the cluster-ops notes on the CX-7 fabric.

Because this endpoint lives in the `vllm` namespace with the usual
`prometheus.io/scrape` annotations, it is visible to the carbon dashboard — but note
that dashboard currently assumes **one card per node**, and a TP2 model spans two.
Its tokens are reported by one endpoint while its power is split across two nodes, so
the per-token figure for this pair is not yet right.

### The nodes are not equivalent

**cirrus** has two discrete Quadro RTX 8000s (48 GB each, Turing), time-sliced 8 ways —
a slice is a co-tenancy slot, not a memory partition, and each pod sees a whole card.

**nimbus, nimbus2, nimbus3, nimbus4** are DGX Sparks: one GB10 each with **unified
memory**, so CPU and GPU share a single ~122 GiB pool. Consequences worth internalising
before deploying there:

- A pod's `memory:` limit does **not** bound CUDA allocations — the cgroup controller
  cannot see them. It is scheduler accounting, and it must reflect real unified-memory
  use or the scheduler will co-schedule something that OOMs the host.
- **No memory flag is reliable across models.** Which of `--gpu-memory-utilization` and
  `--kv-cache-memory` actually binds is a property of the *(model, build)* pair and must
  be measured from a real load every time. When `--kv-cache-memory` is honoured it
  *replaces* the memory profiler (vLLM says so on startup) — but it does **not** replace
  `--gpu-memory-utilization`, which still governs a startup free-memory assertion. Set
  both, and keep a `MemAvailable`-based guard: it is the only signal not fooled by
  reclaimable page cache.
- **~18 GiB of the ~122 GiB pool is unavailable before anything starts**, and it is not
  Kubernetes — the whole k8s layer measures under 1 GiB RSS. It is driver carveout.
  Budget from a measured `MemAvailable`, never from the nominal 128 GB.
- `nvidia.com/gpu: 8` is 8 time-slices of one GPU sharing one pool, so the count is a
  concurrency cap, not a memory partition.

The GB10s are also **arm64** and tainted `dedicated=gb10:NoSchedule`, so its manifest uses
NGC's arm64 vLLM image and carries the toleration. See
[Node placement]({{< relref "../infrastructure/node-placement" >}}).

## Speech-to-text on cirrus

`services/vllm/stt-cirrus.yaml` runs [speaches](https://speaches.ai/), an
OpenAI-compatible `/v1/audio/transcriptions` server, at
`https://whisper-cirrus.carlboettiger.info`. It replaced the LLM on cirrus on
2026-09-21.

It works differently from the vLLM endpoints: **one server holds several models and the
model is a per-request argument.** speaches loads a model on first use and unloads it
after an hour idle, so there is no "current model" to scale between.

```bash
export VLLM_API_KEY=$(kubectl get secret vllm-api-key -n vllm -o jsonpath='{.data.api-key}' | base64 -d)

curl -s https://whisper-cirrus.carlboettiger.info/v1/audio/transcriptions \
  -H "Authorization: Bearer $VLLM_API_KEY" \
  -F file=@recording.wav \
  -F model=istupakov/parakeet-tdt-0.6b-v3-onnx \
  -F response_format=text
```

Any OpenAI SDK works against it:

```python
from openai import OpenAI

client = OpenAI(base_url="https://whisper-cirrus.carlboettiger.info/v1",
                api_key=os.environ["VLLM_API_KEY"])

with open("recording.wav", "rb") as f:
    print(client.audio.transcriptions.create(
        model="istupakov/parakeet-tdt-0.6b-v3-onnx", file=f).text)
```

### Which model to ask for

| Model | Use it for | Avoid it for |
|---|---|---|
| `istupakov/parakeet-tdt-0.6b-v3-onnx` | the default — English and 25 European languages, ~85× real time | audio over ~6 minutes, subtitles, streaming |
| `Systran/faster-whisper-large-v3` | long recordings, the other 74 languages, translation, word timestamps, SRT/VTT, streaming | nothing; it is the safe fallback |
| `istupakov/parakeet-tdt-0.6b-v2-onnx` | English-only work where accuracy matters most | anything non-English |

`GET /v1/models` lists what is loaded locally;
`GET /v1/registry?task=automatic-speech-recognition` lists everything speaches could
fetch, and `POST /v1/models/{id}` fetches one.

### How the models compare, measured on cirrus

150 random LibriSpeech **test-other** utterances (2,805 reference words), scored with a
light normaliser — comparable to each other, not to published leaderboard figures:

| Model | WER | Languages |
|---|---:|---|
| `parakeet-tdt-0.6b-v2` | **2.89 %** | English |
| `parakeet-tdt-0.6b-v3` | **3.17 %** | 25 |
| `faster-whisper-large-v3` | 4.14 % | 99 |
| `faster-whisper-large-v3-turbo` | 4.74 % | 99 |

Throughput on 12.7 minutes of speech in one request: parakeet-v3 ~85× real time,
whisper-large-v3-turbo ~75×, whisper-large-v3 ~45×. Warm latency on an 11 s clip is
about 0.7 s either way, so for short audio the choice is accuracy, not speed.

Parakeet does **not** win everywhere. On 20 short German, Spanish, French, Italian and
Dutch sentences, whisper-large-v3 scored 3.8 % against parakeet-v3's 8.7 %. That is a
small sample of isolated sentences, so read it as a direction: parakeet for English,
whisper for everything else.

### Limits to know about

- **Parakeet fails hard at roughly 6 minutes.** The ONNX encoder has a 4558-frame cap
  baked into its relative-position attention — about 365 s of speech once silence is
  trimmed — and beyond it the request returns a 500, not a shorter transcript. Nothing
  chunks around it yet. Split long audio client-side or use whisper.
- **Parakeet only returns `text` and `json`.** `srt`, `vtt` and `verbose_json` return a
  500; streaming is unimplemented. Subtitles and timestamps mean whisper.
- The image is pinned to `speaches:0.9.0-rc.3-cuda-12.6.3`. `latest-cuda` is still
  0.8.3, which has no parakeet support at all.
- speaches' own model-download endpoint silently omits the ONNX external-weights file
  for parakeet models, so an init container fetches the snapshot directly instead. See
  the comments in `stt-cirrus.yaml`.

## Prerequisites

1. [K3s installed]({{< relref "../infrastructure/k3s" >}})
2. [NVIDIA GPU support configured]({{< relref "../infrastructure/nvidia" >}})
3. Sufficient GPU memory for your chosen model

## Deployment

The `services/vllm/` directory contains the manifests for both endpoints.

### Quick Start

```bash
cd services/vllm

# Create the namespace + secrets (HF token, API key) and deploy a model
./up.sh

# Or apply a single manifest directly
kubectl apply -f stt-cirrus.yaml                 # cirrus: speech-to-text
kubectl apply -f qwen38-flashnext-nimbus.yaml    # nimbus: an LLM

# Check status
kubectl get pods -n vllm

# View logs (use the deployment name, e.g. stt or qwen38-flashnext)
kubectl logs -n vllm deployment/stt -f

# List the model endpoints
kubectl get ingress -n vllm
```

### Configuration Files

Under `services/vllm/`:

- `endpoints.yaml` - the Services, Ingresses, certs and Traefik transport for the LLM endpoints
- `stt-cirrus.yaml` - the speech-to-text server on cirrus, with its own Service and Ingress
- `<model>-<node>.yaml` - an LLM Deployment only, labelled `vllm-endpoint: <node>`
- `secrets.sh` - creates the `vllm-huggingface-token` and `vllm-api-key` secrets (git-ignored)
- `up.sh` / `down.sh` - deploy / cleanup scripts

### Deployment Configuration

Each model manifest:
- Requests GPU slice(s) and pins to a specific node with `nodeSelector`
- Mounts the shared Hugging Face cache from the host (`/home/cboettig/.cache/huggingface`)
- Reads the HF token and API key from Kubernetes secrets
- Exposes the OpenAI-compatible API on port 8000
- Uses `strategy.type: Recreate` so a redeploy frees the GPUs before the new pod starts

See `services/vllm/qwen3-8-cirrus.yaml` for the full reference. Key arguments:

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
curl https://vllm-nimbus.carlboettiger.info/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $VLLM_API_KEY" \
  -d '{
    "model": "qwen3.8",
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
    base_url="https://vllm-nimbus.carlboettiger.info/v1",
    api_key=os.environ["VLLM_API_KEY"],
)

response = client.chat.completions.create(
    model="qwen3.8",
    messages=[{"role": "user", "content": "What is the capital of France?"}],
    max_tokens=100,
)

print(response.choices[0].message.content)
```

> The Qwen3.8 models are reasoning models: in streamed responses the chain-of-thought
> arrives in `delta.reasoning` and the final answer in `delta.content`.

### Streaming Responses

```python
response = client.chat.completions.create(
    model="qwen3.8",
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
curl https://vllm-nimbus.carlboettiger.info/metrics
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
