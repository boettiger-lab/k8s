# vLLM — OpenAI-compatible LLM inference

Each GPU node serves one model at a time, at a fixed URL:

| Endpoint | Node | Currently | Hardware |
|---|---|---|---|
| <https://vllm-nimbus.carlboettiger.info> | nimbus | `qwen`/`qwen3.8` — Qwen3.8-**Flash-Next** NVFP4 | DGX Spark GB10, 128 GB unified |
| <https://whisper-cirrus.carlboettiger.info> | cirrus | **speech-to-text**, several models | 2× Quadro RTX 8000 (48 GB each) |
| <https://vllm-cirrus.carlboettiger.info> | cirrus | *nothing* — see below | — |

**cirrus is an ASR node now (2026-09-21).** Turing cards are not competitive with the
GB10s for LLM inference, but they are excellent at speech recognition, so `qwen3-8` was
scaled to 0 and cirrus was given over to speech-to-text — see
[Speech-to-text on cirrus](#speech-to-text-on-cirrus). `vllm-cirrus.carlboettiger.info`
therefore has no backend and returns 503; the Service, Ingress and certificate are kept
so that scaling `qwen3-8` back to 1 restores it with no DNS or cert churn. Send LLM
traffic to `vllm-nimbus`.

All endpoints are OpenAI-compatible and require an API key:

```bash
API_KEY=$(kubectl get secret vllm-api-key -n vllm -o jsonpath='{.data.api-key}' | base64 -d)
curl -s https://vllm-nimbus.carlboettiger.info/v1/models -H "Authorization: Bearer $API_KEY"
```

## Layout

| File | What |
|---|---|
| `endpoints.yaml` | The Services, Ingresses and Traefik `ServersTransport` — the *stable* half |
| `stt-cirrus.yaml` | **Current cirrus workload**: the speaches speech-to-text server (parakeet + whisper) |
| `qwen3-8-cirrus.yaml`, `gemma4-cirrus.yaml` (google/gemma-4-E2B-it) | LLM Deployments on cirrus, both scaled to 0 since cirrus became an ASR node |
| `qwen38-flashnext-nimbus.yaml` | **Current** nimbus model: Qwen3.8-Flash-Next NVFP4, PLE table mmapped from NVMe |
| `qwen38-nimbus.yaml` | Previous nimbus model: Qwen3.8-27B NVFP4 (scaled to 0; kept as the rollback) |
| `build-flashnext-nimbus.yaml` | Builds the patched Flash-Next image **on nimbus** (hosted arm64 runners lack the disk), then push it to ghcr |
| `drop-caches-nimbus.yaml` | Drops nimbus's page cache before a very large model load |
| `bench-flashnext-nimbus.py` | Prefill/decode + concurrency benchmark, cold vs warm prefix (run inside the pod) |
| `bench-qwen38-nimbus.sh` | Older decode/MTP benchmark for the 27B nimbus model |
| `dgx-spark-memory.md` | The full unified-memory analysis: measurements, KV-cache arithmetic, and why the cgroup limit is not a limit |
| `Dockerfile.gemma4` | `vllm-openai:gemma4` + audio extras (`ghcr.io/boettiger-lab/vllm-gemma4-audio`) |
| `up.sh` / `down.sh` | Apply the endpoints plus one model / remove models but keep the endpoints |
| `secrets.sh` | Creates `vllm-api-key` and the HF token secret. **Git-ignored — holds real credentials** |

## Switching models

The URL belongs to the node, not the model. Every model Deployment carries the pod
label `vllm-endpoint: cirrus` (or `nimbus`), which is what the Service selects, so a
switch is two scales and no ingress/DNS/cert churn:

```bash
kubectl scale -n vllm deployment/qwen3-8 --replicas=0
kubectl scale -n vllm deployment/gemma4  --replicas=1
```

This applies to the LLM endpoints. The speech-to-text server on cirrus works the other
way round — one Deployment, many models, chosen per request — see
[Speech-to-text on cirrus](#speech-to-text-on-cirrus). Scaling an LLM back up on cirrus
means sharing the cards with `stt`, which is fine for a small model (`stt` holds ~7 GB
of a 48 GB card while a model is resident) but not for `qwen3-8`, which asks for 95 %
of both. Scale `stt` to 0 first in that case.

On nimbus the swap back to the 27B model is the same two scales:

```bash
kubectl scale -n vllm deployment/qwen38-flashnext --replicas=0
kubectl scale -n vllm deployment/qwen38          --replicas=1   # rollback
```

Flash-Next claims **all 8** GPU slices, so `mcp-gpu-nimbus` must be scaled to 0
first (`kubectl scale -n default deployment/mcp-gpu-nimbus --replicas=0`) or the
pod stays Pending. Slices are a co-tenancy lock, not a memory partition — mcp-gpu
only holds 178Mi — but with this model needing ~94 GiB of a 121.7 GiB pool,
nothing else should be scheduled against the GPU.

Don't run two models on one node at once — they would split traffic. GPU memory
usually prevents it anyway. Model Deployments use `strategy: Recreate`: a rolling
update deadlocks waiting for GPU the outgoing pod still holds.

## Speech-to-text on cirrus

`stt-cirrus.yaml` runs [speaches](https://speaches.ai/) — an OpenAI-compatible
`/v1/audio/transcriptions` server — behind
<https://whisper-cirrus.carlboettiger.info>. Unlike the vLLM endpoints, **one server
holds several models and the model is a per-request argument**, because speaches loads
a model on first use and unloads it after `STT_MODEL_TTL` (3600 s here) idle. There is
no "current model" to scale between.

```bash
API_KEY=$(kubectl get secret vllm-api-key -n vllm -o jsonpath='{.data.api-key}' | base64 -d)
curl -s https://whisper-cirrus.carlboettiger.info/v1/audio/transcriptions \
  -H "Authorization: Bearer $API_KEY" \
  -F file=@recording.wav \
  -F model=istupakov/parakeet-tdt-0.6b-v3-onnx \
  -F response_format=text
```

`GET /v1/models` lists what is resident; `GET /v1/registry?task=automatic-speech-recognition`
lists the ~590 models speaches could fetch.

### Which model

| Model | Use it for | Don't |
|---|---|---|
| `istupakov/parakeet-tdt-0.6b-v3-onnx` | the default: English, 25 European languages, bulk transcription | audio over ~6 min, `srt`/`vtt`/`verbose_json`, streaming |
| `Systran/faster-whisper-large-v3` | long recordings, the other 74 languages, translation, timestamps, subtitles, streaming | nothing — it is the safe fallback, just slower |
| `istupakov/parakeet-tdt-0.6b-v2-onnx` | English-only work where WER matters most | anything non-English. Not pre-fetched; first use downloads it |

Only the first two are pre-fetched by the init container; any other registry model is
one `POST /v1/models/{id}` away (but see the parakeet download bug below).

### Measured on cirrus, 2026-09-21

150 randomly chosen LibriSpeech **test-other** utterances (2,805 reference words),
scored with a light normaliser (uppercase, strip punctuation, spell out digits), so
these are comparable to each other but not to published leaderboard numbers:

| Model | WER | Notes |
|---|---:|---|
| `parakeet-tdt-0.6b-v2` | **2.89 %** | English only |
| `parakeet-tdt-0.6b-v3` | **3.17 %** | 25 languages |
| `faster-whisper-large-v3` | 4.14 % | 99 languages |
| `faster-whisper-large-v3-turbo` | 4.74 % | fastest whisper |

Long-form throughput, 12.7 min of concatenated LibriSpeech, one request, warm model:

| Model | wall | real-time factor |
|---|---:|---:|
| `parakeet-tdt-0.6b-v3` | 9.0 s | **~85×** |
| `faster-whisper-large-v3-turbo` | 10.2 s | ~75× |
| `faster-whisper-large-v3` | 16.8 s | ~45× |

Warm latency on an 11 s clip is ~0.7 s for either family, over the public endpoint —
so for short clips the choice is accuracy, not speed.

**Parakeet is not uniformly better.** On 20 short de/es/fr/it/nl sentences (Tatoeba,
with reference text) whisper-large-v3 scored 3.8 % against parakeet-v3's 8.7 %. That is
a small sample of single sentences with no surrounding context, so treat it as a
direction rather than a number — but it is enough to say: parakeet wins on English,
whisper is the safer choice everywhere else.

### Things that are easy to get wrong

- **`speaches:latest-cuda` cannot serve parakeet.** That tag is still 0.8.3, which
  predates the `onnx-asr` executor; the container has no `onnx_asr` module and no
  parakeet entries in its registry. The 0.9.0 line exists only as release candidates,
  so the manifest pins `0.9.0-rc.3-cuda-12.6.3`, the newest image published.
- **speaches' own download endpoint produces a broken parakeet.** It derives
  `allow_patterns` from the model's file list and omits `encoder-model.onnx.data` —
  a "successful" download is 110 MB of ONNX graph with 2.4 GB of weights missing
  ([#657](https://github.com/speaches-ai/speaches/issues/657); PR #670 unmerged). The
  init container calls `huggingface_hub.snapshot_download` with explicit patterns
  instead. Don't replace it with `PRELOAD_MODELS`, which goes through the broken path.
- **Parakeet has a hard ~6 minute ceiling, and it fails with a 500.** The ONNX export
  bakes a 4558-frame cap into the encoder's relative-position attention — at 80 ms per
  frame, ~365 s of *speech*. Silero VAD trims silence first, so wall-clock duration is
  not the limit: a 400 s clip passed here and a 480 s one did not. Over the line you get
  `right operand cannot broadcast on dim 3 LeftShape: {1,8,9558,9558}`. speaches
  computes VAD speech segments but the parakeet executor does not yet consume them
  (`TODO: Use request.speech_segments`), so nothing chunks around it. Split long audio
  client-side, or send it to whisper.
- **Parakeet only speaks `text` and `json`.** Ask it for `srt`, `vtt` or
  `verbose_json` and you get a 500, not a 400. Streaming is `NotImplementedError`.
  Subtitles and word timestamps mean whisper.
- **The old `WHISPER__MODEL` / `WHISPER__MODELS_DIR` env vars did nothing.** They were
  never fields in speaches' settings model, so pydantic ignored them — the deployment
  that looked pinned to `faster-whisper-large-v3` was in fact serving whatever each
  request asked for. They are gone.
- **`whisper-cirrus` is a historical name.** The endpoint serves parakeet too. Renaming
  the host would cost a DNS record and a fresh Let's Encrypt issuance, so it stays.

## The two nodes are not interchangeable

**cirrus** — two discrete 48 GB cards, Turing (cc 7.5). Requesting `nvidia.com/gpu: 2`
gets two *distinct* physical GPUs, and cgroup `memory:` is a genuine limit on host RAM,
with VRAM tracked separately. Since 2026-09-21 it runs speech-to-text rather than an
LLM; the notes below are what the LLM deployments here learned, kept because
`qwen3-8-cirrus.yaml` is still the rollback. TP=2 was measured on 2026-08-18 and is a
net loss for a 27B model here; keep TP=1 (the reasoning is in the manifest).

**nimbus** — one GB10 with no discrete VRAM: CPU and GPU share a single ~122 GiB
LPDDR5X pool. Two consequences that repeatedly surprise people:

1. **`memory:` is scheduler accounting, not a limit.** CUDA allocations are invisible
   to the cgroup memory controller (verified: a pod capped at `memory: 32Gi`
   cheerfully reserved 36 GiB of KV cache and kept running). So the request must
   reflect *actual* unified-memory use — weights + KV cache + CPU overhead — or the
   scheduler will co-schedule something that OOMs the host for real.

   **Whether `--gpu-memory-utilization` is a cap depends on the model and the build.**
   On NGC 26.05 (vLLM 0.21) serving Qwen3.8-27B it was advisory: the profiler took all
   free memory regardless (`dgx-spark-memory.md`). On the Flash-Next image (vLLM
   `0.1.dev20073`) it is a genuine cap — it handed out exactly `0.82 × 121.69` and
   stayed inside it. Do not assume either behaviour: set the flag, load once, and read
   the numbers back out of the log before trusting them.

   `--kv-cache-memory` (config field `kv_cache_memory_bytes`) is the absolute cap. Note
   it *replaces* rather than supplements the fraction — vLLM skips profiling entirely
   and logs "This does not respect the gpu_memory_utilization config".
2. **`nvidia.com/gpu: 8` is 8 time-slices of one GPU**, not 8 GPUs, and the slices
   share both compute and the memory pool. A slice is a co-tenancy slot, not a memory
   partition, so claiming slices frees no memory — it is how you tell the scheduler to
   put nothing else on the GPU. Flash-Next claims all 8 for exactly that reason: it
   needs ~94 GiB of the 121.7 GiB pool, so there is no room for a co-tenant even though
   mcp-gpu itself only holds 178Mi. A smaller model should leave slices free instead.
   See [`../../platform/nvidia/`](../../platform/nvidia/).

Images differ too: nimbus is **aarch64**. Most models here run NGC's
`nvcr.io/nvidia/vllm` (pull secret `ngc-pull`), but `vllm/vllm-openai` is **not**
uniformly x86-only as this file used to claim — the `qwen38-flash-next` tag publishes a
`linux/arm64` child in its manifest index, which is what makes Flash-Next possible at
all (NGC 26.05 ships vLLM 0.21, whose registry has no `Qwen4ExpForConditionalGeneration`).
Weights live in a hostPath HF cache (~340 GB) rather than a PVC, because nimbus runs no
storage plugin.

## Qwen3.8-Flash-Next on one Spark

Flash-Next is ~176B parameters (125B main + 51B n-gram, 6B active). The NVFP4
checkpoint is **126 GiB — larger than nimbus's entire 121.7 GiB pool**, before any KV
cache or the OS. 48 GiB of that is the FP8 PLE n-gram table, a pure lookup of which a
token touches 16 rows.

It runs here because [blazux/qwen3.8-Flash-DGX](https://github.com/blazux/qwen3.8-Flash-DGX)
(Apache-2.0) patches vLLM to serve that table from NVMe via `mmap` instead of holding it
resident. That is the *only* published approach that fits: recipes that keep the table —
or a 4-bit requant of it, at ~109 GB — leave no room for k3s on this node.

The checkpoint is **RadixArk's**, not NVIDIA's, and that is load-bearing: RadixArk shards
the PLE into ten `model-plefp8-*` files, NVIDIA ships one 53.72 GB blob, and the mmap
patch and its range guard expect the shards.

### Measured on nimbus, 2026-09-08

| | |
|---|---|
| weights resident (PLE mmapped) | 79.42 GiB |
| consumed (weights + non-torch) | 85.95 GiB |
| peak activation / CUDA graphs | 1.78 / 0.69 GiB |
| KV cache (hard cap) | 8 GiB → 282,420 tokens |
| max concurrency @ 262144 | 1.08× |
| node MemAvailable, steady state | **11.3 GiB** |
| weight load / engine init | 634 s / 100 s |
| decode, single stream | ~23 tok/s (MTP=2, 69% acceptance) |
| prefill, cold page cache | ~1,600 tok/s |
| 38k-token prefix, cold → cached | 25.9 s → 4.0 s (95.7% hit) |

**Why the KV cache is capped at 8 GiB.** Left to `--gpu-memory-utilization 0.82` alone,
vLLM took 12.05 GiB of KV (425,802 tokens, 1.62×) and left the node at **7.64 GiB**
MemAvailable — *below* `gpu-hang-watchdog`'s 8 GiB floor, which drops page cache at two
consecutive sub-floor samples and SIGKILLs vLLM at three, one sample per minute. The
cache-drop rung is the worse of the two for this model: it evicts the page cache the
mmapped PLE table reads through, degrading prefill instead of failing loudly. 8 GiB of
KV returns ~4 GiB and lands MemAvailable at 11.3 GiB.

The `1.08×` figure bounds only simultaneous *262144-token* requests. KV is allocated per
token, so ordinary traffic gets far more than one concurrent stream.

If that proves too tight, `--kv-cache-dtype fp8_e4m3` buys ~1.9× the KV in the same
8 GiB — full context and real concurrency, at a speed and quality cost. blazux ships it
opt-in for that reason.

### Measured throughput, 2026-09-08

`bench-flashnext-nimbus.py`, run **inside the pod** against `localhost:8000`, so
these exclude Traefik/TLS/WAN. Prefill and decode are separated by streaming: TTFT
is the prefill wall, and the tokens after it over the time after it are the decode
rate. 256 generated tokens per request, `temperature 0`.

**Single stream.** Cold = unique prefix, warm = prefix already cached.

| prompt | cold TTFT | cold prefill | warm TTFT | decode (cold/warm) |
|---:|---:|---:|---:|---:|
| 4,067 | 2.4 s | 1,684 tok/s | 1.5 s | 27.2 / 29.5 |
| 16,008 | 9.5 s | 1,689 tok/s | 1.1 s | 26.9 / 29.5 |
| 31,926 | 19.0 s | 1,682 tok/s | 2.0 s | 26.2 / 28.8 |
| 63,767 | 39.1 s | 1,632 tok/s | 2.1 s | 26.7 / 29.5 |
| 127,446 | 81.3 s | 1,568 tok/s | 2.1 s | 25.5 / 28.6 |

Two properties matter more than the absolute numbers:

- **Prefill is flat in context length** — 1,684 tok/s at 4k, 1,568 at 128k, across a
  31x range. QSA sparse attention means no quadratic collapse. This is the opposite
  of cirrus, whose prefill falls apart with length (issue #38).
- **Decode is also flat** — ~26 tok/s at 4k and at 128k alike. Only 12 of 48 layers
  are full attention; the other 36 are Gated DeltaNet linear attention whose state is
  constant per sequence, so KV barely grows with context.

Warm TTFT is ~2 s at *any* prompt size, so at 128k a cache hit is worth **38x**
(81.3 s -> 2.1 s). MTP acceptance held 62-68% throughout.

**Concurrency, 32k prompts.** All-cold is the pathological case; shared-prefix is
what agentic traffic actually looks like (the geo-agent slice hit 84.9% prefix hits).

| N | TTFT median, cold / shared | decode per stream, cold / shared | aggregate tok/s, cold / shared |
|---:|---:|---:|---:|
| 1 | 19.2 s / 2.0 s | 26.6 / 26.2 | 8.9 / 21.8 |
| 2 | 33.6 s / 3.5 s | 22.8 / 23.3 | 11.4 / 35.0 |
| 4 | 60.5 s / 6.0 s | 17.3 / 18.2 | 13.6 / **50.7** |
| 8 | 91.3 s / 13.5 s | 15.7 / 17.8 | 14.1 / 52.1 |

- **Prefix reuse is worth 3.7x aggregate throughput and ~7x TTFT** at N=8. It is the
  single largest lever available, and it is client-side: keep the system prompt and
  tool definitions byte-identical at the front of every turn.
- **All-cold concurrency is prefill-bound, not decode-bound.** Eight cold 32k prompts
  is 256k tokens of prefill at ~1,600 tok/s ~= 160 s, which is essentially the 145 s
  wall observed. Aggregate throughput gains only 58% for 8x the load.
- **`--max-num-seqs 4` is the right cap.** 4 -> 8 buys 3% aggregate (50.7 -> 52.1)
  while median TTFT doubles and worst case reaches 25.6 s. Four is the knee.

Benchmarking notes, learned the hard way: run the load **detached inside the pod**
(`nohup setsid`) -- a client killed by a tool timeout leaves its request generating
server-side and corrupts later measurements. Do not use `ignore_eos` on this
checkpoint. Do not derive decode from `vllm:inter_token_latency`: under MTP that is
per *step*, and a step emits up to 3 tokens.

### Things that are easy to get wrong

- **Prefix caching is correct here, but only because the image fixes it.** vLLM
  overwrote `cache_config.block_size` with the smallest KV-group block while the Mamba
  block is 1600, so a prefix hit restored an *all-zero* Mamba state and returned
  silently wrong answers. Look for `Setting attention block size to 1600 tokens` and
  `Mamba cache mode is set to 'align'` at startup. Do **not** enable prefix caching on
  an unpatched image.
- **Hit rates need blocks, not tokens.** With a 1600-token block, a ~1.6k-token prompt
  shows 0% hit rate and looks broken. Test with tens of thousands of tokens.
- **The PLE gather must stay outside CUDA graphs** — it is a CPU op plus a pageable
  host→device copy. Hence `-cc.cudagraph_mode=PIECEWISE` and `vllm::ple_mmap_lookup` in
  `splitting_ops`.
- **`PREWARM` is off.** blazux streams the 48 GiB table into page cache at boot; with
  ~11 GiB spare that would only thrash. The cost is a 2–3× slower first pass over a cold
  region of the table, which is most of the gap between our ~1,600 tok/s prefill and
  their ~2,400–2,900.
- **The image lives in ghcr and is referenced by digest.** Do not leave it local
  with `imagePullPolicy: Never` — k3s image GC may reclaim an unreferenced image,
  and the recovery is a ~40 minute rebuild.
  `.github/workflows/vllm-flashnext-image.yml` builds it on `ubuntu-24.04-arm`.
  A hosted arm64 runner handles this fine: measured 145 GB of disk with 109 GB
  free before cleanup, against an 18.7 GiB extracted base. (An earlier note here
  claimed ~14 GB and used that to justify building on the node — wrong by an
  order of magnitude, from a search result rather than a measurement.)
  `build-flashnext-nimbus.yaml` remains as the offline fallback.
  The one real blocker is ghcr package permissions: the package was first created
  by a PAT push, so it is not linked to this repo and `GITHUB_TOKEN` gets
  `denied: permission_denied: write_package` until the `k8s` repository is granted
  Write under the package's *Manage Actions access* settings.

## Operational notes worth keeping

- **Long-running completions need the `ServersTransport`.** A big prefill exceeds
  Traefik's default timeouts, and Cloudflare's proxy cuts off any response that takes
  more than ~100 s to first byte (a 524). Both endpoints therefore set
  `cloudflare-proxied: "false"` (DNS-only, grey cloud) and a 600 s transport. TLS is
  unaffected — the origin serves its own Let's Encrypt cert.
- **Pin sampling defaults.** Checkpoints ship their own `generation_config.json`;
  Qwen's `temperature: 1.0` made borderline prompts flip between answering directly
  and calling a tool, run to run. `--override-generation-config` makes server
  behaviour reproducible for clients that send no sampling params.
- **Malformed tool-call JSON is usually truncation, not a parser bug.** When reasoning
  eats the token budget, the arguments string is cut mid-stream — and vLLM reports
  `finish_reason: "tool_calls"` rather than `"length"`, so clients can't tell. Raise
  `max_tokens` before suspecting the parser.
- **A long readiness probe is deliberate.** Loading a 27B checkpoint takes minutes; a
  default probe restarts the pod mid-load, forever.

## Metrics

vLLM's `/metrics` is unauthenticated and scraped by Prometheus via the
`prometheus.io/*` annotations on the *endpoint* Services — so scraping survives a
model switch and nothing double-scrapes. Dashboards:
[`../../platform/monitoring/`](../../platform/monitoring/).
