# nimbus monitoring

Minimal Prometheus + dcgm-exporter stack for nimbus (single GB10 node).
Feeds GPU power and vLLM token metrics to `nimbus-carbon-api`
(see `boettiger-lab/nimbus-carbon-api` and
`docs/superpowers/specs/2026-07-04-nimbus-carbon-api-design.md`).

## Install

    cd monitoring && ./install.sh

## Query

    kubectl -n monitoring port-forward svc/prometheus-server 9090:80
    curl -s 'http://localhost:9090/api/v1/query?query=up' | python3 -m json.tool

Prometheus URL in-cluster: `http://prometheus-server.monitoring.svc.cluster.local`

## Metrics

- `DCGM_FI_DEV_POWER_USAGE` — GPU power draw in watts (from dcgm-exporter).
  Note: on GB10's unified-memory architecture, `DCGM_FI_DEV_FB_FREE` /
  `DCGM_FI_DEV_FB_USED` and memory-clock fields report `N/A` — expected,
  not a bug.
