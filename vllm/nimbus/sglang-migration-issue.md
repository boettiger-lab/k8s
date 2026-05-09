# Nemotron-Super on SGLang/DGX Spark — status & open issues

_Last updated 2026-05-08._

## TL;DR

Nemotron-3-Super-120B-A12B-NVFP4 is **serving** on SGLang 26.04 on the nimbus DGX Spark via `deploy-nemotron-sglang.yaml`. It required two non-obvious workarounds — `--disable-piecewise-cuda-graph` and a JIT pre-warm wrapper — to dodge a torch.dynamo bug in FlashInfer's FP4 quantization path. Synthetic throughput is in the ballpark of every other framework people have gotten working on this hardware (decode 14.5 tok/s, prefill 1.18k tok/s).

**Apples-to-apples A/B vs. the prior vLLM-Marlin deployment shows a clean ~10% regression on every metric, every app, on the agentic workloads we tested first** (32 NVFP4 vs 33 Marlin successful runs across 4 apps; aggregate 0.83× combined throughput, 0.92× output tok/s). Those workloads are decode-dominated (KV cache reuse → ~95% time in decode), where SGLang+NVFP4 currently can't beat vLLM-Marlin on this chip. **Verdict deferred** — workloads with large novel context (low cache reuse, prefill-heavy) still need to be tested before deciding whether to roll back. See the A/B table below.

## What's running

```
nemotron-bd5989c-m2l2p   1/1   Running   0   <ongoing>
```

- Image `nvcr.io/nvidia/sglang:26.04-py3` (SGLang 0.5.10+516d57ac, FlashInfer 0.6.7.post3+nv26.04, CUDA 13.2)
- LoadBalancer `vllm-nimbus-service` → `http://169.229.53.67:8000` (`/v1/chat/completions`, `/v1/models`, `/health`, `/metrics`)
- Tool-calling parser `qwen3_coder` enabled, FP8 KV cache, 262K context, 7 GPU slices, `--mem-fraction-static 0.875`, `--mamba-scheduler-strategy no_buffer`
- `strategy: Recreate` on the Deployment (single-node cluster cannot surge GPU-bound pods)

## The bug we ran into (still upstream-open)

NGC 26.04 ships a patched FlashInfer 0.6.7.post3 that fixes the SM121 illegal-instruction crash from 26.03. Replacing one bug, it surfaced another:

```
torch._dynamo.exc.Unsupported: Attempted to call function marked as skipped
  module: _thread, qualname: allocate_lock
```

Trace path: SGLang piecewise-CUDA-graph capture → `nemotron_h.py:115 down_proj` → `flashinfer/quantization/fp4_quantization.py:700 fp4_quantize` → `get_fp4_quantization_module("120")` → `gen_fp4_quantization_sm120f_module` → `is_cuda_version_at_least("12.8")` → `subprocess.check_output(["nvcc","--version"])` → `Popen.__init__` → `threading.Lock()`. Torch.dynamo refuses to trace `_thread.allocate_lock` (a C builtin) and aborts compilation.

Important detail: caching the JIT-built `.so` does **not** avoid the failure. `is_cuda_version_at_least()` is invoked unconditionally on every call to construct the nvcc flag list **before** the on-disk cache hash check. So even with the kernel pre-built, the subprocess call still runs inside the dynamo-traced region and still aborts.

NGC's SGLang 26.02 release notes had a now-deleted known-issue note: _"When using Nemotron Nano-V2-9B or Nemotron Nano-V3-30B models on Spark/Thor with SGLang the user will need to install the flashinfer-jit-cache before running."_ That advice doesn't actually help on 26.04 — the prebuilt `flashinfer-jit-cache` wheels for CUDA ≥12.9 only ship `sm120f`, not `sm121a`, and SM121 native NVFP4 MMA is JIT-only ([FlashInfer #3170](https://github.com/flashinfer-ai/flashinfer/issues/3170)).

## What ended up working

Three changes to `deploy-nemotron-sglang.yaml`:

1. **`--disable-piecewise-cuda-graph`** — the actual fix. PCG is the path that traces `forward()` under dynamo. Disabled, `forward()` runs in eager Python, the subprocess call works fine. Full CUDA graph capture (non-piecewise) still active for batch sizes 1, 2, 4, 8, 10.
2. **Pre-warm wrapper** before `sglang.launch_server`. Builds the FP4 quantization kernel for the device's compute capability outside any dynamo context, populates `~/.cache/flashinfer`. Does not by itself fix the bug (see above) but reduces startup compile time on subsequent restarts. Also best-effort `pip install flashinfer-jit-cache` — harmless if the wheel doesn't apply.
3. **`strategy: Recreate`** on the Deployment. The nimbus node has 7 GPUs, all consumed by the active pod; the default RollingUpdate strategy pins new pods in `Pending: Insufficient nvidia.com/gpu` forever. Recreate forces tear-down-then-create.

## Measured throughput (2026-04-28)

| Metric             | Value         | Notes                                       |
|--------------------|---------------|---------------------------------------------|
| Decode (steady)    | **14.5 tok/s** | bs=1, 800-token completion, T=0             |
| Prefill (long)     | **1180 tok/s** | 6,032-token prompt, TTFT 5.1s              |
| Prefill (short)    | 141 tok/s     | 40-token prompt, dominated by launch overhead |
| Weight load        | 314 s         | 17 shards from local HF cache              |
| CUDA graph capture | 12 s          | bs ∈ {1,2,4,8,10}                          |
| Memory headroom    | 11.5 GB free  | after KV cache (2.94 M tokens) + Mamba 10 GB |

In FLOPs terms (active params = 12B, 2 FLOP/param/token):

- **Prefill ≈ 28 TFLOP/s sustained → ~2.8% of NVIDIA's headline "1 PFLOP NVFP4" peak.**
- **Decode ≈ 0.35 TFLOP/s sustained → ~0.04% of headline.**

The 1 PFLOP figure is dense FP4 MMA at full tensor-core saturation; LLM inference at bs=1 is dominated by activation movement and leaves most FP4 MMA pipes idle. Community reports for Nemotron-Super on Spark across vLLM-Marlin, TRT-LLM, llama.cpp cluster around 16–35 tok/s decode — our 14.5 is at the low end and likely costs us a few % from disabled PCG. Re-enabling PCG would likely buy ~25–35% more prefill throughput at long context, single-digit % at short prompts; decode would barely move.

**Power draw at 96% GPU util** (per `nvidia-smi -q -d POWER`): 62.4 W average / 48 W instantaneous on the GB10 GPU portion. Module-level / SoC-total readings are `N/A` on Spark — the unified package doesn't expose total power through the standard interface (no `tegrastats`, no IPMI, no hwmon rail). With Spark's published 140 W TDP and CPU at low load, total system draw during inference is plausibly 80–110 W. Efficiency: ~0.45 TFLOP/s/W on prefill, ~0.006 TFLOP/s/W on single-stream decode — both far below the 7 TFLOP/s/W implied by the 1 PFLOP / 140 W marketing peak.

## Real-workload A/B vs. vLLM-Marlin (2026-04-28)

Apples-to-apples on real agentic apps (32 NVFP4 vs 33 Marlin successful runs across 4 apps, ~3.6h matrix). Same model, same hardware, same prompts.

| App                  | Metric                  | NVFP4 | Marlin | NVFP4 / Marlin |
|----------------------|-------------------------|-------|--------|----------------|
| tpl-ca               | combined tok/s/fetch    | 734   | 790    | 0.93× ↓        |
|                      | output tok/s            | 12.3  | 13.7   | 0.90× ↓        |
|                      | median elapsed          | 338s  | 312s   | 0.92× ↓        |
| tpl                  | combined tok/s/fetch    | 712   | 822    | 0.87× ↓        |
|                      | output tok/s            | 12.5  | 13.9   | 0.90× ↓        |
|                      | median elapsed          | 352s  | 214s   | 0.61× ↓        |
| bosl-high-seas       | combined tok/s/fetch    | 455   | 506    | 0.90× ↓        |
|                      | output tok/s            | 12.8  | 13.6   | 0.94× ↓        |
|                      | median elapsed          | 343s  | 247s   | 0.72× ↓        |
| padus                | combined tok/s/fetch    | 531   | 568    | 0.93× ↓        |
|                      | output tok/s            | 12.4  | 13.7   | 0.90× ↓        |
|                      | median elapsed          | 271s  | 365s   | 1.35× ↑*       |
| **AGGREGATE**        | combined throughput     |       |        | **0.83×** (NVFP4 17% slower) |
|                      | output tok/s            |       |        | **0.92×** (NVFP4  8% slower) |
|                      | total wall-clock        | 2.67h | 2.11h  | NVFP4 took 27% longer for ~same input volume (4.5M vs 4.3M tokens) |

*padus elapsed looks better only because NVFP4 took different tool-call trajectories — the per-fetch throughput is still 0.93×.

### Why decode is slower on NVFP4 than Marlin (mechanistically)

These workloads are decode-dominated (~95% time in decode due to KV cache reuse). The ~10% decode regression is the whole story for them. For decode, both paths read the same FP4 weights from HBM — the bandwidth budget is identical. The compute work differs:

| Step                 | vLLM-Marlin                         | SGLang-NVFP4                                |
|----------------------|-------------------------------------|---------------------------------------------|
| Weight format        | FP4 + scales                        | FP4 + scales (same)                         |
| Activation handling  | Stays in BF16                       | **Quantized to FP4 per layer** (extra `fp4_quantize` kernel) |
| MMA tensor-core path | BF16 cuBLAS (mature, well-tuned)    | FP4 MMA on `sm120f` JIT kernel — **forward-compat code, not native SM121** |
| Per-layer overhead   | One dequant + one BF16 MMA          | One activation-quant + one (suboptimal) FP4 MMA |

The native SM121 NVFP4 MMA hardware exists but isn't being properly used: per [FlashInfer #3170](https://github.com/flashinfer-ai/flashinfer/issues/3170), prebuilt wheels at CUDA ≥12.9 emit only `sm120f` targets — no `sm121a`, and SM121 native NVFP4 MMA is JIT-only. Our prewarm builds `gen_fp4_quantization_sm120f_module` (SM120-class, forward-compat), not a `sm121a`-tuned kernel. So we pay the activation-quantization tax (which Marlin doesn't pay) without the FP4-MMA throughput payoff (which a fully-tuned SM121a kernel would give). That's a textbook ~10% regression.

Verifying the user's three diagnostic questions:

1. **"Is the NVFP4 kernel actually being hit?"** — Yes, but the wrong NVFP4 kernel: the `sm120f` AOT-eligible variant via JIT, not a true `sm121a` native path. There's no silent fallback to BF16/Marlin happening; we're on the FP4 path, just not the *good* FP4 path for this chip.
2. **"Batch / TP config matching Marlin?"** — `tp_size=1` matches single-GPU, `max_running_requests=10`. KV cache dtype differs (FP8 here vs likely BF16 on Marlin) but FP8 KV cache should *help* decode bandwidth, not hurt — second-order effect.
3. **"Anything logging fallback?"** — No explicit "NVFP4 not supported, falling back" in our logs. The SGLang banner just says "auto-selecting fp4-gemm-backend=flashinfer_cudnn"; cuDNN's FP4 GEMM on SM121 silently runs whatever it has. No warning, no error, just slower.

## What we still need to test before deciding rollback

The 4-app A/B is decode-dominated. Other use cases will not leverage KV cache as well — they'll have huge novel context per query, putting prefill on the critical path. For those:

- **Prefill regression from disabled PCG could be much worse than it shows in synthetic benchmarks** (the 1180 tok/s on 6K prompt was without concurrency; production prefill with concurrent requests, mamba state churn, and chunked prefill at 8192 may amortize less of the launch overhead).
- **But** prefill of fresh long context is also where NVFP4 *should* shine relative to Marlin if the FP4 MMA pipes are utilized at all — Marlin has to dequant-to-BF16 before MMA, so at long context the per-token MMA cost should favor NVFP4.

Tests in flight: workloads with low cache-reuse, long novel context per query. Verdict pending those numbers. The current pod stays up.

## What we lost vs. the migration motivation

The original case to migrate from vLLM back to SGLang (per the prior version of this doc) rested on:

- **1.32× faster prefill at bs=1** — that win came specifically from PCG, which we just disabled. Net of `--disable-piecewise-cuda-graph` we are roughly at parity with vLLM-Marlin on prefill, possibly slightly behind.
- **Native FlashInfer attention vs. vLLM's TRITON_ATTN fallback** — still a real win, retained.
- **Better RadixAttention prefix-cache eviction** — retained.
- **Built-in Prometheus metrics at `/metrics`** — retained.
- **No Marlin env-var workarounds** — retained (we're on the actual NVFP4 quant path, not weight-only-dequant).

So we kept three of four advantages. The prefill-speed advantage waits on upstream.

## Upstream issues we're tracking

| Tracker | What it is | Why it matters | State |
|---|---|---|---|
| [FlashInfer #2776](https://github.com/flashinfer-ai/flashinfer/issues/2776) | NVFP4 MoE crash on GB10 during PCG capture | Same failure family as ours | Open since Mar 2026 |
| [FlashInfer #3170](https://github.com/flashinfer-ai/flashinfer/issues/3170) | SM121 AOT-coverage audit | Confirms `sm121a` kernels are JIT-only; no AOT path exists yet | Open since Apr 24 2026 |
| [FlashInfer #2252](https://github.com/flashinfer-ai/flashinfer/issues/2252) | vLLM+FlashInfer nvcc subprocess fails on Spark | Same `subprocess.check_output(nvcc)` choke point | Open since Dec 2025 |
| [SGLang #20775](https://github.com/sgl-project/sglang/issues/20775) | `flashinfer_cutlass` doesn't fully disable DeepGemm | Eliminates the obvious "just swap the FP4 backend" workaround | Closed not-planned |
| [SGLang #17130](https://github.com/sgl-project/sglang/issues/17130) | Q1 2026 roadmap: jit-cache & cubins | Likely vehicle for shipping AOT SM121 kernels | Undated |
| [SGLang #5389](https://github.com/sgl-project/sglang/issues/5389) | DGX Spark SGLang tracking issue | Umbrella for Spark-specific issues | Long-running |

What an upstream fix likely looks like, in increasing quality:

1. **Cache the version probe** — wrap `flashinfer.jit.cpp_ext.get_cuda_version` in `functools.lru_cache`. ~5-line PR. Helps every warm process.
2. **Hoist the version probe to module-import time** — resolve once, bake the result into the build-flag list. Cleaner; fixes our case unconditionally.
3. **Register `fp4_quantize` as `torch.compiler.allow_in_graph`** — the proper fix. Tells dynamo to treat the call as opaque. This is the path the dynamo error message itself suggests.
4. **Ship AOT `sm121a` cubins via `flashinfer-jit-cache`** — eliminates the JIT path entirely on GB10.

Likely vehicle: FlashInfer 0.6.11+ → NGC SGLang 26.05 or 26.06.

## FlashInfer 0.6.11 (2026-05-07) — SM121-relevant changes

FlashInfer 0.6.11 (pre-release, published 2026-05-07) contains the most SM120/SM121-targeted changes of any release to date. NGC 26.05 has not yet dropped as of 2026-05-08; when it does, it will likely bundle this version.

**Directly relevant PRs:**

| PR | Title | Why it matters |
|----|-------|---------------|
| [#3175](https://github.com/flashinfer-ai/flashinfer/pull/3175) | `fix: align is_sm120f_supported with SM12x family semantics` | Changes how SM121 is classified relative to SM120f. If SM121 now resolves to AOT-covered paths, the JIT path (and its `is_cuda_version_at_least` subprocess call) may never be entered — potentially fixing the PCG dynamo bug without an explicit patch. |
| [#3173](https://github.com/flashinfer-ai/flashinfer/pull/3173) | `fix: add sm_121 to TMEM column fallback map` | SM121 was missing from the tensor-memory fallback map — a correctness gap specific to our chip. |
| [#3152](https://github.com/flashinfer-ai/flashinfer/pull/3152) | `Integrate CUTLASS Small Tile N Blockscaled GEMMs/Grouped GEMMs for SM120 and SM121` | Adds native blockscaled (NVFP4) GEMM support for SM121. This is the performance gap identified in the A/B results — the activation-quant tax without the FP4-MMA payoff. Expect measurable decode throughput improvement. |
| [#3192](https://github.com/flashinfer-ai/flashinfer/pull/3192) | `fix cudnn sm120 nan` | Fixes NaN values from cuDNN on SM120-family; we use `--fp4-gemm-backend=flashinfer_cudnn`. |
| [#3191](https://github.com/flashinfer-ai/flashinfer/pull/3191) | `fix(sm12x): fix micro-kernel workspace sizing when routed_rows > num_local_experts` | Workspace sizing fix for SM12x MoE; may address the CUTLASS TMA alignment crash in #2776. |
| [#3193](https://github.com/flashinfer-ai/flashinfer/pull/3193) | `perf(moe): optimize SM120 b12x MoE short decode` | Decode throughput improvement for SM120-family. |

**What's still not fixed explicitly:** No PR in 0.6.11 directly patches `is_cuda_version_at_least` or registers `fp4_quantize` as `torch.compiler.allow_in_graph`. PR #3175 is the wild card — untested whether it eliminates the JIT path for SM121 and thus the PCG dynamo crash.

**Action when NGC 26.05 drops:** pull the new container and test with `--disable-piecewise-cuda-graph` removed. If PCG no longer crashes, drop the flag and recover the prefill win. If it still crashes, the monkey-patch workaround remains the next step.

## Local workaround to recover PCG (untested)

Monkey-patch `is_cuda_version_at_least` to a constant-returning Python lambda *before* SGLang imports flashinfer. Inject via `sitecustomize.py` on `PYTHONPATH`:

```python
# /opt/patches/sitecustomize.py
import flashinfer.jit.cpp_ext as _e
from packaging.version import Version
_v = Version("13.2.1")
_e.get_cuda_version = lambda: _v
_e.is_cuda_version_at_least = lambda v: True
```

Then mount the patch and add `PYTHONPATH=/opt/patches:$PYTHONPATH` to the pod env. If dynamo can trace the lambda (it should — pure Python returning a Python bool), drop `--disable-piecewise-cuda-graph` and recover the prefill win. If `packaging.Version` import inside `get_cuda_version` trips dynamo, drop that line and only patch `is_cuda_version_at_least`. Risk is low: we know the CUDA version, so the patch is correct; if PCG re-enables and crashes elsewhere, restore the flag.

## NVIDIA's own recipe for this hardware

For reference, NVIDIA's [Nemotron Spark Deployment Guide](https://docs.nvidia.com/nemotron/nightly/usage-cookbook/Nemotron-3-Super/SparkDeploymentGuide/README.html) and the [NVIDIA-NeMo/Nemotron cookbook](https://github.com/NVIDIA-NeMo/Nemotron/tree/main/usage-cookbook/Nemotron-3-Super) document **only vLLM-Marlin and TRT-LLM** for this model on Spark. There is no NVIDIA-published SGLang-on-Spark recipe for Nemotron-Super. The NemoClaw blueprint at [build.nvidia.com/spark/nemoclaw](https://build.nvidia.com/spark/nemoclaw) ships the vLLM container. The community consensus across [r/LocalLLaMA](https://www.reddit.com/r/LocalLLaMA/), [forums.developer.nvidia.com](https://forums.developer.nvidia.com/), and [HF discussions](https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4/discussions) is that nobody comes close to advertised peak NVFP4 throughput on Spark on any framework yet.

## Reference: cluster commands

```bash
# Status
kubectl get pods -n default -l k8s-app=vllm-nimbus-nemotron
kubectl logs  -n default -l k8s-app=vllm-nimbus-nemotron --tail=50

# Quick health
curl -s http://169.229.53.67:8000/health

# Chat-completion
API_KEY=$(kubectl get secret vllm-api-key -o jsonpath='{.data.api-key}' | base64 -d)
curl -s -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" \
  http://169.229.53.67:8000/v1/chat/completions \
  -d '{"model":"nemotron","messages":[{"role":"user","content":"hi"}],"max_tokens":32}'

# Apply manifest changes (Recreate strategy will tear down old pod automatically)
kubectl apply -f deploy-nemotron-sglang.yaml
```
