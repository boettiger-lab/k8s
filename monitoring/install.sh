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
