# monitoring

Minimal Prometheus + dcgm-exporter stack that feeds GPU power and vLLM token
metrics to a carbon/performance dashboard. The same charts + values apply to
each cluster (they are cluster-agnostic); the carbon-api on top is configured
per node.

- **nimbus** (single GB10): `nimbus-carbon-api` (see
  `boettiger-lab/nimbus-carbon-api` and
  `docs/superpowers/specs/2026-07-04-nimbus-carbon-api-design.md`),
  live at <https://carbon-nimbus.carlboettiger.info>.
- **cirrus** (two RTX 8000s, time-sliced across vllm/jupyter/mcp):
  `cirrus-carbon-api.yaml` in this directory, live at
  <https://carbon-cirrus.carlboettiger.info>. It runs the *same* image, just
  parameterized by env (`NAMESPACE=vllm`, `NODE_NAME=cirrus`, `GPU_COUNT=2`,
  `NODE_POWER=true`).

## Install

    cd monitoring && ./install.sh          # Prometheus + dcgm-exporter (per cluster)
    kubectl apply -f cirrus-carbon-api.yaml # cirrus only: the dashboard

The cirrus dashboard also needs the `prometheus.io/scrape` annotations on
`vllm-qwen3-6-service` (see `../vllm/cirrus/deploy-qwen3-6.yaml`) so Prometheus
scrapes vLLM's `/metrics`.

## Shared-GPU power attribution (cirrus)

cirrus has two physical GPUs time-sliced across several namespaces, so DCGM
per-GPU power cannot be split per tenant. `cirrus-carbon-api` runs with
`NODE_POWER=true`: it sums **total node GPU power** and attributes it to the
vLLM namespace as an explicit upper bound (the API/dashboard flag this via
`power_is_node_total=true`). nimbus (one GPU, one model at a time) does not
need this.

## Query

    kubectl -n monitoring port-forward svc/prometheus-server 9090:80
    curl -s 'http://localhost:9090/api/v1/query?query=up' | python3 -m json.tool

Prometheus URL in-cluster: `http://prometheus-server.monitoring.svc.cluster.local`

## Metrics

- `DCGM_FI_DEV_POWER_USAGE` — GPU power draw in watts (from dcgm-exporter).
  Note: on GB10's unified-memory architecture, `DCGM_FI_DEV_FB_FREE` /
  `DCGM_FI_DEV_FB_USED` and memory-clock fields report `N/A` — expected,
  not a bug.

## Carbon dashboard

Consumed by [nimbus-carbon-api](https://github.com/boettiger-lab/nimbus-carbon-api),
live at <https://carbon-nimbus.carlboettiger.info>.
