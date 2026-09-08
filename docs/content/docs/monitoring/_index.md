---
title: "Monitoring"
weight: 3
bookCollapseSection: false
---

# Monitoring

What the cluster watches, and where to look at it.

Everything lives in the `monitoring` namespace and is installed by
[`platform/monitoring/install.sh`](https://github.com/boettiger-lab/k8s/tree/main/platform/monitoring).
Prometheus is the single metrics store; Grafana and the carbon dashboard are two
different front ends onto it.

| | Where | What it shows |
|---|---|---|
| [**Grafana**](grafana) | <https://grafana-cirrus.carlboettiger.info> | drive health (SMART), node host health, GPU utilisation, node up/down |
| [**Carbon dashboard**](carbon) | <https://carbon-cirrus.carlboettiger.info> | LLM inference power draw, CO₂/hour, CO₂ per token |
| [**Prometheus**](prometheus) | in-cluster only | the metrics themselves, 15 d retention |

Grafana is on a public ingress and requires a login. Prometheus has no ingress —
reach it with a port-forward.

## What is collected

- **GPU** — `dcgm-exporter` on every GPU node (cirrus, thelio, nimbus).
- **Host** — `node-exporter` on every node: CPU, memory, load, filesystem, NIC.
- **Drives** — `smartctl-exporter`, a privileged DaemonSet reading raw SMART data.
- **vLLM** — each vLLM service exposes `/metrics`; Prometheus picks them up from
  `prometheus.io/scrape` annotations. This is what the carbon dashboard is built on.

## What is deliberately not running

- **Alertmanager** — off. Nothing pages anyone; monitoring here is for looking at,
  not for being woken by. Drive *failures* are caught by host `smartd`, which mails
  locally; the exporters exist to trend the slow decline `smartd` cannot see.
- **kube-state-metrics** and **Pushgateway** — off, unused.
