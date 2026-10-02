---
title: "Monitoring"
weight: 5
---

# Monitoring

| Component | Collects |
|---|---|
| Prometheus | everything below; 15-day retention |
| node-exporter | host CPU, memory, disk, network |
| dcgm-exporter | GPU utilization, memory, power, temperature, errors |
| smartctl-exporter | drive health and wear |
| vLLM `/metrics` | tokens, latency, cache use (scraped through pod annotations) |
| [Grafana](https://grafana-cirrus.carlboettiger.info) | dashboards, defined as code in `platform/monitoring/` |

Alert routing is set per alert and is not part of the public configuration.

## Carbon accounting

The [carbon dashboard](https://carbon.carlboettiger.info) reports energy and
CO₂ for each served model, both live and over recent windows. It is a small
stateless service,
[boettiger-lab/nimbus-carbon-api](https://github.com/boettiger-lab/nimbus-carbon-api),
that computes everything from Prometheus on request. `/methodology` on the same
host has the full arithmetic. In short:

- **Power** is GPU power from DCGM. **Tokens** come from vLLM's own counters.
- **Grid intensity** is a fixed regional constant (California eGRID CAMX): all
  machines are in one building.
- **Models are discovered, not configured.** Anything that exports vLLM metrics
  is a model.
- **Power is attributed by time.** A machine's GPU power belongs to whichever
  model it is serving in that minute. A model split across two machines is
  charged for both.
- **Aggregates are ratios of totals**, energy over tokens across the window,
  never averages of per-minute ratios. "All-in" counts idle hosting; "working"
  counts only busy minutes.
- **GPU power only.** CPU, memory and power-supply losses are excluded, so the
  figures are a lower bound.
