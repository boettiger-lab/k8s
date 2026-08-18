#!/bin/bash
# Tear down the model(s) but KEEP the shared endpoint (Service/Ingress/cert), so
# the next model reuses the same URL, DNS record, and certificate.
# Pass --all to remove the endpoint too.
set -euo pipefail

kubectl delete deployment -n vllm qwen3-8 gemma4 --ignore-not-found

if [[ "${1:-}" == "--all" ]]; then
  kubectl delete -f endpoint.yaml --ignore-not-found
  echo "Endpoint removed too (DNS record and cert will need re-issuing on next up)."
else
  echo "Endpoint kept: https://vllm-cirrus.carlboettiger.info"
fi
