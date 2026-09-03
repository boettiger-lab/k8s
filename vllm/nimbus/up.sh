#!/bin/bash
# Bring up nimbus's vLLM endpoint and ONE model, in the shared `vllm` namespace.
#
#   ./up.sh                       # current model (Qwen3.8-27B-NVFP4)
#   ./up.sh deploy-gemma4.yaml    # some other manifest from this directory
#
# nimbus is a tainted worker in the cirrus cluster, so this is run against the
# cirrus control plane like any other deploy -- there is no separate nimbus
# kubeconfig any more. See ../../k3s/nimbus-join/.
set -euo pipefail

MODEL_MANIFEST="${1:-deploy-qwen38.yaml}"

kubectl create namespace vllm --dry-run=client -o yaml | kubectl apply -f -

# Secrets. NIMBUS_KEY is the bearer token clients present; HF_TOKEN is only
# needed for gated checkpoints. The NGC pull secret is created out of band
# (it holds an NGC API key) -- see ../../k3s/nimbus-join/README.md.
kubectl -n vllm create secret generic vllm-api-key \
  --from-literal=api-key="${NIMBUS_KEY:?set NIMBUS_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -

if [ -n "${HF_TOKEN:-}" ]; then
  kubectl -n vllm create secret generic huggingface-token \
    --from-literal=token="$HF_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

# Shared with cirrus -- one definition, applied by both up.sh scripts.
kubectl apply -f ../serverstransport.yaml
kubectl apply -f endpoint.yaml
kubectl apply -f "$MODEL_MANIFEST"

kubectl -n vllm get pods -o wide
echo
echo "Endpoint: https://vllm-nimbus.carlboettiger.info/v1/models"
