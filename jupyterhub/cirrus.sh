#!/bin/bash

helm repo add jupyterhub https://hub.jupyter.org/helm-chart/
helm repo update

## use your name for install name and namespace name
helm upgrade --cleanup-on-fail \
  --install juypterhelm jupyterhub/jupyterhub \
  --namespace jupyter \
  --create-namespace \
  --version=4.0.0 \
  --timeout 90m0s \
  --values public-config.yaml \
  --values private-config.yaml \
  --values jupyterai-config.yaml

