# nimbus-carbon-api design

## Purpose

Track and expose the carbon footprint of LLM inference on `nimbus` (the single
GB10 DGX Spark box in `boettiger-lab/k8s/vllm/nimbus`), mirroring the existing
[nrp-carbon-api](https://github.com/boettiger-lab/nrp-carbon-api) that does
this for the shared NRP Nautilus cluster. Same methodology (power × grid
intensity, tokens/sec from vLLM), scaled down to one node / one GPU / one
active model at a time.

## Why not just reuse nrp-carbon-api as-is

nrp-carbon-api assumes NRP's topology: many nodes, each GPU dedicated to one
pod, multiple institutions each with their own grid carbon intensity, and a
Prometheus instance that already exists. None of that holds for nimbus:

- **One node, one physical GPU** (a GB10), time-sliced by
  `nvidia-device-plugin` into up to 8 `nvidia.com/gpu` replicas. DCGM's power
  reading is per physical device — it cannot be split across concurrently
  scheduled model pods the way NRP's one-GPU-per-pod design assumes.
- **One fixed location** (Berkeley, CA) instead of a multi-institution
  hostname→region lookup table.
- **No Prometheus yet** — this cluster currently has no monitoring stack
  (confirmed: only cert-manager, external-dns, jupyterhub, nvidia-device-plugin,
  traefik, zfs-localpv are installed via Helm).

## Confirmed feasibility

Checked directly on the node before committing to this design:

- `nvidia-smi --query-gpu=power.draw` reports real wattage on GB10 (~11W idle).
- `dcgmi dmon -e 155` (DCGM_FI_DEV_POWER_USAGE) reads the same value —
  DCGM's power telemetry works on this chip.
- `nvcr.io/nvidia/k8s/dcgm-exporter` ships an arm64 manifest (nimbus is
  `aarch64`), so no image-availability blocker.
- In practice only one vLLM model pod runs at a time (the `qwen` deployment is
  `Running`; the `gemma4` service exists but currently has no backing pod) —
  confirming the "attribute all measured power to the currently active model"
  simplification below is realistic, not just theoretical.

## Architecture

```
vLLM pod (qwen/gemma/nemotron — whichever is currently deployed)
   │ /metrics  (vllm:prompt_tokens_total, vllm:generation_tokens_total, ...)
   ▼
Prometheus (new, minimal single-node install)
   ▲ /metrics  (DCGM_FI_DEV_POWER_USAGE)
   │
dcgm-exporter (new, DaemonSet — 1 node = 1 GPU)

Prometheus
   │
   ▼
nimbus-carbon-api (Go, forked from nrp-carbon-api)
   │
   ▼
dashboard + JSON API @ carbon-nimbus.carlboettiger.info
```

### Prometheus

Install the plain `prometheus-community/prometheus` chart — not
`kube-prometheus-stack`. We don't need Alertmanager, node-exporter,
kube-state-metrics, or Grafana for this; just `prometheus-server` with:

- A small PVC via the cluster's existing `zfs-localpv` StorageClass.
- ~15 day retention (comfortably covers nimbus-carbon-api's own 7-day
  in-memory ring buffer, without keeping unbounded history on a small box).
- Scrape configs (static or `kubernetes_sd_configs`, via ConfigMap) targeting:
  - `dcgm-exporter` service, port `9400`, path `/metrics`
  - the active vLLM service, port `8000`, path `/metrics`

### dcgm-exporter

Single-replica DaemonSet (one node). Uses `runtimeClassName: nvidia`, matching
how `deploy-qwen.yaml` already gets GPU access, with the standard
privileged + hostPath device-mount pattern rather than requesting an
`nvidia.com/gpu` resource slice — it must not compete with the model pod for
one of the 8 time-sliced replicas.

**Known risk**: dcgm-exporter's stock manifests are written against the
NVIDIA GPU Operator; this cluster uses the plain `nvidia-device-plugin`
instead, so the privileged/hostPath wiring may need adjustment during
implementation. **Fallback**: if it fights the device-plugin, replace it with
a small custom sidecar that shells out to `dcgmi dmon -e 155` on an interval
and exposes a handful of Prometheus-format lines itself — much smaller
surface area than the full dcgm-exporter image.

### Power attribution simplification

DCGM only ever reports one physical GPU's power draw. Since nimbus runs at
most one actively-serving model pod at a time in practice, nimbus-carbon-api
attributes 100% of measured power to whichever vLLM target is currently
reporting nonzero token throughput. This is a deliberate departure from
nrp-carbon-api's per-pod GPU dedication assumption, called out here so it
isn't mistaken for an oversight later.

## nimbus-carbon-api (fork of nrp-carbon-api)

New repo: `boettiger-lab/nimbus-carbon-api`, forked from nrp-carbon-api to
keep its Go module layout, dashboard HTML/JS, and CI setup.

Changes from upstream:

- `internal/carbon/intensity.go`: replace the multi-region eGRID lookup table
  with a single constant for Berkeley (CAMX subregion — the same
  0.198 kg CO₂/kWh value nrp-carbon-api already uses for California). No
  hostname/namespace matching needed with one node.
- `internal/scraper`: reuse largely as-is — the ring-buffer history,
  hourly token-weighted CO₂/token averaging, and `ModelMetrics` struct all
  carry over unchanged. Drop the multi-node GPU-count/hardware-discovery
  logic since it's always "1× GB10."
- `cmd/main.go` and API routes: unchanged. Keep
  `GET /api/v1/carbon`, `GET /api/v1/carbon/timeseries`,
  `GET /api/v1/carbon/{ns}/{container}/{metric}`, `GET /healthz`.
  The per-model route is deliberately kept even though only one model runs
  at a time: nimbus swaps models over time (Qwen, Gemma, Nemotron variants),
  so the same history that accumulates in Prometheus lets this become a way
  to compare CO₂/token *across* models tried on the same hardware — not just
  a live gauge for whichever one is currently up.
- `internal/dashboard` static HTML: retitle/rebrand for nimbus; drop the
  "compare across institutions" framing; keep the power/CO₂/tokens chart.
- `PROMETHEUS_URL` points at the in-cluster Prometheus service DNS name
  instead of the public NRP endpoint.
- CI: reuse this repo's arm64-native-runner pattern (commit `5350e06`)
  rather than QEMU emulation, since nimbus is aarch64.

## Deployment & ingress

- k8s manifests modeled on nrp-carbon-api's own (`Deployment` + `Service` +
  `Ingress`), but without the `serverstransport` long-timeout annotation
  vLLM's ingress needs — carbon-api's responses are small and fast.
- Ingress host: `carbon-nimbus.carlboettiger.info`, same
  `cert-manager.io/cluster-issuer: letsencrypt-production` +
  `ingressClassName: traefik` pattern as `vllm-nimbus.carlboettiger.info`
  (see `ingress.yaml`). Public, no auth — same posture as the public NRP
  dashboard; nothing sensitive is exposed (power draw, token rates, CO2
  estimates only).
- Resource requests: tiny (100m CPU / 128Mi mem), matching upstream. This is
  a lightweight poller and must not compete for the box's precious GPU/CPU/
  memory the way the model deployments do.

## Out of scope

- Grafana dashboards, alerting, or general GPU observability (temperature,
  utilization, memory) beyond what's needed for the carbon calculation.
  Standing up Prometheus + dcgm-exporter creates a foundation for this later,
  but it is not part of this project.
- Authentication/access control on the public dashboard.
- Handling multiple concurrently-serving model pods sharing GPU time —
  revisit the power-attribution simplification above if that ever becomes
  the normal mode of operation on nimbus.
