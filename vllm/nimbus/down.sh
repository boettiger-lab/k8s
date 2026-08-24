#!/bin/bash

# Delete Kubernetes manifests
kubectl delete -f ingress.yaml
kubectl delete -f service.yaml
kubectl delete -f deployment.yaml

# Delete API key secret
# kubectl delete secret vllm-api-key
