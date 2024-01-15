#!/bin/bash
helm upgrade -i nvdp nvdp/nvidia-device-plugin \
  --namespace nvidia-device-plugin \
  --create-namespace \
  --version 0.14.3 \
  --wait \
  --values nvidia-device-plugin-config.yaml


