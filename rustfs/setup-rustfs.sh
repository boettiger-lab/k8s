#!/bin/bash
# Interactive setup for RustFS on cirrus.
#
# The nimbus manifests (init/deployment/service.yaml, s3.nimbus.*) were retired
# when nimbus joined the cirrus cluster as a compute-only worker -- see
# ../k3s/nimbus-join/. That deployment held 276 KiB and was never used.
set -e

NAMESPACE="rustfs"

echo "Setup RustFS S3 Service"
echo "======================="

# Namespace first, so the secret has somewhere to go.
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

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
kubectl apply -f cirrus.yaml

echo ""
echo "RustFS deployed! 🚀"
echo "Check status: kubectl get pods -n $NAMESPACE"
