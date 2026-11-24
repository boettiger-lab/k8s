#!/bin/bash
# CVE scanning of running images (k8s#221). Settings and rationale: values.yaml.
# Remove: helm -n trivy-system uninstall trivy-operator
#         kubectl delete crd -l app.kubernetes.io/name=trivy-operator
set -euo pipefail
cd "$(dirname "$0")"
helm repo add aqua https://aquasecurity.github.io/helm-charts/
helm repo update aqua
helm upgrade -i trivy-operator aqua/trivy-operator \
  --namespace trivy-system \
  --create-namespace \
  --version 0.38.1 \
  --wait \
  --values values.yaml
