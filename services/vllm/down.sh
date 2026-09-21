#!/bin/bash
# Tear down a model, leaving the endpoints (Service/Ingress/cert) in place.
#
#   ./down.sh                      # the current cirrus workload (speech-to-text)
#   ./down.sh qwen38-nimbus.yaml   # some other manifest from this directory
#   ./down.sh --all                # every model, plus the endpoints themselves
#
# The endpoints are deliberately NOT deleted by default: dropping an Ingress makes
# cert-manager re-issue its certificate on the next up.sh, burning a Let's Encrypt
# issuance for nothing. To swap models, scale rather than delete.
set -euo pipefail

if [[ "${1:-}" == "--all" ]]; then
  kubectl delete deployment -n vllm qwen3-8 gemma4 qwen38 qwen38-flashnext stt --ignore-not-found
  kubectl delete -f endpoints.yaml --ignore-not-found
  echo "Endpoints removed too (DNS records and certs will need re-issuing on next up)."
else
  MODEL_MANIFEST="${1:-stt-cirrus.yaml}"
  if [[ "$MODEL_MANIFEST" == "stt-cirrus.yaml" ]]; then
    # stt-cirrus.yaml carries its own Service and Ingress alongside the Deployment, so
    # `delete -f` would take the endpoint and its certificate with it. Drop only the
    # workload, same as for the model manifests.
    kubectl delete deployment -n vllm stt --ignore-not-found
  else
    kubectl delete -f "$MODEL_MANIFEST" --ignore-not-found
  fi
  echo "Endpoints kept:"
  echo "  https://vllm-cirrus.carlboettiger.info"
  echo "  https://vllm-nimbus.carlboettiger.info"
  echo "  https://whisper-cirrus.carlboettiger.info"
fi
# The API key secret is left alone; clients keep working across a model swap.
