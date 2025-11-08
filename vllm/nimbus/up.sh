#!/bin/bash

# Create API key secret if it doesn't exist
kubectl create secret generic vllm-api-key --from-literal=api-key=$CIRRUS_KEY --dry-run=client -o yaml | kubectl apply -f -

# Apply Kubernetes manifests
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml
kubectl apply -f ingress.yaml
