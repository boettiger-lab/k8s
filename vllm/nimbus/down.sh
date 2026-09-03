#!/bin/bash
# Tear down nimbus's model, leaving the endpoint (Service/Ingress/cert) in place.
#
#   ./down.sh                     # current model
#   ./down.sh deploy-gemma4.yaml  # some other manifest from this directory
#
# The endpoint is deliberately NOT deleted: dropping the Ingress would make
# cert-manager re-issue vllm-nimbus-tls on the next up.sh, which burns a
# Let's Encrypt issuance for nothing. To swap models, scale rather than delete.
set -euo pipefail

MODEL_MANIFEST="${1:-deploy-qwen38.yaml}"
kubectl delete -f "$MODEL_MANIFEST" --ignore-not-found

# To remove the endpoint too:
#   kubectl delete -f endpoint.yaml
# The API key secret is left alone; clients keep working across a model swap.
