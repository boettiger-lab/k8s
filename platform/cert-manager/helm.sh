#!/bin/bash
# Install/upgrade cert-manager and the Let's Encrypt ClusterIssuer (DNS-01 via Cloudflare).
#
# Upgrades go ONE MINOR AT A TIME (cert-manager's upgrade docs), reading
# https://cert-manager.io/docs/releases/upgrading/ for each step:
#   VERSION=v1.20.5 bash platform/cert-manager/helm.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

VERSION="${VERSION:-v1.21.3}"

helm repo add jetstack https://charts.jetstack.io
helm repo update jetstack

# crds.enabled + crds.keep == the deprecated installCRDs=true: the chart manages
# (and upgrades) the CRDs, and a helm uninstall does not delete them -- which
# would delete every Certificate with them.
helm upgrade \
  --cleanup-on-fail \
  --install cert-manager jetstack/cert-manager \
  --version "$VERSION" \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true \
  --set crds.keep=true \
  --wait

kubectl apply -f cluster-issuer-prod.yaml
