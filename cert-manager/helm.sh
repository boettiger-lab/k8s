#!/bin/bash
helm repo add jetstack https://charts.jetstack.io
helm repo update


helm upgrade \
  --cleanup-on-fail \
  --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set installCRDs=true

kubectl apply -f cluster-issuer-prod.yaml

