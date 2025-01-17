#!/bin/bash

helm repo add binderhub-service https://2i2c.org/binderhub-service
helm repo update

helm upgrade \
  --install \
  --create-namespace \
  --devel \
  --wait \
  --namespace testjupyter \
  my-binderhub \
  binderhub-service/binderhub-service \
  --values binderhub-service-config.yaml \
  --values private-binderhub.yaml

