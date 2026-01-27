#!/bin/bash
# Setup Kubernetes secrets for JupyterHub
# This replaces the plaintext private-config.yaml approach
#
# Usage: ./setup-secrets.sh
#
# Required environment variables (or will prompt):
#   GITHUB_CLIENT_ID     - GitHub OAuth App client ID
#   GITHUB_CLIENT_SECRET - GitHub OAuth App client secret  
#   OPENAI_API_KEY       - OpenAI API key
#   MINIO_KEY            - MinIO access key
#   MINIO_SECRET         - MinIO secret key
#   GHCR_USERNAME        - GitHub Container Registry username
#   GHCR_PASSWORD        - GitHub Container Registry token (for private images)

set -e

NAMESPACE="jupyter"

echo "============================================"
echo "JupyterHub Secrets Setup"
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

if [ -z "$OPENAI_API_KEY" ]; then
    read -sp "OpenAI API Key: " OPENAI_API_KEY
    echo ""
fi

if [ -z "$MINIO_KEY" ]; then
    read -p "MinIO Access Key: " MINIO_KEY
fi

if [ -z "$MINIO_SECRET" ]; then
    read -sp "MinIO Secret Key: " MINIO_SECRET
    echo ""
fi

if [ -z "$GHCR_USERNAME" ]; then
    read -p "GitHub Container Registry Username [cboettig]: " GHCR_USERNAME
    GHCR_USERNAME="${GHCR_USERNAME:-cboettig}"
fi

if [ -z "$GHCR_PASSWORD" ]; then
    read -sp "GitHub Container Registry Token (ghp_...): " GHCR_PASSWORD
    echo ""
fi

echo ""
echo "📦 Creating/updating secrets in namespace '$NAMESPACE'..."

# Delete existing secrets if they exist
kubectl delete secret jupyter-oauth-secret -n "$NAMESPACE" 2>/dev/null || true
kubectl delete secret jupyter-secrets -n "$NAMESPACE" 2>/dev/null || true
kubectl delete secret ghcr-pull-secret -n "$NAMESPACE" 2>/dev/null || true

# Create OAuth secret
kubectl create secret generic jupyter-oauth-secret \
    --namespace "$NAMESPACE" \
    --from-literal=GITHUB_CLIENT_ID="$GITHUB_CLIENT_ID" \
    --from-literal=GITHUB_CLIENT_SECRET="$GITHUB_CLIENT_SECRET"

echo "✅ Created jupyter-oauth-secret"

# Create general secrets for API keys and MinIO credentials
kubectl create secret generic jupyter-secrets \
    --namespace "$NAMESPACE" \
    --from-literal=OPENAI_API_KEY="$OPENAI_API_KEY" \
    --from-literal=MINIO_KEY="$MINIO_KEY" \
    --from-literal=MINIO_SECRET="$MINIO_SECRET" \
    --from-literal=AWS_ACCESS_KEY_ID="$MINIO_KEY" \
    --from-literal=AWS_SECRET_ACCESS_KEY="$MINIO_SECRET" \
    --from-literal=GHCR_USERNAME="$GHCR_USERNAME" \
    --from-literal=GHCR_PASSWORD="$GHCR_PASSWORD"

echo "✅ Created jupyter-secrets"

# Create docker-registry secret for image pulls
kubectl create secret docker-registry ghcr-pull-secret \
    --namespace "$NAMESPACE" \
    --docker-server=ghcr.io \
    --docker-username="$GHCR_USERNAME" \
    --docker-password="$GHCR_PASSWORD"

echo "✅ Created ghcr-pull-secret"

echo ""
echo "============================================"
echo "✅ Secrets created successfully!"
echo "============================================"
echo ""
echo "Secrets in namespace '$NAMESPACE':"
kubectl get secrets -n "$NAMESPACE"
echo ""
echo "Next: Run 'bash cirrus.sh' to deploy JupyterHub"
