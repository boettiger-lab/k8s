#!/bin/bash
# Deploy hash-archive.
#
# PRIVATE BY DEFAULT. The ingress is NOT applied unless PUBLIC=1.
#
#   ./up.sh              # cluster-internal only (recommended)
#   PUBLIC=1 ./up.sh     # also publish at hash-archive.carlboettiger.info
#
# Why private is the default: this is unmaintained C network code (upstream's
# last commit 2021-10-31) whose purpose is to fetch arbitrary user-supplied
# URLs, and whose TLS stack is statically vendored from a 2021 pin. Restricting
# who can trigger a fetch is the only control over that outbound exposure —
# the NetworkPolicy contains where it can reach, not who can drive it.
# See ../README.md "Security posture".
set -e
cd "$(dirname "$0")"

kubectl create namespace hash-archive --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f pvc.yaml
kubectl apply -f networkpolicy.yaml
kubectl apply -f service.yaml
kubectl apply -f deployment.yaml

if [[ "${PUBLIC:-0}" == "1" ]]; then
  echo ">> PUBLIC=1 — publishing at hash-archive.carlboettiger.info"
  kubectl apply -f ingress.yaml
else
  echo ">> private mode (no ingress). Reach it with:"
  echo "     kubectl -n hash-archive port-forward svc/hash-archive 8000:8000"
  echo "     curl -H 'Host: hash-archive.carlboettiger.info' http://127.0.0.1:8000/"
  kubectl -n hash-archive delete ingress hash-archive --ignore-not-found
fi

kubectl rollout status deployment/hash-archive -n hash-archive --timeout=5m
kubectl get pods,svc,ingress -n hash-archive
