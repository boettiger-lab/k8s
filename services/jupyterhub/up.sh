#!/bin/bash
# Deploy / upgrade JupyterHub (release `juypterhelm` in namespace `jupyter`).
#
# Serves https://jupyterhub.cirrus.carlboettiger.info -- the lab's one hub.
# Credentials come from Kubernetes Secrets, not from values: run ./setup-secrets.sh
# first. public-config.yaml is the complete, committed configuration.
set -euo pipefail

helm repo add jupyterhub https://hub.jupyter.org/helm-chart/
helm repo update

helm upgrade --cleanup-on-fail \
  --install juypterhelm jupyterhub/jupyterhub \
  --namespace jupyter \
  --create-namespace \
  --version=4.0.0 \
  --timeout 90m0s \
  --values public-config.yaml
