#!/bin/bash


## use your name for install name and namespace name
helm upgrade --cleanup-on-fail \
  --install testjuypterhelm jupyterhub/jupyterhub \
  --namespace testjupyter \
  --create-namespace \
  --version=3.2.1 \
  --values public-config.yaml \
  --values private-config.yaml

