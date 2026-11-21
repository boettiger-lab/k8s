---
name: gb10-model-bringup
description: Stand up, screen and benchmark a new LLM on the nimbus GB10 fleet (one box or a TP2 pair) with vLLM. Use when asked to try, serve, test, benchmark or swap a model on nimbus/nimbus2/nimbus3/nimbus4, to find a recipe or quant (NVFP4, FP8, EXL3) for a GB10/DGX Spark, or to retire a model from a GB10.
---

# Bring up a model on the GB10s

This skill is a checklist. `ops/` is the cluster-ops repo nested in this clone. The facts live in the files it points to, so read those files;
don't rely on this summary. When a step teaches something new, write it into that file
(or the manifest header), not here.

## 0. Know the current state (live, not from notes)

```bash
kubectl -n vllm get deploy -o wide          # what is at 1, and on which node
kubectl get pods -A -o wide | grep nimbus   # notebooks / jobs on the target boxes
gh pr list -R boettiger-lab/k8s             # someone may already be mid-change
```

- Production: the DeepSeek TP2 pair on nimbus2+4 (`vllm-nimbus2`). Never touch it without
  Carl saying so.
- Check `ops/tp2-benchmark.md` (scoreboard + "Re-benchmark plan") and cluster-ops#93 for
  rotations in flight on nimbus3.
- Freeing a box = scale its model to 0 live AND a PR that sets `replicas: 0` (repo must
  match live). Use a git worktree from fresh `origin/main`; never `git checkout` in the
  shared clone.

## 1. Research before choosing a checkpoint

Carl's bar (see the `feedback_llm_eval_criteria` memory): single-stream decode only,
context >= 200K, glen `numeric` decides quality. Look up, with URLs:

- The HF model card: architecture (MoE? MLA/DSA? hybrid Mamba? MTP layers?), native
  context, the chat template, the recommended vLLM/SGLang version and the parser flags.
- Quants: `nvidia/*-NVFP4` first (has a Spark recipe on the card more often than not),
  then RedHatAI / community NVFP4, FP8. EXL3 means TensorFold or exllamav3, not vLLM. Read
  the TensorFold verdict in `services/vllm/deepseek-v41-tensorfold-nimbuspair.yaml`
  before choosing that path.
- GB10/Spark recipes (record which one you replicate in the manifest header):
  - NVIDIA model cards ("DGX Spark" sections) and the NVIDIA DGX Spark dev forum
  - `github.com/NVIDIA/local-ai-inference-recipes`: NVIDIA's own Spark recipes
  - `github.com/eugr/spark-vllm-docker`: community vLLM images and launch scripts for Spark
  - `recipes.vllm.ai/<org>/<model>`: vLLM's per-model flags (tool/reasoning parsers, MTP)
  - `github.com/Anemll/dspark-vllm-gx10`: the DeepSeek pair recipe (image, `mp` backend)
  - `github.com/blazux/qwen3.8-Flash-DGX`: Flash-Next PLE-mmap image
  - `github.com/0rand/DeepSeek-V4.1-Flash-1017-EXL3-TensorFold-2x-DGX-Spark`
  - drafters: `z-lab/*-DFlash`, `nvidia/*-DSpark`
  - r/LocalLLaMA threads for real Spark tok/s
- Earlier lab results: the `ops/tp2-benchmark.md` scoreboard and the `services/vllm/*.yaml`
  headers. Fetch the web in parallel subagents; say "not found" rather than guess.

## 2. Fit check (one box or two)

Read `services/vllm/dgx-spark-memory.md` and `ops/gb10-fleet-onboarding.md` →
"Non-obvious facts". The essentials:

- 121.6 GiB MemTotal per box. Budget from `MemFree` after a cache drop.
- After warm-up, free memory must stay clear of the low watermark (4.4 GiB). Weights,
  KV, CUDA context, graphs, warm-up and any vision tower all count against it.
- Whether `--gpu-memory-utilization` binds is per model and per build. Read the KV pool
  from the logs (`grep -iE "Model loading took|Available KV cache|KV cache size"`). For
  hybrid Mamba models with a drafter, the pool varies non-monotonically with the draft
  length.
- Host-side structures (PLE tables, Engram n-grams, a page-cache-buffered loader) are
  outside every vLLM flag.
- Two boxes: TP2 over CX-7, following `deepseek-v4-flash-gb10pair.yaml` (head + worker,
  start order in its header) and `ops/network-topology.md`.

A model of uncertain fit (> ~100 GiB, a new engine, or TP2) is NOT just applied. Follow
the node safety protocol (`feedback_node_safety_protocol` memory): drop caches
(`services/vllm/drop-caches-nimbus.yaml`), clear any stale watermark boost, start under a
`kubectl debug --profile=sysadmin` watcher with the abort triggers from
gb10-fleet-onboarding.md, one node first. Get Carl's OK on the protocol.

## 3. Weights onto the node

- Download on the target node into `/home/cboettig/.cache/huggingface` (the hostPath every
  manifest mounts), e.g. with a short Job or `kubectl debug`. HF token: secret
  `vllm/huggingface-token`.
- Xet-layout repos have their bytes in the shared `hub/blobs/`: `du` on the repo lies.
  Verify with the three checks in gb10-fleet-onboarding.md "HF cache layout". To copy
  between boxes, rsync `blobs/` first, then the repo skeleton, over the fabric.
- Label the node `vllm-cache/<model>=true` if the manifest selects on it.

## 4. Manifest

Copy the closest existing manifest in `services/vllm/` (single box:
`nemotron-lightning-nimbus.yaml` or `qwen36-35b-a3b-nimbus.yaml`; pair:
`deepseek-v4-flash-gb10pair.yaml`). Keep its conventions:

- `strategy: Recreate`, `priorityClassName: llm-serving`, the `dedicated=gb10` toleration,
  `runtimeClassName: nvidia`, `nvidia.com/gpu: 8`, 108Gi memory request (scheduler
  accounting; the header explains why).
- A `nodeSelector` pin. Exactly one Deployment per `vllm-endpoint: <node>` label, which is
  what `endpoints.yaml` routes (`vllm-<node>.carlboettiger.info`).
- Args as a bash array (comments inside `\` continuations truncate the command).
- `--max-num-seqs 1`, prefix caching + chunked prefill, the tool + reasoning parsers from
  the card, `--override-generation-config '{"max_new_tokens": 32768}'`, and a long
  readiness probe.
- Pin the image by exact tag (or by digest for a custom image in ghcr). Build arm64
  images per `ops/` notes (buildkit OCI worker; not hosted runners for big CUDA images).
- A header recording the recipe source, what was measured, and why each odd flag is there.

For a quick decode screen of several variants, `ops/scripts/gb10-speedtest/speedtest.py`
serves one variant as `speedtest-<node>` (add it to its table `V`) and runs
`bench-decode.py` in the pod. Delete the Deployment afterwards.

## 5. Validate

1. `/v1/models` answers at `https://vllm-<node>.carlboettiger.info` (API key: secret
   `vllm/vllm-api-key`).
2. A tool call and a reasoning response parse cleanly. A truncated tool call is usually
   the token budget, not the parser (README "Operational notes").
3. Prefix caching gives correct answers on hybrid models (README "Things that are easy to
   get wrong"); test with prompts of tens of thousands of tokens.
4. Decode screen: mean tok/s and tok/s after a ~110K prompt.
5. glen `numeric`: an Armada job in Carl's `cirrus`-context queue (`armada-jobs`
   namespace), temperature 0, `MCP_URL=https://duckdb-mcp.carlboettiger.info/mcp`; grade
   and `publish_run.py` in a pod. Never run podman, DuckDB or glen on the cirrus host.

## 6. Record and land

- Scoreboard row (and the decode-screen row) in `ops/tp2-benchmark.md` (cluster-ops repo,
  its own PR).
- Measured numbers in the manifest header; a row in `services/vllm/README.md` → Layout.
- Metrics: endpoint Services are scraped already; a new node or a TP pair needs care with
  carbon-api `nodes.json` (a pair's second rank must NOT be listed).
- PR in k8s so the repo matches live: no Claude attribution anywhere.
- Retiring a model: replicas 0 + a VERDICT line in its header, not deletion.
