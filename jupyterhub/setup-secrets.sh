#!/bin/bash
# Setup Kubernetes secrets for JupyterHub on nimbus
# This replaces the plaintext private-config.yaml approach
#
# Usage: ./setup-secrets.sh
#
# Required environment variables (or will prompt):
#   GITHUB_CLIENT_ID     - GitHub OAuth App client ID
#   GITHUB_CLIENT_SECRET - GitHub OAuth App client secret  
#   GHCR_TOKEN           - GitHub Container Registry token (for private images)

set -e

NAMESPACE="jupyter"

echo "============================================"
echo "JupyterHub Secrets Setup for Nimbus"
echo "============================================"
echo ""

# Create namespace if needed
kubectl create namespace "$NAMESPACE" 2>/dev/null || true

# Prompt for secrets if not in environment
if [ -z "$GITHUB_CLIENT_ID" ]; then
    read -p "GitHub OAuth Client ID: " GITHUB_CLIENT_ID
fi

if [ -z "$GITHUB_CLIENT_SECRET" ]; then
    read -sp "GitHub OAuth Client Secret: " GITHUB_CLIENT_SECRET
    echo ""
fi

if [ -z "$GHCR_TOKEN" ]; then
    read -sp "GitHub Container Registry Token (ghp_...): " GHCR_TOKEN
    echo ""
fi

if [ -z "$GHCR_USERNAME" ]; then
    GHCR_USERNAME="cboettig"
fi

echo ""
echo "📦 Creating/updating secrets in namespace '$NAMESPACE'..."

# Delete existing secrets if they exist
kubectl delete secret jupyter-oauth-secret -n "$NAMESPACE" 2>/dev/null || true
kubectl delete secret ghcr-pull-secret -n "$NAMESPACE" 2>/dev/null || true

# Create OAuth secret
kubectl create secret generic jupyter-oauth-secret \
    --namespace "$NAMESPACE" \
    --from-literal=GITHUB_CLIENT_ID="$GITHUB_CLIENT_ID" \
    --from-literal=GITHUB_CLIENT_SECRET="$GITHUB_CLIENT_SECRET"

echo "✅ Created jupyter-oauth-secret"

# Create docker-registry secret for image pulls
kubectl create secret docker-registry ghcr-pull-secret \
    --namespace "$NAMESPACE" \
    --docker-server=ghcr.io \
    --docker-username="$GHCR_USERNAME" \
    --docker-password="$GHCR_TOKEN"

echo "✅ Created ghcr-pull-secret"

echo ""
echo "============================================"
echo "✅ Secrets created successfully!"
echo "============================================"
echo ""
echo "Secrets in namespace '$NAMESPACE':"
kubectl get secrets -n "$NAMESPACE"
echo ""
echo "Next: Run 'bash nimbus.sh' to deploy JupyterHub"
