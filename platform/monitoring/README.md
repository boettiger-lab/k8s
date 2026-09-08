# monitoring

Prometheus-based stack. Originally just dcgm-exporter + vLLM `/metrics` feeding a
carbon/performance dashboard; **extended 2026-07-11** with `smartctl-exporter`
(per-drive SMART), `node-exporter` (host CPU/mem/disk), and **Grafana** for
drive-health / node / GPU dashboards.

Carbon dashboard: **one deployment for the whole cluster**, one card per GPU node,
live at <https://carbon.carlboettiger.info> (`carbon-cirrus.carlboettiger.info` still
resolves there). `carbon-api.yaml` here; the node list is the `carbon-api-nodes`
ConfigMap, read once at startup -- edit it and `rollout restart`.

This replaced the per-node deployments (`cirrus-carbon-api.yaml` and the archived
`nimbus-carbon-api.yaml`) on 2026-09-08. They keyed state by namespace, which was fine
while the machines were separate clusters and wrong once they were one: both models
serve out of `vllm`, so nimbus's tokens landed in cirrus's row while cirrus's watts
stayed node-scoped, understating cirrus's CO2/token. Every vLLM query is now filtered
and grouped by node AND namespace (issue #60).

## Install

    cd platform/monitoring && ./install.sh   # Prometheus + dcgm-exporter + Grafana
    kubectl apply -f carbon-api.yaml         # the carbon dashboard

The dashboard also needs the `prometheus.io/scrape` annotations on the vLLM services
(see `../../services/vllm/endpoints.yaml`) so Prometheus scrapes vLLM's `/metrics`.

## Shared-GPU power attribution

Nodes with `node_power: true` report TOTAL node GPU power, attributed to that node's
model as an explicit upper bound (`power_is_node_total=true` in the API, labelled on
the card). Both current nodes need it:

- **cirrus**: two GPUs time-sliced across vllm/jupyter/mcp -- per-tenant power is not
  measurable.
- **nimbus**: DCGM attributes the GB10's watts to whichever pod the pod-resources
  mapping picked (currently an MCP pod in `default`), so a namespace-scoped power query
  returns nothing at all for vLLM.

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
  - `grafana-dashboard-cluster.yaml` — **Cluster Nodes**: per-node UP/DOWN via
    `up{job="kubernetes-nodes"}` (stays red when a node is unreachable, unlike
    node-exporter metrics that just vanish) + up/down history.
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

**amd64 only.** Upstream publishes release tags for linux/amd64 alone (only the
floating `master` tag is multi-arch), so the DaemonSet pins
`nodeSelector: kubernetes.io/arch: amd64`. arm64 nimbus therefore has no SMART
metrics -- with the toleration but without the selector it just ImagePullBackOffs
("no match for platform in manifest"). Issue #61.

## Carbon dashboard

[nimbus-carbon-api](https://github.com/boettiger-lab/nimbus-carbon-api) (the name
predates it covering more than nimbus), deployed here as `carbon-api.yaml`.
Web docs: `docs/content/docs/monitoring/carbon.md`.
