# vLLM — OpenAI-compatible LLM inference

Two GPU nodes each serve one model at a time, at a fixed URL:

| Endpoint | Node | Currently | Hardware |
|---|---|---|---|
| <https://vllm-cirrus.carlboettiger.info> | cirrus | `qwen3-8` — Qwen3.8-27B AWQ-INT4 | 2× Quadro RTX 8000 (48 GB each) |
| <https://vllm-nimbus.carlboettiger.info> | nimbus | `qwen`/`qwen3.8` — Qwen3.8-27B NVFP4 | DGX Spark GB10, 128 GB unified |
| <https://whisper-cirrus.carlboettiger.info> | cirrus | `whisper` — speech-to-text | scaled to 0 unless in use |

Both are OpenAI-compatible and require an API key:

```bash
API_KEY=$(kubectl get secret vllm-api-key -n vllm -o jsonpath='{.data.api-key}' | base64 -d)
curl -s https://vllm-nimbus.carlboettiger.info/v1/models -H "Authorization: Bearer $API_KEY"
```

## Layout

| File | What |
|---|---|
| `endpoints.yaml` | The Services, Ingresses and Traefik `ServersTransport` — the *stable* half |
| `qwen3-8-cirrus.yaml`, `gemma4-cirrus.yaml` (google/gemma-4-E2B-it), `whisper-cirrus.yaml` | Model Deployments on cirrus |
| `qwen38-nimbus.yaml` | Model Deployment on nimbus |
| `bench-qwen38-nimbus.sh` | Throughput benchmark for the nimbus endpoint |
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

Don't run two models on one node at once — they would split traffic. GPU memory
usually prevents it anyway. Model Deployments use `strategy: Recreate`: a rolling
update deadlocks waiting for GPU the outgoing pod still holds.

## The two nodes are not interchangeable

**cirrus** — two discrete 48 GB cards. Requesting `nvidia.com/gpu: 2` gets two
*distinct* physical GPUs, and cgroup `memory:` is a genuine limit on host RAM, with
VRAM tracked separately. TP=2 was measured on 2026-08-18 and is a net loss for a
27B model here; keep TP=1 (the reasoning is in the manifest).

**nimbus** — one GB10 with no discrete VRAM: CPU and GPU share a single ~122 GiB
LPDDR5X pool. Two consequences that repeatedly surprise people:

1. **`memory:` is scheduler accounting, not a limit.** CUDA allocations are invisible
   to the cgroup memory controller (verified: a pod capped at `memory: 32Gi`
   cheerfully reserved 36 GiB of KV cache and kept running). So the request must
   reflect *actual* unified-memory use — weights + KV cache + ~4 GiB CPU overhead —
   or the scheduler will co-schedule something that OOMs the host for real. Guard the
   ceiling with `--kv-cache-memory-bytes` — an absolute cap that bypasses vLLM's
   profiler; `--gpu-memory-utilization` is applied against the full visible pool, not
   the cgroup. The measurements behind both are in `dgx-spark-memory.md`.
2. **`nvidia.com/gpu: 8` is 8 time-slices of one GPU**, not 8 GPUs, and the slices
   share both compute and the memory pool. Requesting all 8 would idle-block the node
   against every other GPU job; vLLM takes 6 and the GPU MCP server
   ([`../mcp/`](../mcp/)) takes 1. On the Spark the
   replica count is a *concurrency cap*, which is exactly why nimbus keeps time-slicing
   while thelio's 8 GB card does not — see
   [`../../platform/nvidia/`](../../platform/nvidia/).

Images differ too: nimbus is **aarch64**, so it runs NGC's `nvcr.io/nvidia/vllm`
(pull secret `ngc-pull`), never `vllm/vllm-openai`, which is x86-only. Weights live in
a hostPath HF cache (~215 GB) rather than a PVC, because nimbus runs no storage plugin.

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
