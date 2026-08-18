#!/bin/bash
# Bring up the vllm namespace, the shared endpoint, and ONE model.
#
# cirrus serves a single model at a time behind https://vllm-cirrus.carlboettiger.info
# (see endpoint.yaml). Pass a model manifest to pick which one; defaults to the
# current model.
set -euo pipefail

MODEL_MANIFEST="${1:-deploy-qwen3-8.yaml}"

kubectl create namespace vllm --dry-run=client -o yaml | kubectl apply -f -

# HF token + API key
../secrets.sh -n vllm

kubectl apply -f endpoint.yaml
kubectl apply -f "$MODEL_MANIFEST"

kubectl get pods -n vllm
echo
echo "Endpoint: https://vllm-cirrus.carlboettiger.info/v1/models"
