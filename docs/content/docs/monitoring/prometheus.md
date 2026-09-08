---
title: "Prometheus & Exporters"
weight: 1
bookToc: true
---

# Prometheus & Exporters

The metrics store and the things that feed it. Config lives in
[`platform/monitoring/`](https://github.com/boettiger-lab/k8s/tree/main/platform/monitoring);
`install.sh` applies the whole stack.

## Prometheus

Helm chart `prometheus-community/prometheus` (pinned 29.14.0), namespace `monitoring`.

- **Retention**: 15 days, and a hard `retentionSize: 40GB` second brake. A full data
  volume stops compaction, which pins everything in the head — that is how RAM ran
  away once before.
- **Storage**: 100 Gi on `openebs-zfs`, so the size is actually enforced (`local-path`
  would not).
- **No ingress.** Query it through a port-forward:

```bash
kubectl -n monitoring port-forward svc/prometheus-server 9090:80
curl -s --get --data-urlencode 'query=up' http://localhost:9090/api/v1/query | python3 -m json.tool
```

In-cluster URL: `http://prometheus-server.monitoring.svc.cluster.local`

### Cardinality guards — do not remove these

Three settings in `prometheus-values.yaml` exist because each one, on its own, was
enough to blow up Prometheus's memory on this cluster:

1. **node-exporter filesystem excludes.** Without them the filesystem collector
   reports every kubelet pod-volume bind mount and every containerd sandbox `/shm`
   — 325k distinct `mountpoint` values on cirrus alone, × ~8 `node_filesystem_*`
   metrics, all churning to brand-new series on every pod restart.
2. **Explicit `node` label on the node jobs.** The stock `kubernetes-nodes` and
   `kubernetes-nodes-cadvisor` jobs `labelmap` all 127 node labels — including 88
   NFD `feature.node.kubernetes.io/*` labels — onto every series. That measured
   0.5–1.3 GB of label memory *per NFD label*.
3. **cAdvisor allowlist.** Raw cAdvisor output is ~2M series here. Only a handful of
   `container_*` metrics are kept, and the two highest-cardinality labels (`id`,
   `name`) are dropped as redundant with namespace/pod/container.

Unused scrape jobs (`kubernetes-services`, the `*-slow` variants, pushgateway) are
disabled — all had zero targets.

## How things get scraped

Anything with `prometheus.io/scrape: "true"` on the pod or service is picked up. That
is how vLLM's `/metrics` reaches Prometheus, via annotations on the vLLM services in
[`services/vllm/endpoints.yaml`](https://github.com/boettiger-lab/k8s/tree/main/services/vllm) —
which follow whichever model is live, so the carbon dashboard does not need updating
when a model is swapped.

## dcgm-exporter (GPU)

Chart `gpu-helm-charts/dcgm-exporter` 4.8.2, DaemonSet on every GPU node.

**Tolerations are the whole trick.** The nodes are tainted differently — cirrus is the
control plane, thelio is jupyter-only (`hub.jupyter.org/dedicated=user:NoSchedule`),
nimbus is `dedicated=nimbus:NoSchedule` — and GPU telemetry is one of the few things we
*do* want everywhere. This is **one YAML list**: a second `tolerations:` key does not
append, it replaces. Miss one node and that node's GPU metrics silently never arrive;
the dashboards still render and look fine.

Key metrics: `DCGM_FI_DEV_POWER_USAGE` (watts), `DCGM_FI_DEV_GPU_UTIL`,
`DCGM_FI_DEV_FB_USED`/`_FREE`, temperatures.

> **GB10 (nimbus) nuance:** on unified memory, `DCGM_FI_DEV_FB_FREE` /
> `DCGM_FI_DEV_FB_USED` and the memory-clock fields report `N/A`. Expected, not a
> broken exporter — there is no discrete framebuffer to report. `DCGM_FI_DEV_POWER_USAGE`
> does work, which is what the carbon dashboard needs.

## node-exporter (host)

Ships with the Prometheus chart, on every node, standard `:9100`. (It sat on `:9101`
for a while to dodge armada-pulsar's own node-exporter; armada came down 2026-07-11 and
freed the port.)

## smartctl-exporter (drives)

[`smartctl-exporter.yaml`](https://github.com/boettiger-lab/k8s/blob/main/platform/monitoring/smartctl-exporter.yaml)
— a **privileged** DaemonSet running `smartctl` on each node, metrics on `:9633`.
Privileged is required for raw device access; a deliberate tradeoff for a DaemonSet
that lands on the control plane.

It complements host `smartd` rather than replacing it: `smartd` alerts on *failures*,
these metrics *trend the slow endurance climb* it cannot see (cirrus's root QLC drive is
already ~70% of its write endurance used).

```promql
smartctl_device_percentage_used                      # NVMe endurance used (%)
smartctl_device_available_spare                      # vs _available_spare_threshold
smartctl_device_temperature{temperature_type="current"}
smartctl_device_media_errors
smartctl_device_smart_status                         # 1 = PASS
```

Same toleration caveat as dcgm-exporter — check it is actually running everywhere:

```bash
kubectl -n monitoring get ds
kubectl -n monitoring get pods -o wide | grep exporter
```

`DESIRED` counts below the node count mean a taint is not tolerated, not that the
exporter crashed.

> **nimbus has no SMART data.** The upstream image publishes release tags for
> linux/amd64 only (just the floating `master` tag is multi-arch), so the DaemonSet
> carries an explicit `nodeSelector: kubernetes.io/arch: amd64` — on arm64 it would
> only ImagePullBackOff. Tracked in
> [issue #61](https://github.com/boettiger-lab/k8s/issues/61); check that drive by hand
> with `smartctl -a /dev/nvme0` in the meantime.
