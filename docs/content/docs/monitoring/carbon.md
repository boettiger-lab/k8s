---
title: "Carbon Dashboard"
weight: 3
bookToc: true
---

# Carbon Dashboard

<https://carbon.carlboettiger.info> — the energy and carbon footprint of LLM inference
on the cluster: live GPU power draw, CO₂ per hour, and CO₂ per token, with 24 h and 7 d
averages. **One card per GPU node serving a model** — currently cirrus and nimbus.

(`carbon-cirrus.carlboettiger.info`, the old per-node name, still resolves here.)

It is a small Go service ([boettiger-lab/nimbus-carbon-api](https://github.com/boettiger-lab/nimbus-carbon-api),
image `ghcr.io/boettiger-lab/nimbus-carbon-api`) that reads Prometheus and renders both
an HTML dashboard and a JSON API. It stores nothing itself — restart it and it backfills
seven days of history from Prometheus.

```bash
curl -s https://carbon.carlboettiger.info/api/v1/carbon | python3 -m json.tool
curl -s 'https://carbon.carlboettiger.info/api/v1/carbon/timeseries?range=7d'
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

### Shared-GPU attribution

Where a node's GPUs are shared, the dashboard reports **total node GPU power** and
attributes it to that node's model as an explicit upper bound. The API flags it —
`"power_is_node_total": true` — and the card is labelled `node-total power`.

Both current nodes run this way, for different reasons:

- **cirrus** has two RTX 8000s time-sliced across vLLM, JupyterHub and MCP workloads, so
  per-GPU DCGM power genuinely cannot be split per tenant.
- **nimbus** would need it even if nothing else ran there. DCGM attributes each GPU's
  watts to whichever pod its pod-resources mapping picked, and on nimbus that is an MCP
  pod in the `default` namespace — so a namespace-scoped power query returns *nothing at
  all* for vLLM.

## Deployment

[`platform/monitoring/carbon-api.yaml`](https://github.com/boettiger-lab/k8s/blob/main/platform/monitoring/carbon-api.yaml)
— one Deployment, one hostname, for the whole cluster.

**Which nodes appear is data, not code.** The `carbon-api-nodes` ConfigMap holds a JSON
array; edit it and restart:

```json
[
  {"name": "cirrus", "namespace": "vllm", "gpu_hardware": "Quadro RTX 8000",
   "gpu_count": 2, "node_power": true},
  {"name": "nimbus", "namespace": "vllm", "gpu_hardware": "NVIDIA GB10",
   "gpu_count": 1, "node_power": true}
]
```

```bash
kubectl -n monitoring edit configmap carbon-api-nodes
kubectl -n monitoring rollout restart deployment/carbon-api
```

The node list is read once at startup, so the restart is required. thelio has a GPU but
serves no LLM, so it has no entry.

### Why every query is filtered by node *and* namespace

Both models currently serve out of the `vllm` namespace. The service used to key its
state by namespace alone, which summed nimbus's tokens into cirrus's row while cirrus's
watts stayed node-scoped — quietly *understating* cirrus's CO₂ per token whenever nimbus
was busy. Filtering and grouping on both labels is what prevents that, and it is covered
by a regression test in the service repo. (Fixed 2026-09-08,
[issue #60](https://github.com/boettiger-lab/k8s/issues/60).)

It depends on the `prometheus.io/scrape` annotations on the vLLM services in
`services/vllm/endpoints.yaml`. Those follow whichever model is live, so swapping the
served model needs no change here.
