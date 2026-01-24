#!/bin/bash
# interactive setup for RustFS
set -e

NAMESPACE="rustfs"

echo "Setup RustFS S3 Service"
echo "======================="

# Ensure namespace manifests are applied first (except secret)
kubectl apply -f init.yaml --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true

# Check if secret exists
if kubectl get secret rustfs-secrets -n "$NAMESPACE" &>/dev/null; then
    echo "✅ Secret 'rustfs-secrets' already exists."
    read -p "Do you want to overwrite it? (y/N) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Skipping secret creation."
    else
        echo "Creating new secret..."
        SET_SECRET=true
    fi
else
    SET_SECRET=true
fi

if [ "$SET_SECRET" = true ]; then
    read -p "Enter Access Key (default: admin): " ACCESS_KEY
    ACCESS_KEY=${ACCESS_KEY:-admin}
    
    read -s -p "Enter Secret Key (default: password): " SECRET_KEY
    SECRET_KEY=${SECRET_KEY:-password}
    echo ""

    kubectl create secret generic rustfs-secrets \
        --namespace "$NAMESPACE" \
        --from-literal=access-key="$ACCESS_KEY" \
        --from-literal=secret-key="$SECRET_KEY" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    echo "✅ Secret 'rustfs-secrets' created/updated."
fi

echo "Applying manifests..."
kubectl apply -f init.yaml
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml

echo ""
echo "RustFS deployed! 🚀"
echo "Check status: kubectl get pods -n $NAMESPACE"
