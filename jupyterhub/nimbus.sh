#!/bin/bash
# Deploy JupyterHub on nimbus
#
# Prerequisites:
#   1. Run ./setup-secrets.sh first to create K8s secrets
#   2. Or ensure secrets exist: jupyter-oauth-secret, ghcr-pull-secret
#
# This uses nimbus-config.yaml which references secrets via:
#   - imagePullSecrets (for ghcr-pull-secret)
#   - hub.extraEnv with valueFrom.secretKeyRef (for OAuth)

set -e

NAMESPACE="jupyter"

# Verify secrets exist
echo "🔍 Checking for required secrets..."
if ! kubectl get secret jupyter-oauth-secret -n "$NAMESPACE" &>/dev/null; then
    echo "❌ Missing secret: jupyter-oauth-secret"
    echo "   Run: ./setup-secrets.sh"
    exit 1
fi

if ! kubectl get secret ghcr-pull-secret -n "$NAMESPACE" &>/dev/null; then
    echo "❌ Missing secret: ghcr-pull-secret"
    echo "   Run: ./setup-secrets.sh"
    exit 1
fi
echo "✅ Secrets found"

# Update helm repos
helm repo add jupyterhub https://hub.jupyter.org/helm-chart/
helm repo update

# Show available versions
echo ""
echo "📋 Available JupyterHub chart versions:"
helm search repo jupyterhub/jupyterhub | head -5

# Deploy
echo ""
echo "🚀 Deploying JupyterHub..."
helm upgrade --cleanup-on-fail \
  --install jupyter jupyterhub/jupyterhub \
  --namespace "$NAMESPACE" \
  --create-namespace \
  --version=4.1.0 \
  --timeout 10m0s \
  --values nimbus-config.yaml

echo ""
echo "✅ JupyterHub deployed!"
echo ""
echo "Check status:"
echo "  kubectl get pods -n $NAMESPACE"
echo ""
echo "Access at: https://jupyter-nimbus.carlboettiger.info"
