#!/bin/bash
# Bring up the vllm namespace, both endpoints, and ONE model.
#
# Each GPU node serves a single model at a time behind a fixed URL (endpoints.yaml).
# Pass a model manifest to pick which one; defaults to the current cirrus model.
#
#   ./up.sh                              # cirrus: Qwen3.8-27B (AWQ INT4)
#   ./up.sh qwen38-flashnext-nimbus.yaml # nimbus: Qwen3.8-Flash-Next (NVFP4)
#   ./up.sh qwen38-nimbus.yaml           # nimbus: Qwen3.8-27B (NVFP4), the rollback
#   ./up.sh gemma4-cirrus.yaml           # cirrus: Gemma 4
#
# nimbus is a tainted worker in this same cluster, so its models deploy against the
# cirrus control plane like everything else -- there is no separate nimbus kubeconfig.
set -euo pipefail

MODEL_MANIFEST="${1:-qwen3-8-cirrus.yaml}"

kubectl create namespace vllm --dry-run=client -o yaml | kubectl apply -f -

# Secrets. VLLM_API_KEY is the bearer token clients present; the HF token is only
# needed for gated checkpoints. The NGC pull secret (`ngc-pull`, for nimbus's arm64
# image) is created out of band -- see ../../cluster/nodes/nimbus/README.md.
./secrets.sh -n vllm

if [ -n "${HF_TOKEN:-}" ]; then
  kubectl -n vllm create secret generic huggingface-token \
    --from-literal=token="$HF_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

kubectl apply -f endpoints.yaml
kubectl apply -f "$MODEL_MANIFEST"

kubectl -n vllm get pods -o wide
echo
echo "cirrus: https://vllm-cirrus.carlboettiger.info/v1/models"
echo "nimbus: https://vllm-nimbus.carlboettiger.info/v1/models"
