#!/bin/bash

# PostgreSQL Kubernetes Cleanup Script
# This script removes PostgreSQL from your Kubernetes cluster

set -e

echo "🗑️ Removing PostgreSQL from Kubernetes..."

# Remove all PostgreSQL resources
echo "🗄️ Removing PostgreSQL deployment..."
kubectl delete -f postgres-deployment.yaml --ignore-not-found=true

echo "🌐 Removing PostgreSQL service..."
kubectl delete -f postgres-service.yaml --ignore-not-found=true

echo "💾 Removing persistent volume claim..."
kubectl delete -f postgres-pvc.yaml --ignore-not-found=true

echo "📝 Removing PostgreSQL secret..."
kubectl delete -f postgres-secret.yaml --ignore-not-found=true

echo "📦 Removing postgres namespace..."
kubectl delete namespace postgres --ignore-not-found=true

echo "✅ PostgreSQL cleanup completed!"
