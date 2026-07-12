#!/bin/bash
set -euo pipefail

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add gpu-helm-charts https://nvidia.github.io/dcgm-exporter/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

helm upgrade -i prometheus prometheus-community/prometheus \
  --namespace monitoring \
  --create-namespace \
  --version 29.14.0 \
  --wait \
  --values prometheus-values.yaml

helm upgrade -i dcgm-exporter gpu-helm-charts/dcgm-exporter \
  --namespace monitoring \
  --version 4.8.2 \
  --wait \
  --values dcgm-exporter-values.yaml

# smartctl_exporter — per-drive SMART metrics (privileged DaemonSet).
kubectl apply -f smartctl-exporter.yaml

# Dashboards (as-code; the Grafana sidecar auto-loads labelled ConfigMaps, so
# applying before/after Grafana both work). Tuned to this cluster's metric
# labels so they show data (community dashboards 1860/12239 do not — wrong job).
kubectl apply -f grafana-dashboard-smart.yaml \
              -f grafana-dashboard-node.yaml \
              -f grafana-dashboard-gpu.yaml

# Grafana admin credentials — created once, out of git, with a random password
# (the chart's default is public/insecure and this is on a public ingress).
if ! kubectl -n monitoring get secret grafana-admin >/dev/null 2>&1; then
  kubectl -n monitoring create secret generic grafana-admin \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="$(openssl rand -base64 24)"
  echo "Created grafana-admin secret (random password)."
fi

# Grafana — provisioned Prometheus datasource + ingress + dashboard sidecar
# (see grafana-values.yaml). NOTE: chart version left unpinned because it was
# not verifiable when authored; after the first successful install, pin it for
# reproducibility (`helm -n monitoring list` shows the resolved version).
helm upgrade -i grafana grafana/grafana \
  --namespace monitoring \
  --wait \
  --values grafana-values.yaml

echo
echo "Grafana: https://grafana-cirrus.carlboettiger.info  (user: admin)"
echo "Admin password:"
echo "  kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo"
