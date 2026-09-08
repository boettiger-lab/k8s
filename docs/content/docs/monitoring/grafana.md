---
title: "Grafana"
weight: 2
bookToc: true
---

# Grafana

<https://grafana-cirrus.carlboettiger.info> — Traefik ingress, Let's Encrypt cert,
DNS from external-dns. **Login required**; anonymous access is off, because this is a
public hostname.

Admin credentials live in the `grafana-admin` Secret, created by `install.sh` with a
random password (not the chart's default, which is public knowledge):

```bash
kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

Persistence is a 2 Gi `openebs-zfs` PVC, so anything imported through the UI survives a
restart.

## Dashboards as code

The sidecar loads **any ConfigMap in the `monitoring` namespace labelled
`grafana_dashboard: "1"`**. To add a dashboard, drop another labelled ConfigMap in
`platform/monitoring/` and apply it — no clicking, and it is in git.

Four ship with the repo. All are **tuned to this cluster's metric labels**; the obvious
community dashboards (1860 Node Exporter Full, 12239 NVIDIA DCGM) assume different `job`
labels and render No Data here, which is why these exist instead:

| Dashboard | File | Shows |
|---|---|---|
| **Cluster Nodes** | `grafana-dashboard-cluster.yaml` | per-node UP/DOWN from `up{job="kubernetes-nodes"}`, plus up/down history |
| **Drive Health (SMART)** | `grafana-dashboard-smart.yaml` | NVMe wear %, temperature, spare, error counts, SATA attributes |
| **Node Host Health** | `grafana-dashboard-node.yaml` | CPU, memory, load, filesystem, physical-NIC traffic |
| **GPU (DCGM)** | `grafana-dashboard-gpu.yaml` | per-GPU utilisation, power, temperature, framebuffer |

Two details worth knowing:

- **Cluster Nodes uses `up{job="kubernetes-nodes"}` deliberately.** It stays red when a
  node is unreachable. Node-exporter metrics simply *vanish* in that case, which a naive
  panel renders as a gap rather than a failure.
- **The GPU dashboard aggregates `by (gpu, Hostname)`** to collapse DCGM's per-pod
  attribution into one series per physical GPU.

Default time range is `now-6h`. Widen it for endurance trending — the exporters have not
been running long enough for the multi-month view to be interesting yet.

## Datasource

Provisioned as code in `grafana-values.yaml`: Prometheus, uid `prometheus`, pointing at
`http://prometheus-server.monitoring.svc.cluster.local`. Dashboards reference that uid,
so a Grafana reinstall does not orphan them.
