---
title: "Model serving"
weight: 4
---

# Model serving

## LLMs

Models are served with [vLLM](https://github.com/vllm-project/vllm), one model
per machine, on the GB10 pool.

- **Endpoints are named after machines, not models:**
  `vllm-<machine>.carlboettiger.info`. Swapping the model on a machine leaves
  the URL unchanged for clients, and clients find out what is served from
  `/v1/models`. Each model directory sets its own served name.
- **One Deployment per model, scaled to 0 when not in use.** A machine's
  Ingress follows a label (`vllm-endpoint`) on the running pod. Switching
  models means scaling one Deployment down and another up.
- **Models too big for one machine** run with tensor parallelism across two
  GB10s joined by a direct link. They appear as one endpoint.
- GPU deployments use the `Recreate` strategy. A rolling update would need a
  second copy of the model's GPU memory, which isn't there.
- Model weights are cached on each machine's local disk. Nothing else is
  stored on an `llm`-pool machine.

The manifests are in
[`services/vllm/`](https://github.com/boettiger-lab/k8s/tree/main/services/vllm).

## Speech-to-text

[speaches](https://github.com/speaches-ai/speaches) serves OpenAI's
transcription API from the workstation GPUs. It can hold several
speech-recognition models at once and loads them on demand, so one endpoint
serves Whisper and Parakeet families side by side.

## Access

Every model endpoint checks a shared bearer token. There is no gateway or
per-user key: the endpoints are for lab use, and keys come from an admin.
