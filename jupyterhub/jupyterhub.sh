#!/bin/bash

helm repo add jupyterhub https://hub.jupyter.org/helm-chart/
helm repo update

## use your name for install name and namespace name
helm upgrade --cleanup-on-fail \
  --install testjuypterhelm jupyterhub/jupyterhub \
  --namespace testjupyter \
  --create-namespace \
  --version=3.2.1 \
  --timeout 90m0s \
  --values public-config.yaml \
  --values private-config.yaml

