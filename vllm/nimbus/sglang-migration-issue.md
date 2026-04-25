# Migrate Nemotron to SGLang once NGC 26.04 ships FlashInfer 0.6.8

## Background

We successfully deployed Nemotron-3-Super-120B-A12B-NVFP4 on SGLang (`nvcr.io/nvidia/sglang:26.03-py3`) with native FlashInfer FP4 GEMM on the DGX Spark (GB10/SM121). Tool calling and prefix caching worked correctly. However the deployment crashes mid-request with:

```
torch.AcceleratorError: CUDA error: an illegal instruction was encountered
```

This is a known FlashInfer bug on SM121 — the `flashinfer_cudnn` FP4 backend (auto-selected on SM12x) emits SM100-specific instructions (`tcgen05`) that SM121 does not implement. The CUTLASS fix for SM121 landed in January 2026 (https://github.com/NVIDIA/cutlass/issues/2947), and FlashInfer 0.6.8 incorporated it on April 16 2026 with SM121-specific MoE and GEMM kernels using the correct `mma.*` instruction family. NVIDIA announced this in https://forums.developer.nvidia.com/t/nvfp4-performance-update/367781 on April 24 2026.

The NGC SGLang 26.03 container ships FlashInfer 0.6.6, one version short of the fix. No ARM64 wheels exist for FlashInfer 0.6.8 on PyPI so pip-upgrading inside the container is not viable. **We are reverting to vLLM+Marlin as a stable interim solution and will re-migrate to SGLang once NGC 26.04 ships.**

## What was working in SGLang (26.03)

- `--tool-call-parser qwen3_coder` — fully supported, drop-in from vLLM
- `--reasoning-parser` — NOT needed; app (geo-agent) only reads `tool_calls` and `content`, never `reasoning_content`. The `gpt-oss` reasoning parser silently swallows tool calls (bug: `tool_calls: null` with 47 consumed tokens). **Do not add a reasoning parser.**
- `--mamba-scheduler-strategy no_buffer` — required; `extra_buffer` asserts on NemotronHForCausalLM
- `--fp4-gemm-backend auto` auto-selects `flashinfer_cudnn` on SM12x — **this is the crashing backend**
- `--enable-metrics` — exposes Prometheus metrics at `/metrics`
- 7 GPU slices at `--mem-fraction-static 0.875` fits the model comfortably
- NGC pull secret `ngc-pull` is already created in the `default` namespace

## What to do when NGC 26.04 drops

1. Check FlashInfer version in the new container:
   ```bash
   kubectl exec <pod> -- python3 -c "import flashinfer; print(flashinfer.__version__)"
   ```
   Proceed only if ≥ 0.6.8.

2. Apply `deploy-nemotron-sglang.yaml` (already in repo, ready to go).

3. Verify the FP4 backend selected at startup:
   ```bash
   kubectl logs <pod> | grep "fp4-gemm-backend"
   ```
   Should still say `flashinfer_cudnn`. With 0.6.8 this should no longer crash.

4. Run a multi-tool agentic query end-to-end and confirm no 502s.

5. If still crashing, try `--fp4-gemm-backend flashinfer_cutlass` — but note SGLang issue #20775 suggests this flag may not fully disable DeepGemm. Monitor closely.

## SGLang advantages over vLLM on GB10 (motivation to migrate back)

- **1.32× faster prefill at batch size 1** — critical since our workload is ~99% input tokens (agentic tool-calling)
- Native FlashInfer attention backend vs vLLM's TRITON_ATTN fallback
- Better prefix cache eviction (RadixAttention LRU)
- Prometheus metrics built-in via `--enable-metrics`
- No Marlin env var workarounds needed once 0.6.8 kernels are stable

## Key references

- FlashInfer 0.6.8 release: https://github.com/flashinfer-ai/flashinfer/releases/tag/v0.6.8
- CUTLASS SM121 fix (closed Jan 11 2026): https://github.com/NVIDIA/cutlass/issues/2947
- NVFP4 performance update (Apr 24 2026): https://forums.developer.nvidia.com/t/nvfp4-performance-update/367781
- SGLang DeepGemm flag bug: https://github.com/sgl-project/sglang/issues/20775
- Mamba illegal instruction on SM121: https://github.com/vllm-project/vllm/issues/37431
- DGX Spark SGLang tracking issue: https://github.com/sgl-project/sglang/issues/11658
- NGC SGLang release notes: https://docs.nvidia.com/deeplearning/frameworks/sglang-release-notes/index.html
