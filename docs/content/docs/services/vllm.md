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
| **DeepSeek-V4-Flash-DSpark** | nimbus2 + nimbus4 (**2× GB10, TP2**) | `deepseek-v4-flash` | `deepseek-v4-flash-gb10pair.yaml`. **~70 tok/s** single stream, 350K context |
| Laguna S 2.1 NVFP4 | nimbus3 (1× GB10) | `laguna` | `laguna-nimbus3.yaml`, **scaled to 0** since 2026-09-24 — loops on agentic traffic, see [below](#laguna-on-nimbus3). ~23–32 tok/s, 256K context |
| Qwen3.8-Flash-Next NVFP4 | nimbus (1× GB10) | `qwen`, `qwen3.8` | `qwen38-flashnext-nimbus.yaml`. ~24 tok/s single stream, 256K context |
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
| `https://vllm-nimbus2.carlboettiger.info` | nimbus2 (+nimbus4) | the TP2 pair's API server |
| `https://vllm-nimbus3.carlboettiger.info` | nimbus3 | nothing since Laguna was scaled to 0 (503) |
| `https://whisper-cirrus.carlboettiger.info` | cirrus | speech-to-text, several models at once |
| `https://vllm-cirrus.carlboettiger.info` | cirrus | nothing — kept for the rollback |

`services/vllm/endpoints.yaml` holds these — Services, Ingresses and the Traefik
transport. Each model is a Deployment beside it carrying the pod label
`vllm-endpoint: <node>` (`cirrus`, `nimbus`, `nimbus3`), which the matching Service
selects. The exceptions carry their own Service and Ingress:
`deepseek-v4-flash-gb10pair.yaml` (`vllm-nimbus2`) and `stt-cirrus.yaml` (`whisper-cirrus`). Switching
models is scaling one down and the next up: no new Ingress, DNS record or certificate.

The speech-to-text endpoint is the exception: it routes on the request's `model` field
inside one process rather than on a label selector, and holds several models at once.
See [One endpoint, several models](#one-endpoint-several-models).

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

**Not Ray.** This pair uses vLLM's native multi-node path —
`--distributed-executor-backend mp` with `--nnodes 2 --node-rank ${NODE_RANK}
--master-addr/--master-port`. An earlier Ray-based attempt produced
`collective_rpc should not be called on follower node`, which we wrongly read as "B12X
multi-node is broken"; it was a Ray-path artifact. Dropping Ray also cut startup from
30–80 minutes of FlashInfer autotune to about six minutes end to end.

#### Restarting the pair

**Start order is load-bearing**, and `kubectl apply` alone will not give it to you — an
apply rolls *both* Deployments into new ReplicaSets simultaneously, which silently undoes
any ordering. Scale *after* applying:

```bash
kubectl -n vllm scale deploy/deepseek-v4-flash-head   --replicas=0
kubectl -n vllm scale deploy/deepseek-v4-flash-worker --replicas=0   # wait: both gone
kubectl -n vllm scale deploy/deepseek-v4-flash-worker --replicas=1   # wait: rank=1 in its log
kubectl -n vllm scale deploy/deepseek-v4-flash-head   --replicas=1
```

The ranks meet in a torch distributed store and a rank arriving alone waits there.

**A healthy TP2 start drops BOTH nodes to single-digit GiB free** — each takes its
~79 GiB shard. If one node stays near 90 GiB free, that rank never loaded, and the pair
will sit there with no error at all: both pods `Running`, the head `0/1`, GPU 0% on both,
logs stopping dead. Three distinct bugs produced exactly that signature, so check the
*worker* log first:

- a hardcoded `--node-rank` gave both pods rank 0 (use `${NODE_RANK}` from the env);
- the worker's `--headless` sat after a line with **no trailing backslash**, so the
  continued command ended early, `exec` replaced the shell and the flag never reached
  vLLM — the worker then ran as a second non-headless head. Tell-tale: an
  `(APIServer pid=1)` prefix in the *worker's* log;
- a `#` comment *inside* a backslash-continued command splices in and truncates the rest.

None of these raises an error. Verify the rendered `args`, not just that a flag appears
somewhere in the file.

Because this endpoint lives in the `vllm` namespace with the usual
`prometheus.io/scrape` annotations, it is visible to the carbon dashboard — but note
that dashboard currently assumes **one card per node**, and a TP2 model spans two.
Its tokens are reported by one endpoint while its power is split across two nodes, so
the per-token figure for this pair is not yet right.

### Laguna on nimbus3

`laguna-nimbus3.yaml`, served at `https://vllm-nimbus3.carlboettiger.info` as `laguna`,
256K context, with **tool calling and reasoning both working**.

> **Scaled to 0 on 2026-09-24 — not fit for agentic traffic.** Under real agent load it
> enters non-terminating reasoning loops: 31 aborted requests against zero on
> `deepseek-v4-flash` and `qwen3.8-flashnext`. The cause is upstream and unresolved
> (issue #95). The manifest is kept correct and measured; this is a fitness decision,
> not a broken config. poolside's RC2 mitigation de-quantizes 8 layers' experts back to
> bf16 (92.9 GiB), which leaves one GB10 only ~115K KV tokens — so reviving Laguna *with*
> the fix means TP2 on the nimbus2+nimbus4 pair, not nimbus3.

**Use the `ennerd` checkpoint, not `poolside`.** poolside's official NVFP4 leaves 8 of 48
layers' experts in bf16, so it is 93 GiB and leaves only ~4 GiB of KV — a 16K ceiling,
and it fails to load at all at 32K. `ennerd/Laguna-S-2.1-NVFP4` packs all 48 layers and
quantizes attention too: 65 GB, and 30 GiB of KV. It is explicitly built for this
hardware (tagged `dgx-spark`, `gb10`, `blackwell`). Measured on nimbus3, same box:

| | poolside | ennerd |
|---|---|---|
| single stream | 17.7 tok/s | **32.4 tok/s** |
| aggregate @ c8 | 60.2 tok/s | **120.4 tok/s** |
| max context | ~16K | **262,144** |
| KV cache | ~4 GiB | **30 GiB / 1.1M tokens** |

Two flags are non-obvious, and **both failed silently** rather than erroring:

- `--tool-call-parser poolside_v1`. Laguna's format is GLM-style
  (`<tool_call>NAME<arg_key>k</arg_key><arg_value>v</arg_value></tool_call>`), not
  Qwen/Hermes. The real template is `chat_template.jinja`; the `chat_template` field in
  `tokenizer_config.json` is a 35-character stub, and reading that instead is how this
  was first wrongly written off as having no tool support.
- `--default-chat-template-kwargs '{"enable_thinking":true}'` is **required** for
  reasoning to be separated. `DeepSeekV3ReasoningParser` picks its implementation from
  the chat-template kwargs, which default to `false`, so without this it installs a
  pass-through `IdentityReasoningParser`, reports success, and the whole chain-of-thought
  lands in `content`. `--reasoning-config` silences the related warning but fixes nothing
  on its own.

**Client note:** reasoning arrives in `message.reasoning`, **not** `reasoning_content`.
A client reading `reasoning_content` gets an empty string and will conclude the parser is
broken.

**Restarting it at `--gpu-memory-utilization 0.85` needs a cache drop first.** vLLM's
startup assertion compares `MemFree` against the requested budget before allocating, so
page cache left by the previous pod makes a restart crash-loop
(`Free memory on device ... is less than desired GPU memory utilization`). There is no env
var that skips it — `VLLM_SKIP_INIT_MEMORY_CHECK` is a no-op. Run
`drop-caches-nimbus.yaml` (edit its `kubernetes.io/hostname` to `nimbus3`) before scaling back to 1. The watchdog fix
described [below](#the-nodes-are-not-equivalent) is what made 0.85 safe again after the
interim 0.80.

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
  both, and measure the result.
- **Do NOT guard on `MemAvailable` alone.** On these nodes `cudaMemGetInfo` free equals
  **`MemFree`** exactly, and `MemAvailable` runs roughly **7 GiB below `MemFree`** — so a
  `MemAvailable` floor fires while CUDA still has GiBs to give. On 2026-09-21 that killed
  a healthy Laguna mid-serve at 36.8 tok/s with `MemFree` at 7.7–8.2 GiB and
  `direct_reclaim` at 0. The inverse also happens: just after loading a large checkpoint,
  `MemFree` can sit at 5.7 GiB with 40 GiB of reclaimable page cache, and there
  `MemAvailable` is the honest number. **No single metric is trustworthy.** The distress
  predicate is `MemFree` low **and** `Cached` low — nothing free *and* nothing to
  reclaim. `cluster/nodes/nimbus/gpu-hang-watchdog.sh` now applies this to both its
  thresholds.
- **The pool is ~121.6 GiB, not 128 GB.** Of the 127.6 GiB physical, **6.10 GiB** is
  firmware/ACPI reservation (measured identical on the NVIDIA and Dell units), leaving
  `MemTotal` 121.63 GiB. Kubernetes itself is under 2 GiB. Earlier notes here claimed
  ~18 GiB of "driver carveout" — that was wrong: the rest of any apparent shortfall is
  page cache, which is reclaimable. Budget from a measured figure, never the nominal
  128 GB.
- `nvidia.com/gpu: 8` is 8 time-slices of one GPU sharing one pool, so the count is a
  concurrency cap, not a memory partition.

The GB10s are also **arm64** and tainted `dedicated=gb10:NoSchedule`, so their manifests
use arm64 vLLM images and carry the toleration. See
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

### One endpoint, several models

This is the one place in the cluster where model routing does **not** happen in
Kubernetes, so it is worth understanding before extending it.

**speaches is a multi-model engine; vLLM and SGLang are not.** A vLLM process builds its
engine around one checkpoint at startup and pins the card for its lifetime, so serving
several models *requires* several processes — several Deployments, several GPU claims,
and a model-aware proxy such as LiteLLM in front. That is the correct shape for vLLM, and
close to what the LLM endpoints here do, except that routing is by hostname (one model
scaled up per node) instead of a proxy. **There is no LiteLLM in this cluster.**

speaches works the other way round: it calls itself "Ollama, but for TTS/STT", and
holding several models with lazy loading and idle unloading is its native mode rather
than something built around it. So the speech-to-text endpoint has no router and no
fleet behind it — it is a single ordinary Deployment:

```
Ingress ─→ Service ─→ Deployment `stt` (1 replica) ─→ 1 pod ─→ 1 container (speaches)
```

Exactly the object count of the whisper-only Deployment it replaced. Going from one
model to three added no Kubernetes resources, because the multiplexing is inside the
process: the model id is a form field on the request, and the server dispatches on it.
Nothing in the cluster is model-aware; Traefik just forwards to the one Service.

```
POST /v1/audio/transcriptions   model=istupakov/parakeet-tdt-0.6b-v3-onnx
  │
  ├─ read that id's Hugging Face model card from the local cache
  ├─ pick the executor whose filter the card passes
  │     whisper   ← Systran/faster-whisper*,  task=automatic-speech-recognition
  │     parakeet  ← istupakov/parakeet-tdt*,  task=automatic-speech-recognition
  ├─ Silero VAD runs first, always, whichever executor won
  └─ executor.model_manager.handle_transcription_request(...)
```

The pieces:

- **One `Executor` per model family**, each a `(name, model_manager, model_registry,
  task)` tuple. Transcription is `(whisper, parakeet)`; text-to-speech, VAD, diarization
  and speaker embedding are sibling tuples on the same registry. A new family is a new
  `Executor`, not a change to the router.
- **Dispatch on model-card metadata rather than a hardcoded list.** Each executor owns a
  filter — a repo-name prefix plus a Hugging Face task tag — and the router asks which
  filter the requested id passes. The same filters let
  `GET /v1/registry?task=automatic-speech-recognition` enumerate roughly 590 fetchable
  models straight from the Hub.
- **A shared handler protocol**, so the router never learns that whisper runs on
  CTranslate2 and parakeet on ONNX Runtime. Both runtimes live in a single process and
  share one `nvidia.com/gpu: 1` claim — about 7.4 GB of a 48 GB card with models
  resident.
- **Refcounted lazy loading.** Each model is a self-disposing object: the first request
  loads the weights and takes a reference, the last one to finish arms an idle timer,
  and the next request cancels it. `STT_MODEL_TTL` (3600 s here) is that timer; `0`
  unloads after every request, `-1` never unloads.

**The trade-off.** No extra Deployment, Service, Ingress, DNS record or certificate per
model and no proxy to operate, switching is a changed form field instead of two
`kubectl scale`s, and several models stay warm at once — which suits ASR, where checkpoints are 2–3 GB rather than an LLM's whole card.
What you give up:

- **No isolation.** One process, one cgroup, one GPU claim, one VRAM pool. A crash in
  one model family takes the rest with it, and there are no per-model limits or metrics.
- **Capabilities are the union, not the intersection.** `srt` works on whisper and
  returns a 500 on parakeet; streaming is whisper-only; the ~6 minute ceiling applies to
  one of the two. `GET /v1/models` does not express any of that, so the caller has to
  know what it picked — hence the table below.
- **Cold start is request latency, not deploy latency** — 8.2 s for the first request
  after a restart here, against 0.7 s warm. `STT_MODEL_TTL` trades held VRAM against
  paying that again.

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

The `services/vllm/` directory contains the manifests for every endpoint.

### Quick Start

```bash
cd services/vllm

# Create the namespace + secrets (HF token, API key) and deploy a model
./up.sh

# Or apply a single manifest directly
kubectl apply -f stt-cirrus.yaml                 # cirrus: speech-to-text
kubectl apply -f qwen38-flashnext-nimbus.yaml    # nimbus: an LLM
kubectl apply -f deepseek-v4-flash-gb10pair.yaml # nimbus2+4: TP2 -- see "Restarting the pair"

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
- `deepseek-v4-flash-gb10pair.yaml` - the TP2 pair: head + worker Deployments, with their own Service and Ingress
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
