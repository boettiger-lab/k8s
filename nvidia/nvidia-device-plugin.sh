#!/bin/bash
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm repo update

# check available versions
#helm search repo nvdp --devel

helm upgrade -i nvdp nvdp/nvidia-device-plugin \
  --namespace nvidia-device-plugin \
  --create-namespace \
  --version 0.17.1 \
  --wait \
  --values nvidia-device-plugin-config.yaml


