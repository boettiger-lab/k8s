#!/bin/bash
set -e

kubectl create namespace titiler --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f service.yaml
kubectl apply -f ingress.yaml
kubectl apply -f deployment.yaml

kubectl rollout status deployment/titiler -n titiler
kubectl get pods -n titiler
