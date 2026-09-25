---
title: "Carbon Dashboard"
weight: 3
bookToc: true
---

# Carbon Dashboard

<https://carbon.carlboettiger.info> — the energy, carbon and service quality of LLM
inference on the cluster. **One card per served model**, with a global toggle between
**Live** (what it is doing now) and **Aggregate** (its record over 24 h, 7 d or 15 d).
A model that is not running keeps its card and shows its aggregate record, labelled with
when it was last seen — so a model scaled to 0 still says what it cost and how fast it
was.

Each card carries power, CO₂/hour and CO₂/token, plus decode speed, TTFT, end-to-end and
queue-time percentiles, KV- and prefix-cache use, speculative-decoding acceptance,
uptime, tokens per request and an availability strip.

(`carbon-cirrus.carlboettiger.info`, the old per-node name, still resolves here.)

It is a small Go service ([boettiger-lab/nimbus-carbon-api](https://github.com/boettiger-lab/nimbus-carbon-api),
image `ghcr.io/boettiger-lab/nimbus-carbon-api`) that reads Prometheus and renders both
an HTML dashboard and a JSON API. It stores nothing itself: live state is re-read every
30 s and aggregates every 5 min, straight from Prometheus, so a restart loses nothing.
History is bounded by Prometheus retention — **15 days**.

```bash
curl -s https://carbon.carlboettiger.info/api/v1/models | jq '.models[] | {id, status}'
curl -s 'https://carbon.carlboettiger.info/api/v1/carbon/timeseries?range=7d'
```

`/methodology` on the same host explains the arithmetic.

## How the numbers are computed

- **Power** comes from `DCGM_FI_DEV_POWER_USAGE` (dcgm-exporter), **tokens** from vLLM's
  own `/metrics`.
- **Grid intensity is a fixed constant**: 0.198 kg CO₂/kWh, the CAMX (California) eGRID
  subregion. Every node is in the same building in Berkeley, so there is nothing to look
  up per node.
- **Models are discovered, not listed.** Anything exporting vLLM metrics on a configured
  node is a model, keyed `model_name@node` (`qwen@nimbus`, `deepseek-v4-flash@nimbus2`).
- **Power is node-total, attributed by time.** A node's GPU power belongs to the model
  serving there at that minute. GPU time serving no LLM — cirrus's speech-to-text — is
  counted nowhere, including the cumulative chart.
- **Aggregates are ratios of totals**, never averages of ratios: energy is attributed
  power integrated over the window at 1-minute resolution, divided by tokens.
  **All-in** CO₂/token counts every serving joule, idle hosting included; **working**
  CO₂/token counts only minutes above 5 tok/s.
- **Latency percentiles are withheld below 20 completed requests** — on bursty
  single-user traffic a p95 of two requests is not a statistic.
- g CO₂/hr = watts × intensity. mg CO₂/token = joules × intensity ÷ 3.6 ÷ tokens, over
  prompt + generation tokens.
- **GPU power only.** Host CPU, memory, fans, and PSU losses are not in the figure, so
  treat it as a floor for the machine's true draw.

### Why not per-pod power

DCGM attributes each GPU's watts to whichever pod its pod-resources mapping picked. On
cirrus the two RTX 8000s are time-sliced across vLLM, JupyterHub and MCP workloads, so
that split is meaningless; on nimbus it names an MCP pod in `default`, so a vLLM-scoped
query returns *nothing at all*. Node-total power attributed by serving time avoids both.
On a shared node it is an upper bound for the model.

### Tensor-parallel models

DeepSeek-V4-Flash runs TP2 across nimbus2 and nimbus4. Only the head exports vLLM
metrics, so its card is keyed to nimbus2 — but both ranks draw power. nimbus2's entry
lists `"power_hosts": ["nimbus2", "nimbus4"]`, and nimbus4's watts are summed into the
head's before attribution. A host may be claimed by only one node, so nothing is counted
twice.

## Deployment

[`platform/monitoring/carbon-api.yaml`](https://github.com/boettiger-lab/k8s/blob/main/platform/monitoring/carbon-api.yaml)
— one Deployment, one hostname, for the whole cluster.

**The config is data, not code.** The `carbon-api-nodes` ConfigMap holds two files:

- `nodes.json` — every node that serves models, with its hardware and `power_hosts`
  (defaults to the node itself; list every rank of a tensor-parallel model):

  ```json
  [
    {"name": "cirrus",  "gpu_hardware": "Quadro RTX 8000", "gpu_count": 2},
    {"name": "nimbus",  "gpu_hardware": "NVIDIA GB10",     "gpu_count": 1},
    {"name": "nimbus2", "gpu_hardware": "NVIDIA GB10",     "gpu_count": 2,
     "power_hosts": ["nimbus2", "nimbus4"]},
    {"name": "nimbus3", "gpu_hardware": "NVIDIA GB10",     "gpu_count": 1}
  ]
  ```

- `models.json` — optional display names and one-line descriptions, keyed by served
  model name, or `model@node` where a name is reused (`qwen` has been more than one
  checkpoint on nimbus). A model with no entry still appears, under its served name.

```bash
kubectl apply -f platform/monitoring/carbon-api.yaml   # bump checksum/config first
# or, after editing in place:
kubectl -n monitoring rollout restart deployment/carbon-api
```

Both are read once at startup, so the restart is required. **A new model needs no
config at all** — it appears once it serves; add a `models.json` entry only for a
friendlier name. A **new node** does need a `nodes.json` entry, or its models are
ignored.

### Why every query is filtered by node *and* namespace

Every model serves out of the `vllm` namespace. The service once keyed its state by
namespace alone, which summed nimbus's tokens into cirrus's row while cirrus's watts
stayed node-scoped — quietly *understating* cirrus's CO₂ per token. Filtering and
grouping on both labels prevents that, and it is covered by a regression test in the
service repo. (Fixed 2026-09-08,
[issue #60](https://github.com/boettiger-lab/k8s/issues/60).)

It depends on the `prometheus.io/scrape` annotations on the vLLM services in
`services/vllm/endpoints.yaml` (and the TP2 pair's own Service in
`deepseek-v4-flash-gb10pair.yaml`). Those follow whichever model is live, so swapping
the served model needs no change here.
