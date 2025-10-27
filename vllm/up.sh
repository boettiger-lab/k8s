#!/bin/bash

# Create the vllm namespace if it doesn't exist
kubectl create namespace vllm --dry-run=client -o yaml | kubectl apply -f -

# Create secrets in the vllm namespace
./secrets.sh -n vllm

# Deploy resources in the vllm namespace
kubectl apply -f service.yaml -n vllm
kubectl apply -f ingress.yaml -n vllm
kubectl apply -f deployment.yaml -n vllm

# Show status
kubectl get pods -n vllm
