#!/bin/bash

# PostgreSQL Kubernetes Deployment Script
# This script deploys PostgreSQL to your Kubernetes cluster

set -e

echo "🚀 Deploying PostgreSQL to Kubernetes..."

# Load secrets from local file
if [ -f "./secrets.sh" ]; then
    echo "📝 Loading secrets from secrets.sh..."
    source ./secrets.sh
else
    echo "❌ secrets.sh not found!"
    echo "Please copy secrets.sh.example to secrets.sh and set your password:"
    echo "  cp secrets.sh.example secrets.sh"
    echo "  # Edit secrets.sh with your actual password"
    exit 1
fi

# Validate required environment variables
if [ -z "$POSTGRES_PASSWORD" ]; then
    echo "❌ POSTGRES_PASSWORD not set in secrets.sh"
    exit 1
fi

# Set defaults for optional variables
POSTGRES_DB=${POSTGRES_DB:-"postgres"}
POSTGRES_USER=${POSTGRES_USER:-"postgres"}

echo "🔐 Creating PostgreSQL secret with your password..."

# Create namespace if it doesn't exist
echo "📦 Creating postgres namespace..."
kubectl create namespace postgres --dry-run=client -o yaml | kubectl apply -f -

# Create secret from environment variables
echo "� Creating PostgreSQL secret..."
kubectl create secret generic postgres-secret \
  --from-literal=postgres-password="$POSTGRES_PASSWORD" \
  --from-literal=postgres-user="$POSTGRES_USER" \
  --from-literal=postgres-db="$POSTGRES_DB" \
  --namespace=postgres \
  --dry-run=client -o yaml | kubectl apply -f -

# Apply all PostgreSQL manifests

echo " Creating persistent volume claim..."
kubectl apply -f postgres-pvc.yaml

echo "🗄️ Creating PostgreSQL deployment..."
kubectl apply -f postgres-deployment.yaml

echo "🌐 Creating PostgreSQL service..."
kubectl apply -f postgres-service.yaml

echo "⏳ Waiting for PostgreSQL to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/postgres -n postgres

echo "✅ PostgreSQL deployment completed!"
echo ""
echo "Connection details:"
echo "  PostgreSQL Host: postgres-service.postgres.svc.cluster.local"
echo "  PostgreSQL Port: 5432"
echo "  Database: $POSTGRES_DB"
echo "  Username: $POSTGRES_USER"
echo "  Password: [from secrets.sh]"
echo ""
echo "To connect from within the cluster:"
echo "  psql -h postgres-service.postgres.svc.cluster.local -U $POSTGRES_USER -d $POSTGRES_DB"
echo ""
echo "To port-forward PostgreSQL for external access:"
echo "  kubectl port-forward service/postgres-service 5432:5432 -n postgres"
echo "  Then connect to localhost:5432"
