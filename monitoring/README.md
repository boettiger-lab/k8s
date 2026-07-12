# monitoring

Prometheus-based stack. Originally just dcgm-exporter + vLLM `/metrics` feeding a
carbon/performance dashboard; **extended 2026-07-11** with `smartctl-exporter`
(per-drive SMART), `node-exporter` (host CPU/mem/disk, on `:9101` to dodge
armada's `:9100`), and **Grafana** for drive-health / node / GPU dashboards. The
charts + values are cluster-agnostic; the carbon-api on top is configured per node.

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

## Grafana (drive health / node / GPU)

Live at <https://grafana-cirrus.carlboettiger.info> (Traefik ingress + LE cert,
external-dns). Login required (anonymous off). Admin creds live in the
`grafana-admin` Secret, created by `install.sh` with a **random** password (not
the chart's insecure default — this is a public ingress). Retrieve it:

    kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo

- **Datasource** (Prometheus, uid `prometheus`) is provisioned as code in
  `grafana-values.yaml`.
- **Dashboards as code:** any ConfigMap in `monitoring` labelled
  `grafana_dashboard: "1"` is auto-loaded by the sidecar. Three ship here, all
  **tuned to this cluster's metric labels so they show data** — the community
  dashboards 1860 (node) / 12239 (DCGM) assume different `job` labels and render
  No Data:
  - `grafana-dashboard-smart.yaml` — **Drive Health (SMART)**: NVMe wear %, temp,
    spare, errors, SATA attributes.
  - `grafana-dashboard-node.yaml` — **Node Host Health**: CPU, memory, load,
    filesystem, physical-NIC network.
  - `grafana-dashboard-gpu.yaml` — **GPU (DCGM)**: per-GPU util, power, temp,
    framebuffer (aggregated `by (gpu, Hostname)` to collapse pod attribution).
  - Default time range is `now-6h` (exporters are young; widen for long-term
    wear trending). Add more by dropping another labelled ConfigMap.

node-exporter runs on the standard `:9100`. (It was briefly on `:9101` to dodge
armada-pulsar's node-exporter; armada was torn down 2026-07-11, freeing 9100.)

## Drive health (SMART)

`smartctl-exporter.yaml` — a **privileged** DaemonSet that runs `smartctl` on
every node and exposes SMART metrics on `:9633` (scraped via pod annotations,
same as dcgm-exporter). Complements host `smartd`: smartd alerts on *failures*,
these metrics *trend the slow endurance climb* smartd can't see (e.g. cirrus root
QLC ~70% used). Useful queries:

- `smartctl_device_percentage_used` — NVMe endurance used (%).
- `smartctl_device_available_spare` vs `_available_spare_threshold` — NVMe spare.
- `smartctl_device_temperature{temperature_type="current"}` — temp (°C).
- `smartctl_device_media_errors`, `smartctl_device_smart_status` (1 = PASS).

`smartctl-exporter` needs `privileged: true` for raw device access — a deliberate
tradeoff for a control-plane DaemonSet.

## Carbon dashboard

Consumed by [nimbus-carbon-api](https://github.com/boettiger-lab/nimbus-carbon-api),
live at <https://carbon-nimbus.carlboettiger.info>.
