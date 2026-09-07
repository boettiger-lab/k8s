#!/bin/bash
set -e
cd "$(dirname "$0")"

kubectl create namespace hash-archive --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f pvc.yaml
kubectl apply -f networkpolicy.yaml
kubectl apply -f service.yaml
kubectl apply -f ingress.yaml
kubectl apply -f deployment.yaml

# The in-container `make install` makes first start slow; allow for it.
kubectl rollout status deployment/hash-archive -n hash-archive --timeout=10m
kubectl get pods,svc,ingress -n hash-archive
