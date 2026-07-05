# nimbus Monitoring Infra (Prometheus + dcgm-exporter) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a minimal Prometheus + dcgm-exporter stack on the nimbus
k3s cluster so GPU power draw and vLLM token throughput are queryable —
the data source the nimbus-carbon-api service (a separate plan) depends on.

**Architecture:** dcgm-exporter runs as a one-replica DaemonSet reading GPU
power from the GB10 via DCGM; a minimal Prometheus (no Alertmanager,
kube-state-metrics, node-exporter, or Pushgateway) scrapes it and the
existing vLLM service via annotation-based auto-discovery, which the chart
already enables by default.

**Tech Stack:** Helm (charts already used elsewhere in this cluster for
add-ons), `prometheus-community/prometheus`, NVIDIA's
`gpu-helm-charts/dcgm-exporter`.

## Global Constraints

- Cluster is `nimbus`: single-node k3s, aarch64 (GB10 DGX Spark). Verify any
  image supports arm64 before using it.
- New namespace: `monitoring`.
- Pin exact chart versions: `prometheus-community/prometheus` **29.14.0**,
  `gpu-helm-charts/dcgm-exporter` **4.8.2**.
- dcgm-exporter must **not** request the `nvidia.com/gpu` extended resource —
  the node's `nvidia-device-plugin` time-slices that resource into 8
  replicas for model-serving pods (see `nvidia/nvidia-device-plugin-config.yaml`);
  a monitoring pod must not consume one of those slots. It gets GPU access
  via `runtimeClassName: nvidia` instead (same mechanism `deploy-qwen.yaml`
  uses), which the chart supports as a plain value with no resource request.
- Disable `serviceMonitor` in the dcgm-exporter chart — this cluster has no
  prometheus-operator CRDs installed, so leaving it enabled would fail the
  install.
- Prometheus persistent storage uses the existing `openebs-zfs` StorageClass
  (confirmed present via `kubectl get storageclass`).
- Neither Prometheus nor dcgm-exporter get an Ingress in this plan — both
  stay `ClusterIP`/internal. Public exposure is scoped to the
  nimbus-carbon-api service in a later plan.
- New files live under a new top-level `monitoring/` directory, following
  the existing `nvidia/` directory's convention: a `README.md`, one
  `*-values.yaml` per Helm release, and a single `install.sh` using
  `helm upgrade -i ... --create-namespace` (see `nvidia/nvidia-device-plugin.sh`
  for the exact pattern to match).
- Confirmed on the live node before writing this plan: `dcgmi dmon -e 155`
  reads real GB10 power (~11W idle); the full default dcgm-exporter field
  list (`dcgmi dmon -e 100,101,140,150,155,156,202,203,204,206,207,230,251,252`)
  returns valid readings for power/utilization/temperature but `N/A` for
  memory clock and framebuffer free/used — expected on GB10's unified-memory
  architecture, not a bug, and does not stop the exporter from tolerating
  those fields.

---

### Task 1: Deploy Prometheus

**Files:**
- Create: `monitoring/prometheus-values.yaml`
- Create: `monitoring/install.sh`
- Create: `monitoring/README.md`

**Interfaces:**
- Produces: a Prometheus server reachable in-cluster at
  `http://prometheus-server.monitoring.svc.cluster.local` (Service port 80),
  and via `kubectl -n monitoring port-forward svc/prometheus-server 9090:80`
  for local queries against `http://localhost:9090/api/v1/query`. Task 2 and
  Task 3 both rely on this Prometheus instance being live and using its
  default annotation-based scrape discovery (enabled by the chart out of the
  box — no scrape-config changes needed).

- [ ] **Step 1: Add the required Helm repos**

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add gpu-helm-charts https://nvidia.github.io/dcgm-exporter/helm-charts
helm repo update
```

Expected: both repos report `"...has been added to your repositories"` (or
already exists), and `helm repo update` ends with
`Update Complete. ⎈Happy Helming!⎈`.

- [ ] **Step 2: Write `monitoring/prometheus-values.yaml`**

```yaml
# Minimal Prometheus install for nimbus: just prometheus-server.
# No Alertmanager, kube-state-metrics, node-exporter, or Pushgateway —
# this cluster only needs Prometheus as a metrics store for dcgm-exporter
# and vLLM's built-in /metrics endpoint.
alertmanager:
  enabled: false
kube-state-metrics:
  enabled: false
prometheus-node-exporter:
  enabled: false
prometheus-pushgateway:
  enabled: false

server:
  retention: "15d"
  persistentVolume:
    storageClass: openebs-zfs
    size: 5Gi
```

- [ ] **Step 3: Write `monitoring/install.sh`**

```bash
#!/bin/bash
set -euo pipefail

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add gpu-helm-charts https://nvidia.github.io/dcgm-exporter/helm-charts
helm repo update

helm upgrade -i prometheus prometheus-community/prometheus \
  --namespace monitoring \
  --create-namespace \
  --version 29.14.0 \
  --wait \
  --values prometheus-values.yaml
```

```bash
chmod +x monitoring/install.sh
```

- [ ] **Step 4: Run it**

```bash
cd monitoring && ./install.sh
```

Expected: ends with `STATUS: deployed` for release `prometheus`.

- [ ] **Step 5: Verify the Prometheus pod is running**

```bash
kubectl -n monitoring get pods
```

Expected: a pod named `prometheus-server-0` (or similar) in `Running` /
`1/1` (or `2/2`) state.

- [ ] **Step 6: Verify Prometheus is scraping itself**

```bash
kubectl -n monitoring port-forward svc/prometheus-server 9090:80 &
sleep 3
curl -s 'http://localhost:9090/api/v1/query?query=up' | python3 -m json.tool
kill %1
```

Expected: JSON with `"status": "success"` and at least one result where
`metric.job == "prometheus"` and `value` ends in `"1"`.

- [ ] **Step 7: Write `monitoring/README.md`**

```markdown
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
```

- [ ] **Step 8: Commit**

```bash
git add monitoring/prometheus-values.yaml monitoring/install.sh monitoring/README.md
git commit -m "monitoring: deploy minimal Prometheus for nimbus"
```

---

### Task 2: Deploy dcgm-exporter and verify GPU power metrics

**Files:**
- Create: `monitoring/dcgm-exporter-values.yaml`
- Modify: `monitoring/install.sh`
- Modify: `monitoring/README.md`

**Interfaces:**
- Consumes: the `monitoring` namespace and `gpu-helm-charts` repo from Task 1.
- Produces: `DCGM_FI_DEV_POWER_USAGE` queryable in Prometheus — this is the
  power signal nimbus-carbon-api (a later plan) uses for its
  power × grid-intensity carbon calculation.

- [ ] **Step 1: Write `monitoring/dcgm-exporter-values.yaml`**

```yaml
# dcgm-exporter on nimbus's single GB10. Must NOT request nvidia.com/gpu —
# that resource is time-sliced 8-way for model-serving pods
# (see ../nvidia/nvidia-device-plugin-config.yaml). GPU access instead
# comes from runtimeClassName, same mechanism deploy-qwen.yaml uses.
runtimeClassName: nvidia

# No prometheus-operator CRDs installed in this cluster — ServiceMonitor
# would fail to apply.
serviceMonitor:
  enabled: false

# Picked up by Prometheus's built-in kubernetes-pods scrape job
# (enabled by default in the prometheus-community/prometheus chart).
podAnnotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "9400"
```

- [ ] **Step 2: Add the dcgm-exporter release to `monitoring/install.sh`**

Append to the end of the file:

```bash

helm upgrade -i dcgm-exporter gpu-helm-charts/dcgm-exporter \
  --namespace monitoring \
  --version 4.8.2 \
  --wait \
  --values dcgm-exporter-values.yaml
```

- [ ] **Step 3: Run it**

```bash
cd monitoring && ./install.sh
```

Expected: ends with `STATUS: deployed` for release `dcgm-exporter`.

- [ ] **Step 4: Verify the dcgm-exporter pod is running**

```bash
kubectl -n monitoring get pods -l app.kubernetes.io/name=dcgm-exporter
```

Expected: one pod, `Running`, `1/1`.

If it's crash-looping, check logs (`kubectl -n monitoring logs
-l app.kubernetes.io/name=dcgm-exporter`). If the failure is about an
unsupported DCGM field (not just an `N/A` reading — an actual collector
init error), fall back to a minimal custom field list confirmed working on
this GB10, by adding this to `monitoring/dcgm-exporter-values.yaml` and
re-running `./install.sh`:

```yaml
customMetrics: |
  DCGM_FI_DEV_POWER_USAGE, gauge, Power draw (in W).
  DCGM_FI_DEV_GPU_UTIL, gauge, GPU utilization (in %).
```

- [ ] **Step 5: Verify the raw metrics endpoint directly**

```bash
kubectl -n monitoring port-forward svc/dcgm-exporter 9400:9400 &
sleep 3
curl -s http://localhost:9400/metrics | grep DCGM_FI_DEV_POWER_USAGE
kill %1
```

Expected: one line like
`DCGM_FI_DEV_POWER_USAGE{gpu="0",...} 11.43` (value will vary).

- [ ] **Step 6: Verify Prometheus picked it up**

```bash
kubectl -n monitoring port-forward svc/prometheus-server 9090:80 &
sleep 3
curl -s 'http://localhost:9090/api/v1/query?query=DCGM_FI_DEV_POWER_USAGE' | python3 -m json.tool
kill %1
```

Expected: `"status": "success"` with one result, `value` a small positive
number (watts).

- [ ] **Step 7: Update `monitoring/README.md`**

Add below the existing "Query" section:

```markdown
## Metrics

- `DCGM_FI_DEV_POWER_USAGE` — GPU power draw in watts (from dcgm-exporter).
  Note: on GB10's unified-memory architecture, `DCGM_FI_DEV_FB_FREE` /
  `DCGM_FI_DEV_FB_USED` and memory-clock fields report `N/A` — expected,
  not a bug.
```

- [ ] **Step 8: Commit**

```bash
git add monitoring/dcgm-exporter-values.yaml monitoring/install.sh monitoring/README.md
git commit -m "monitoring: deploy dcgm-exporter for GPU power metrics"
```

---

### Task 3: Expose vLLM metrics to Prometheus

**Files:**
- Modify: `vllm/nimbus/service.yaml`

**Interfaces:**
- Consumes: the live Prometheus instance from Task 1 (annotation-based
  `kubernetes-service-endpoints` scrape job, enabled by default).
- Produces: `vllm:generation_tokens_total`, `vllm:prompt_tokens_total`, etc.
  queryable in Prometheus, labeled by whichever `model_name` is currently
  deployed behind `vllm-nimbus-service` — the token-throughput signal
  nimbus-carbon-api needs for tokens/sec and CO2/token.

- [ ] **Step 1: Add scrape annotations to the vLLM service**

Modify `vllm/nimbus/service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: vllm-nimbus-service
  labels:
    k8s-app: vllm-nimbus
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "8000"

spec:
  type: LoadBalancer
  ports:
    - port: 8000
      targetPort: http
      protocol: TCP
      name: http
  selector:
    k8s-app: vllm-nimbus-nemotron
```

- [ ] **Step 2: Apply it**

```bash
kubectl apply -f vllm/nimbus/service.yaml
```

Expected: `service/vllm-nimbus-service configured`. This is a metadata-only
change to an existing Service (not GPU-bound), so no pod restart or
`Recreate` concern applies here.

- [ ] **Step 3: Verify Prometheus is scraping it**

Wait ~30s for the next scrape interval, then:

```bash
kubectl -n monitoring port-forward svc/prometheus-server 9090:80 &
sleep 3
curl -s 'http://localhost:9090/api/v1/query?query=vllm:generation_tokens_total' | python3 -m json.tool
kill %1
```

Expected: `"status": "success"` with a result whose `metric.model_name`
matches whichever model is currently deployed (e.g. `"qwen"`), and a
nonzero counter `value`.

- [ ] **Step 4: Commit**

```bash
git add vllm/nimbus/service.yaml
git commit -m "vllm/nimbus: expose /metrics to Prometheus via scrape annotations"
```

## Self-Review Notes

- **Spec coverage**: spec's "Prometheus" and "dcgm-exporter" sections are
  covered by Tasks 1–2; the vLLM scrape target (implied by the spec's
  architecture diagram) is covered by Task 3. The nimbus-carbon-api service
  itself, its fork changes, and its Ingress are explicitly out of scope for
  this plan — they're a separate plan per the earlier scope-splitting
  decision.
- **Placeholder scan**: no TBDs; every step has literal file content and
  exact commands.
- **Type/interface consistency**: Task 2 and Task 3 both depend on Task 1's
  Prometheus Service name (`prometheus-server`, namespace `monitoring`,
  port 80) and its default annotation-based scrape jobs — verified by
  rendering the chart locally (`helm template`) before writing this plan,
  not assumed.
