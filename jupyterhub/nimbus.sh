#!/bin/bash

helm repo add jupyterhub https://hub.jupyter.org/helm-chart/
helm repo update
## check most recent version 
helm search repo jupyterhub/jupyterhub

## use your name for install name and namespace name
helm upgrade --cleanup-on-fail \
  --install jupyter jupyterhub/jupyterhub \
  --namespace jupyter \
  --create-namespace \
  --version=4.2.0 \
  --timeout 10m0s \
  --values nimbus-config.yaml \
  --values private-config.yaml