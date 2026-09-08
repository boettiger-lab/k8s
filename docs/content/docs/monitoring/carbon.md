---
title: "Carbon Dashboard"
weight: 3
bookToc: true
---

# Carbon Dashboard

<https://carbon-cirrus.carlboettiger.info> — the energy and carbon footprint of LLM
inference on the cluster: live GPU power draw, CO₂ per hour, and CO₂ per token, with
24 h and 7 d averages.

It is a small Go service ([boettiger-lab/nimbus-carbon-api](https://github.com/boettiger-lab/nimbus-carbon-api),
image `ghcr.io/boettiger-lab/nimbus-carbon-api`) that reads Prometheus and renders both
an HTML dashboard and a JSON API. It stores nothing itself — restart it and it backfills
seven days of history from Prometheus.

```bash
curl -s https://carbon-cirrus.carlboettiger.info/api/v1/carbon | python3 -m json.tool
curl -s 'https://carbon-cirrus.carlboettiger.info/api/v1/carbon/timeseries?range=7d'
```

`/methodology` on the same host explains the arithmetic.

## How the numbers are computed

- **Power** comes from `DCGM_FI_DEV_POWER_USAGE` (dcgm-exporter), **tokens** from vLLM's
  own `/metrics`.
- **Grid intensity is a fixed constant**: 0.198 kg CO₂/kWh, the CAMX (California) eGRID
  subregion. Every node is in the same building in Berkeley, so there is nothing to look
  up per node.
- g CO₂/hr = watts × intensity. mg CO₂/token = watts × intensity × 0.2778 ÷ tokens per
  second, over prompt + generation tokens.
- **GPU power only.** Host CPU, memory, fans, and PSU losses are not in the figure, so
  treat it as a floor for the machine's true draw.

### Shared-GPU attribution on cirrus

cirrus has two RTX 8000s time-sliced across vLLM, JupyterHub and MCP workloads, so
per-GPU DCGM power cannot be split per tenant. The deployment runs with
`NODE_POWER=true`: it sums **total node GPU power** and attributes all of it to vLLM as
an explicit upper bound. The API flags this — `"power_is_node_total": true` — and the
dashboard says so. A single-GPU, single-tenant node like nimbus does not need it.

## Deployment

[`platform/monitoring/cirrus-carbon-api.yaml`](https://github.com/boettiger-lab/k8s/blob/main/platform/monitoring/cirrus-carbon-api.yaml).
The service is parameterised entirely by environment (`NAMESPACE`, `NODE_NAME`,
`GPU_HARDWARE`, `GPU_COUNT`, `NODE_POWER`), so the same image serves any node.

It depends on the `prometheus.io/scrape` annotations on the vLLM services in
`services/vllm/endpoints.yaml`. Those follow whichever model is live, so swapping the
served model needs no change here.

## Known limitation: it only describes cirrus

**The dashboard currently covers one node, and mixes in a second one's traffic.**

nimbus serves its own model at `vllm-nimbus.carlboettiger.info`, and its footprint is
not reported anywhere. Worse, both models run in the `vllm` namespace and the service
keys its vLLM queries by *namespace*, so nimbus's tokens are summed into cirrus's row
while cirrus's watts stay node-filtered — which understates cirrus's CO₂ per token
whenever nimbus is busy.

The old per-node nimbus deployment (`carbon-nimbus.carlboettiger.info`) is preserved as
[`platform/monitoring/nimbus-carbon-api.yaml`](https://github.com/boettiger-lab/k8s/blob/main/platform/monitoring/nimbus-carbon-api.yaml),
archived and deliberately not installed: one Deployment and one hostname per machine is
the wrong shape now that the machines are one cluster.

The fix — filter by the `node` label, then decide between a per-node instance and a
single cluster-wide API with a per-node breakdown — is tracked in
[issue #60](https://github.com/boettiger-lab/k8s/issues/60).

thelio has a GPU but runs no LLM, so it has no carbon row and needs none.
