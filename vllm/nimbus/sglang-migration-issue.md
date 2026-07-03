# Nemotron-Super on SGLang/DGX Spark — status & open issues

_Last updated 2026-07-02._

## 2026-07-02 update — the packaging blocker cleared, and the decode theory is now contradicted upstream

Two developments since 2026-06-18 change what we're waiting on:

1. **NGC SGLang 26.06 dropped and bundles FlashInfer 0.6.12** (SGLang 0.5.12.post1, CUDA 13.3.0) — so it carries #3081, the PCG dynamo fix. The "trap" from the 0.6.12 section below is resolved: we no longer need a pip-upgrade or the `sitecustomize.py` patch to drop `--disable-piecewise-cuda-graph`. A clean container pull now recovers the prefill win. (26.06 note: **MTP is not supported for Nemotron-3-Super** — not a path we use.) FlashInfer upstream is now at 0.6.13 final (Jun 24) and 0.6.14 (Jul 2, pre-release).

2. **The b12x dispatch heuristic is UNCHANGED — and upstream has reframed the SM121 exclusion as intentional, not a bug.** Verified verbatim in `flashinfer/gemm/gemm_base.py` at v0.6.12, v0.6.13, and v0.6.14 (`_heuristic_func_mm_fp4`, ~line 6083 in 0.6.14):

   ```python
   is_sm120 = major == 12 and minor == 0
   # SM120 + CUDA 13: prefer b12x. SM121 (GB10) is intentionally excluded -- b12x
   # is supported there as an explicit backend, but cutlass/cudnn are faster in
   # most cases, so `auto` keeps using them.
   if is_sm120 and use_nvfp4 and cuda_major >= 13:
       return [c for c in ("b12x", "cutlass", "cudnn") if c in suitable_backends]
   ```

   This **contradicts the decode root-cause theory in the rest of this doc.** We assumed the `121→120` redirect was a gap "wasting" a faster b12x path (the A/B decode-regression diagnosis below). Upstream now asserts the opposite: b12x *is* available on GB10 as an explicit backend, they measured cutlass/cudnn as faster there in most cases, and `auto` deliberately keeps using them. (The v0.6.14 comment added the explicit "intentionally excluded … faster in most cases" rationale; 0.6.12/0.6.13 had the same gate with a terser comment.) So "wait for b12x to select on SM121" is no longer the right thing to wait for — that path exists and upstream chose not to use it on perf grounds.

   Note: upstream's "faster in most cases" comparison is b12x-vs-cutlass/cudnn *within* FlashInfer-NVFP4 — it does **not** speak to our actual question, which is FlashInfer-NVFP4 vs. **vLLM-Marlin**. That remains open and empirical.

**A large SM12x PR wave landed after 2026-06-15**, several touching the NVFP4 path our A/B blamed: #3646 (relax b12x FP4 K constraint 128→32, Jun 16), #3744 (b12x NVFP4 MoE activations "for SM12x", Jul 1), #3597 (BF16_FP4 GEMM for SM120/121, Jun 22), #3640 (SM120 NVFP4 attention JIT, Jun 17), #3615 (fix SM120/121 top-k stream hangs, Jun 16). Also #3668 (Jun 25) now **rejects SM120/SM121 in Mamba SSDCombined with a clear error** — relevant to Nemotron's hybrid layers: still no native SSD path on GB10, just a louder failure.

**Revised action:** the packaging blocker is gone and the "b12x heuristic" wait is moot, so stop upstream-watching and **test empirically on the live deployment**: pull 26.06 (or 26.04/26.05 + `pip install -U flashinfer-python>=0.6.12`), drop `--disable-piecewise-cuda-graph`, and re-run the decode-dominated 4-app A/B vs. vLLM-Marlin. If FlashInfer-NVFP4 (cutlass/cudnn + the newer per-token quant #3237 and SM12x perf fixes) has closed the ~10% decode gap, migrate; if not, the vLLM-Marlin decision stands regardless of #3170's remaining items.

### 2026-07-02 empirical A/B result — TESTED on 26.06; decode gap did NOT close; vLLM-Marlin decision STANDS

Ran it. Deployed `nvcr.io/nvidia/sglang:26.06-py3` (FlashInfer 0.6.12) on nimbus and benchmarked a synthetic throughput A/B against the live vLLM-Marlin deployment (`ghcr.io/boettiger-lab/vllm-dgx-spark:latest`, `--attention-backend TRITON_ATTN`). Same model, same hardware, same prompts. Note: this is the **synthetic decode/prefill/concurrent** A/B, not the agentic 4-app matrix (that harness lives outside this repo). Decode bs=1 is the decision metric.

**Two findings:**

**1. PCG still cannot be enabled on 26.06 — new blocker, not the old one.** With `--disable-piecewise-cuda-graph` removed, #3081 *did* fix the original `allocate_lock` dynamo crash (zero occurrences in the logs — confirmed). But piecewise-CUDA-graph capture then died at a **different** point:

```
RuntimeError: CUDA error: CUBLAS_STATUS_INTERNAL_ERROR when calling `cublasGemmEx(... CUDA_R_16BF ...)`
  in moe_forward_piecewise_cuda_graph_impl  (crashes at the 8192-token bucket)
[...] Piecewise CUDA Graph failed [...] To work around this error, add --disable-piecewise-cuda-graph
```

A BF16 cuBLAS GEMM inside the MoE piecewise path returns `CUBLAS_STATUS_INTERNAL_ERROR` on SM121. Full (non-piecewise) CUDA-graph capture for bs {1,2,4,8,10} succeeds fine — only the piecewise path fails. This matches FlashInfer #3170's open "no BF16 backend for SM121" item and the #2776 family (NVFP4 MoE crash on GB10 during graph capture). SGLang's own log tells you to re-add the flag. **So we re-disabled PCG and benchmarked the working config** (same posture as 26.04, just newer kernels). PCG prefill-win recovery is still blocked upstream.

**2. Synthetic A/B (PCG disabled on both-ish; vLLM on TRITON_ATTN):**

| Metric            | vLLM-Marlin | SGLang 26.06 | SGLang / Marlin |
|-------------------|-------------|--------------|-----------------|
| **decode bs=1**   | **16.95 tok/s** (TTFT 0.22s) | 15.49 tok/s (TTFT 0.23s) | **0.91×** (SGLang 8.6% slower) |
| prefill (6.4K tok)| 1799 tok/s  | 2193 tok/s   | 1.22× (SGLang faster) |
| concurrent n=8    | 73.0 tok/s  | 74.7 tok/s   | 1.02× (~parity) |

(3 reps each, low variance. SGLang weight load 370s, KV cache 3.7M tokens; vLLM `--gpu-memory-utilization 0.7` vs SGLang `--mem-fraction-static 0.875`, both `max seqs = 10`.)

**Verdict: vLLM-Marlin stays.** The decode number — the metric that governs our decode-dominated agentic workloads — reproduces the historical ~10% regression almost exactly (0.91× here vs 0.92× output-tok/s in the Apr agentic A/B). The 26.06 kernel wave (per-token NVFP4 quant #3237, SM12x fixes) did **not** close it. SGLang's ~22% prefill win is real but (a) partly reflects vLLM running `TRITON_ATTN` rather than FlashInfer attention — not a clean framework delta — and (b) only matters for prefill-heavy/low-cache-reuse workloads, which our agentic traffic is not. Net: no reason to migrate; re-test only if either the decode kernel path changes upstream or our workload mix shifts prefill-heavy.

**Reproduce:** `scratchpad/bench.py` (streaming decode/prefill/concurrent harness) + saved results `bench_vllm-marlin.json`, `bench_sglang-26.06.json`. Manifest `deploy-nemotron-sglang.yaml` now documents the BF16-cublas PCG crash inline and keeps `--disable-piecewise-cuda-graph` on.

### 2026-07-02 addendum — native-FP4 and MTP experiments (both models); "waiting for native FP4" answer

Two follow-on experiments, both with definitive results:

**Native FP4 MoE in vLLM is NOT available on GB10 for these checkpoints — but TensorRT-LLM DOES do native FP4 here (correction).** In **vLLM**: flipping Qwen3.6-35B-A3B-NVFP4 from `--moe-backend marlin` to `flashinfer_cutlass` fails at engine init — the oracle **explicitly rejects** it: *"NvFp4 MoE backend 'FLASHINFER_CUTLASS' does not support ... QuantKey(u8, scale(f8e4m3fn,static,GroupShape(row=1,col=16)), scale2(f32,static,per_tensor))"*. vLLM's kernel doesn't implement the group-16 NVFP4 + FP8-block-scale scheme; corroborated by vLLM #43906 (fast FP4/FP8 MoE gates on `family(100)`/SM100, excluding SM_12x/GB10). So on the **vLLM** path, Marlin (weight-only 4-bit → BF16 MMA) is correct.

**HOWEVER — native FP4 IS available on GB10 via TensorRT-LLM, which is NVIDIA's *recommended* Spark recipe.** The [NVIDIA-NeMo Nemotron-3-Super SparkDeploymentGuide](https://github.com/NVIDIA-NeMo/nemotron/tree/main/usage-cookbook/Nemotron-3-Super/SparkDeploymentGuide) uses `trtllm-serve` (image `nvcr.io/nvidia/tensorrt-llm/release:1.3.0rc9`) with `extra-llm-api-config.yml`: `moe_config: {backend: CUTLASS}` (**native FP4 MoE**), fp8 KV cache, `mamba_ssm_cache_dtype: float16` + stochastic rounding, and `speculative_config: {decoding_type: MTP, num_nextn_predict_layers: 3}` (**native 3-layer MTP**). So the earlier "native FP4 is dead on this arch" was **too strong** — it's dead in *vLLM* for these checkpoints, but TRT-LLM's CUTLASS FP4 kernels run natively on GB10 and get FP4 + MTP together. Caveat: native FP4 MoE mainly helps prefill/batched throughput; at bs=1 decode you're bandwidth-bound either way (~0.06% of FP4 peak), so the single-stream win is mostly from MTP, not FP4 compute. **TRT-LLM is the untested third path** (the A/B only covered vLLM-Marlin and SGLang-NVFP4) and is the way to actually leverage native FP4 + clean MTP on Nemotron. Worth testing.

### 2026-07-02 — TRT-LLM native-FP4 + MTP TESTED on nimbus (measured)

Deployed NVIDIA's Spark recipe: `nvcr.io/nvidia/tensorrt-llm/release:1.3.0rc9`, `trtllm-serve` (via `/opt/nvidia/nvidia_entrypoint.sh` — overriding `command:` directly breaks `import tensorrt` with a `libnvonnxparser.so.10` error), config = CUTLASS MoE + fp8 KV + fp16 Mamba-SSM-cache + 3-layer MTP. Manifest: `deploy-nemotron-trtllm.yaml` (ClusterIP-only, distinct label `trtllm-nemotron` so the external LB never selects it; `trtllm-serve` has no api-key gate). Startup clean — **native CUTLASS FP4 MoE ran with no crash** (config confirmed `moe_config.backend=CUTLASS`, `nvfp4_gemm_config.allowed_backends=['cutlass',...]`, `MTPSampler` active).

| Metric | vLLM-Marlin | **TRT-LLM native-FP4 + MTP** | Ratio |
|---|---|---|---|
| decode bs=1 | 16.4 tok/s | **20.13 tok/s** (median, sd 0.53) | **1.23×** |
| prefill (6K tok) | ~1799 tok/s | **2773 tok/s** | ~1.54× |
| TTFT (short) | 0.20s | 0.30s | — |

**Read:** confirms native FP4 *works* on GB10 via TRT-LLM (Marlin isn't the only option after all), but the single-stream **decode gain is modest (1.23×)** — MTP acceptance on reasoning/essay content is low (implied mean accepted length ~1.23 tok/step; not cleanly logged). The bigger win is **prefill (~1.5×)** from native FP4 + TRT attention. This matches the physics: at bs=1 decode is bandwidth-bound, so native FP4 compute + MTP only nudge it; FP4 compute shows up in prefill. **Not the 6.5× MTP gave Qwen** — Nemotron is 12B active (vs Qwen 3B) and MTP acceptance is lower here. Trade-off vs vLLM-Marlin: TRT-LLM buys ~1.2× decode / ~1.5× prefill + native FP4 + NVIDIA-blessed, at the cost of a heavier stack (no built-in api-key auth, less operational familiarity, no easy prefix-caching parity). Worth it for prefill-heavy use; marginal for decode-dominated agentic. Benchmark harness/results: `scratchpad/single_stream.py`, `single_trtllm.json`.

### 2026-07-02 session — consolidated experiment log, tracked issues, follow-ups

**Experiments run (all on nimbus, single GB10, single-stream unless noted):**

| Config | Framework / image | decode bs=1 | prefill 6K | Notes |
|---|---|---|---|---|
| Nemotron vLLM-Marlin (baseline) | vLLM lab img (v0.17.2) | **16.4 tok/s** | ~1799 tok/s | current tested prod posture; no MTP; prefix caching on |
| Nemotron SGLang 26.06 (PCG off) | sglang 26.06 / FI 0.6.12 | 15.5 tok/s (0.91×) | 2193 tok/s | #3081 fixed allocate_lock; PCG still dies (BF16 cublas); decode gap NOT closed |
| Nemotron vLLM + MTP | vLLM lab img v0.17.2 | — (crash) | — | Mamba+MTP cudagraph bug `mamba_attn.py:501`; fixed in v0.19 |
| **Nemotron TRT-LLM native-FP4 + MTP** | trtllm 1.3.0rc9 | **20.1 tok/s (1.23×)** | **2773 tok/s (1.54×)** | native CUTLASS FP4 works; MTP accept modest; NVIDIA's recipe |
| Qwen3.6-35B-A3B Marlin (**current default**) | NGC vLLM 26.05.post1 | **106 tok/s** | ~5–11k tok/s | MTP works great (3B active); tool-calls valid; deploy-qwen.yaml |
| Qwen3.6 native FP4 (flashinfer_cutlass) | NGC vLLM 26.05.post1 | — (rejected) | — | oracle rejects the group-16-NVFP4+FP8-scale quant scheme |

**Open upstream issues we're tracking:**
- [FlashInfer #2776](https://github.com/flashinfer-ai/flashinfer/issues/2776) — NVFP4 MoE crash on GB10/SM121 (the core "native NVFP4 on vLLM" blocker). **Open.**
- [vLLM #43906](https://github.com/vllm-project/vllm/issues/43906) — fast FP4/FP8 MoE gates on `family(100)`, excluding SM_12x → Marlin fallback. **Open.**
- [FlashInfer #3170](https://github.com/flashinfer-ai/flashinfer/issues/3170) — SM121 support audit; b12x FP4 GEMM intentionally excludes SM121. **Open.**
- [vLLM #39809](https://github.com/vllm-project/vllm/issues/39809) — Mamba prefix-caching + MTP crash on NemotronH (NVIDIA's vLLM recipe drops prefix caching to sidestep it). Fixed area in v0.19.
- [SGLang #21138](https://github.com/sgl-project/sglang/issues/21138) — MTP ~0 acceptance on NemotronH (SGLang); why SGLang delists Nemotron MTP.
- NVIDIA forum: "MTP CUDA illegal-memory-access on Nemotron-3-Super-NVFP4, vLLM cu130-nightly" — relevant to the guide's own vLLM image.

**Manifests (state):**
- `deploy-qwen.yaml` — **current default**, Qwen3.6 Marlin, external LB + API key, ~106 tok/s.
- `deploy-nemotron.yaml` — tested Nemotron vLLM-Marlin baseline (16.4 tok/s, no MTP).
- `deploy-nemotron-mtp.yaml` — **matches NVIDIA guide's vLLM recipe exactly** (cu130-nightly + Marlin + MTP + no prefix caching); UNTESTED, ready for the vLLM-MTP-vs-TRT-LLM comparison.
- `deploy-nemotron-trtllm.yaml` — TRT-LLM native-FP4 + MTP (tested, 20.1 tok/s); ClusterIP-only (no built-in auth).

**Follow-ups / if we come back:**
1. **Qwen-Marlin quality trial:** run real-world use-case tests on Qwen3.6 (106 tok/s) — decide if quality suffices for our use cases (enjoy the speed) or if we need the stronger Nemotron.
2. **NVIDIA vLLM-MTP vs TRT-LLM:** deploy `deploy-nemotron-mtp.yaml` (cu130-nightly) and compare decode/prefill + MTP acceptance against the TRT-LLM numbers above. (Native FP4 only via TRT-LLM; vLLM path is Marlin+MTP.)
3. **TRT-LLM auth:** trtllm-serve has no api-key gate — add a k8s auth wrapper (sidecar reverse-proxy validating the `vllm-api-key` secret, e.g. a tiny nginx/envoy container in the pod, or an ingress-level auth) before any external exposure. The ClusterIP approach was the interim.
4. Watch #2776 / #43906 for native FP4 MoE reaching vLLM on SM_12x (would let vLLM match TRT-LLM's native path).

**MTP speculative decoding for Nemotron: supported by vLLM, blocked by our image age.** Config parses (`NemotronHMTPModel`, `SpeculativeConfig(method='mtp', num_spec_tokens=2)`, drafter loads, weights shared) — the model *does* ship a native MTP layer (`num_nextn_predict_layers=1`). But the lab image `ghcr.io/boettiger-lab/vllm-dgx-spark:latest` runs **vLLM v0.17.2rc1 (2026-03-17)**, which crashes at Mamba+MTP cudagraph capture (`mamba_attn.py:501`: tensor 32≠34 — spec tokens not accounted for in Mamba attn metadata). Fixed upstream in **vLLM v0.19** ("NemotronH MTP + chunked prefill"). Community reports ~63% acceptance at MTP=2 on a good version → real speedup potential (maybe ~25–40 tok/s vs 16.4 baseline, 12B active caps it). **To pursue:** need a ≥v0.19 image — either NGC vLLM (adapting the `super_v3` reasoning-parser plugin) or a rebuilt lab image. Not blocked on kernels, just packaging. Prefix-caching-vs-MTP tradeoff (vLLM #39809) to be measured once it runs.

---

**Current production posture (decision, 2026-06-18; revised 2026-07-02 — see section above):** stay on **vLLM-Marlin** and **wait for a clean upstream path to native SM121 FP4 performance** — no partial workarounds. The one blocker we could close ourselves (the PCG dynamo crash, fixed in FlashInfer ≥0.6.12) only buys back prefill; it does not address the decode regression. The thing that actually delivers petaflop-class native FP4 — a correct, tuned `sm121a` NVFP4 GEMM that the FlashInfer dispatcher selects — is unwritten upstream kernel work (FlashInfer #3170), not a packaging gap. Flipping the dispatch heuristic to force the path is rejected: the b12x FP4 GEMM isn't validated on SM12x (NaN/garbage reports), so it risks correctness, not just perf. We re-evaluate when #3170 lands a real SM121 path. The SGLang manifest (`deploy-nemotron-sglang.yaml`) is kept ready to re-apply at that point.

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
3. **`strategy: Recreate`** on the Deployment. nimbus is a single DGX Spark (one GB10) exposed via NVIDIA time-slicing as **8 `nvidia.com/gpu` replicas** (not 8 physical GPUs — time-slices of the one GPU, sharing its 124 GB unified memory). This pod requests **7 of the 8 slices**, so the default RollingUpdate strategy can't place a surge pod (only 1 slice free) and pins it in `Pending: Insufficient nvidia.com/gpu` forever. Recreate forces tear-down-then-create.

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

| Tracker | What it is | Why it matters | State (2026-06-18) |
|---|---|---|---|
| [FlashInfer #3170](https://github.com/flashinfer-ai/flashinfer/issues/3170) | DGX Spark (SM121) support audit — the real umbrella | b12x FP4 path still **excludes** SM121 by heuristic — but as of v0.6.14 this is **intentional** (b12x available as explicit backend; cutlass/cudnn measured faster on GB10, so `auto` keeps them). So this is no longer the "root cause we're waiting to be fixed." | **Open** as of Jul 2 2026; heuristic `minor == 0` gate confirmed intact & intentional in v0.6.12/0.6.13/0.6.14 |
| [FlashInfer #2776](https://github.com/flashinfer-ai/flashinfer/issues/2776) | NVFP4 MoE crash on GB10 during PCG capture | Same failure family as ours | **Open** as of Jul 2 2026 (still titled as bug; no confirmed fix) |
| [FlashInfer #2252](https://github.com/flashinfer-ai/flashinfer/issues/2252) | vLLM+FlashInfer nvcc subprocess fails on Spark | Same `subprocess.check_output(nvcc)` choke point | **Closed** Jan 16 2026 |
| [SGLang #19637](https://github.com/sgl-project/sglang/issues/19637) | SM120 Performance Optimization Plan | Tracks NVFP4/MXFP4 GEMM, CUTLASS-vs-Triton blockscale, attn heuristics for SM120/121 | Open since Mar 2 2026 |
| [SGLang #23386](https://github.com/sgl-project/sglang/issues/23386) | "fail to loading cuda graph on DGX Spark" — our exact stack (Nemotron-3-Super-NVFP4, GB10 CC 12.1) | Confirms the `--disable-piecewise-cuda-graph` workaround for the dynamo `allocate_lock` crash | Closed (Apr 21 2026) |
| [SGLang #20775](https://github.com/sgl-project/sglang/issues/20775) | `flashinfer_cutlass` doesn't fully disable DeepGemm | Eliminates the obvious "just swap the FP4 backend" workaround | Closed not-planned |
| [SGLang #17130](https://github.com/sgl-project/sglang/issues/17130) | NVIDIA collaboration roadmap (2026 Q1): jit-cache & cubins | Datacenter-Blackwell-centric (GB300/200/SM100); **no SM121-specific deliverable** — not the vehicle for AOT SM121 kernels after all | Closed (Q1 ended) |

_Correction vs. prior versions of this doc: #2252 is closed (not open); the old "SGLang #5389 DGX Spark tracking issue" was a misattribution — #5389 is an unrelated A100 `cuda_fp8.h` bug from Apr 2025. The genuine umbrellas are FlashInfer #3170 and SGLang #19637._

What an upstream fix likely looks like, in increasing quality:

1. **Cache the version probe** — wrap `flashinfer.jit.cpp_ext.get_cuda_version` in `functools.lru_cache`. ~5-line PR. Helps every warm process.
2. **Hoist the version probe to module-import time** — resolve once, bake the result into the build-flag list. Cleaner; fixes our case unconditionally.
3. **Register `fp4_quantize` as `torch.compiler.allow_in_graph`** — the proper fix. Tells dynamo to treat the call as opaque. This is the path the dynamo error message itself suggests.
4. **Ship AOT `sm121a` cubins via `flashinfer-jit-cache`** — eliminates the JIT path entirely on GB10.

Likely vehicle: FlashInfer 0.6.12 → NGC SGLang 26.05 or 26.06.

## FlashInfer 0.6.12 (2026-05-29) — the PCG fix has landed, but NGC 26.05 does NOT carry it

FlashInfer **0.6.12 final** released **2026-05-29** (0.6.12rc1 was May 22) and contains **the explicit fix for our PCG dynamo crash** (#3081, merged, shipped in the final tag). The tree has since moved to 0.6.13rc1/rc2 (Jun 10/17); no 0.6.13 final, no 0.7.x yet.

> ✅ **Update 2026-07-02: the trap is resolved.** NGC SGLang **26.06** now ships **FlashInfer 0.6.12** (with #3081), so a clean container pull recovers PCG. The warning below applies only to 26.04/26.05.
>
> ⚠️ **The trap (26.04/26.05):** NGC SGLang **26.05** bundles **FlashInfer 0.6.10** — *older* than 0.6.12 and **without #3081**. So the prior plan ("pull 26.05, drop `--disable-piecewise-cuda-graph`") would **re-trigger the dynamo crash**. To get the fix on this hardware you must either (a) wait for an NGC container bundling ≥0.6.12, (b) `pip install -U flashinfer-python==0.6.12` inside the 26.04/26.05 container, or (c) apply the `sitecustomize.py` monkey-patch below. Verify with `pip show flashinfer` in the actual image before assuming a version. (26.05 = SGLang 0.5.11, FlashInfer 0.6.10, CUDA 13.2.1; upstream SGLang is at 0.5.13 as of Jun 13 but none of 0.5.11–0.5.13 headline an SM121 NVFP4 fix — the real fixes are all in FlashInfer.)

**Critical fix:**

| PR | Title | Why it matters |
|----|-------|---------------|
| [#3081](https://github.com/flashinfer-ai/flashinfer/pull/3081) | `Add torch.compile-compatible custom op for fp4_quantize` | Registers `fp4_quantize` as a proper `torch.compile`-compatible custom op — exactly fix #3 from the upstream fix list above. Dynamo can now trace through it without hitting `_thread.allocate_lock`. Merged; in 0.6.12 final. **Drop `--disable-piecewise-cuda-graph` only once running FlashInfer ≥0.6.12 — NOT just because 26.05 is available.** |

**Other SM121-relevant PRs in 0.6.12rc1:**

| PR | Title | Why it matters |
|----|-------|---------------|
| [#3180](https://github.com/flashinfer-ai/flashinfer/pull/3180) | `Fix/3170 dense blockscaled sm12x` | Directly references #3170 audit; adds dense blockscaled GEMM coverage for SM12x. |
| [#3237](https://github.com/flashinfer-ai/flashinfer/pull/3237) | `perf: optimize per-token nvfp4 quantization kernel` | Direct throughput improvement on the activation-quant path that caused our A/B regression. |
| [#2885](https://github.com/flashinfer-ai/flashinfer/pull/2885) | `feat: add SM120 fmha_v2 kernels to AOT pip wheel builds` | AOT attention kernels for SM120-family, reducing JIT compile burden. |
| [#3290](https://github.com/flashinfer-ai/flashinfer/pull/3290) | `Fix [Spark unit test CI]: defer torch._dynamo.disable to avoid import-time crash in CI` | Spark-specific dynamo import fix — confirms active Spark attention in upstream CI. |

**Status of #3170 (AOT coverage audit), as of Jun 15 2026:** Still **open**, ~17 consolidated action items, actively updated. Key unresolved items confirming our A/B diagnosis: the fast b12x FP4 GEMM path still **excludes SM121** by heuristic (`is_sm120 = major==12 and minor==0` in `gemm_base.py`), so Spark falls through to slower CUTLASS/cuDNN; AOT builds `fp4_quantization_121` but the runtime **redirects `121→120f`**, wasting it; Mamba SSU missing from AOT (breaks `FLASHINFER_DISABLE_JIT` on Spark); no BF16 backend for SM121. **Prebuilt `sm121a` AOT cubins still have NOT shipped** — `flashinfer-cubin` ships ~12.7k FP4 cubins for Sm100a/100f/103a and zero sm120/121; the jit-cache wheel even blew past GitHub's 2 GiB asset limit while trying to add SM120/121 CUTLASS GEMM variants (#3257, closed via #3265). The JIT path now correctly emits `sm_121a`, so JIT NVFP4 MMA works — but the dispatch heuristic above means it often isn't selected. **#2776** (NVFP4 MoE PCG crash) also still open, untouched since Apr 14.

**Net for our regression:** #3081 restores the *prefill* win we gave up with `--disable-piecewise-cuda-graph`, but does **not** fix the *decode* regression that drove the rollback to vLLM — that needs the SM121 dispatch/AOT work in #3170, which is unfinished.

## FlashInfer 0.6.11 (2026-05-07) — SM121-relevant changes (superseded by 0.6.12)

0.6.11 was the first release with significant SM121 coverage. Key PRs for reference:

| PR | Title | Why it matters |
|----|-------|---------------|
| [#3175](https://github.com/flashinfer-ai/flashinfer/pull/3175) | `fix: align is_sm120f_supported with SM12x family semantics` | Fixes SM121 classification relative to SM120f. |
| [#3173](https://github.com/flashinfer-ai/flashinfer/pull/3173) | `fix: add sm_121 to TMEM column fallback map` | SM121 was missing from the tensor-memory fallback map. |
| [#3152](https://github.com/flashinfer-ai/flashinfer/pull/3152) | `Integrate CUTLASS Small Tile N Blockscaled GEMMs/Grouped GEMMs for SM120 and SM121` | Native blockscaled (NVFP4) GEMM for SM121 — addresses the activation-quant gap from the A/B results. |
| [#3192](https://github.com/flashinfer-ai/flashinfer/pull/3192) | `fix cudnn sm120 nan` | Fixes NaN values from cuDNN on SM120-family. |
| [#3191](https://github.com/flashinfer-ai/flashinfer/pull/3191) | `fix(sm12x): fix micro-kernel workspace sizing when routed_rows > num_local_experts` | Workspace sizing fix for SM12x MoE. |
| [#3193](https://github.com/flashinfer-ai/flashinfer/pull/3193) | `perf(moe): optimize SM120 b12x MoE short decode` | Decode throughput improvement for SM120-family. |

**Action (revised 2026-06-18):** NGC 26.05 dropped but ships FlashInfer **0.6.10**, which lacks #3081 — pulling it alone does NOT let us drop `--disable-piecewise-cuda-graph` (see the 0.6.12 section warning above). To re-test PCG: take 26.05 (or 26.04) and `pip install -U flashinfer-python>=0.6.12` (or the `sitecustomize.py` patch), then remove the flag. Expect the prefill win (~25–35% at long context) to return, but **not** the decode parity — the SM121 GEMM dispatch fix (#3170) hasn't landed, so the activation-quant tax that caused the A/B regression persists. Re-run the decode-dominated A/B before considering any switch back from vLLM.

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
