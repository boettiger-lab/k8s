#!/bin/bash
# Tear down a model, leaving the endpoints (Service/Ingress/cert) in place.
#
#   ./down.sh                      # the current cirrus model
#   ./down.sh qwen38-nimbus.yaml   # some other manifest from this directory
#   ./down.sh --all                # every model, plus the endpoints themselves
#
# The endpoints are deliberately NOT deleted by default: dropping an Ingress makes
# cert-manager re-issue its certificate on the next up.sh, burning a Let's Encrypt
# issuance for nothing. To swap models, scale rather than delete.
set -euo pipefail

if [[ "${1:-}" == "--all" ]]; then
  kubectl delete deployment -n vllm qwen3-8 gemma4 qwen38 --ignore-not-found
  kubectl delete -f endpoints.yaml --ignore-not-found
  echo "Endpoints removed too (DNS records and certs will need re-issuing on next up)."
else
  MODEL_MANIFEST="${1:-qwen3-8-cirrus.yaml}"
  kubectl delete -f "$MODEL_MANIFEST" --ignore-not-found
  echo "Endpoints kept:"
  echo "  https://vllm-cirrus.carlboettiger.info"
  echo "  https://vllm-nimbus.carlboettiger.info"
fi
# The API key secret is left alone; clients keep working across a model swap.
