#!/bin/bash

# Based on: https://developer.nvidia.com/blog/improving-gpu-utilization-in-kubernetes/

helm upgrade nvdp nvdp/nvidia-device-plugin \
   --version=0.14.3 \
   --namespace nvidia-device-plugin \
   --create-namespace \
   --set gfd.enabled=true \
   --set-file config.map.config=timeslicing.yaml

