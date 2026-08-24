#!/bin/bash
# Deploy Armada batch job scheduler and all dependencies on this k3s cluster.
# Run from this directory: bash install.sh

set -euo pipefail

NAMESPACE=armada
JOBS_NAMESPACE=armada-jobs

# ---------------------------------------------------------------------------
# 1. Helm repos
# ---------------------------------------------------------------------------
echo "==> Adding Helm repos..."
helm repo add gresearch https://g-research.github.io/charts
helm repo add bitnami   https://charts.bitnami.com/bitnami
helm repo add apache    https://pulsar.apache.org/charts
helm repo update

# ---------------------------------------------------------------------------
# 2. Namespace + secrets
# ---------------------------------------------------------------------------
echo "==> Creating namespaces..."
kubectl create namespace "$NAMESPACE"      --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "$JOBS_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Postgres password — generate once and store as a secret
if ! kubectl get secret armada-postgres-secret -n "$NAMESPACE" &>/dev/null; then
  PGPASS=$(openssl rand -base64 24)
  kubectl create secret generic armada-postgres-secret \
    --namespace "$NAMESPACE" \
    --from-literal=postgres-password="$PGPASS" \
    --from-literal=password="$PGPASS"
  echo "  Generated postgres password and stored in secret armada-postgres-secret"
fi

PGPASS=$(kubectl get secret armada-postgres-secret -n "$NAMESPACE" \
  -o jsonpath='{.data.password}' | base64 -d)

# ---------------------------------------------------------------------------
# 3. PostgreSQL (Bitnami)
# ---------------------------------------------------------------------------
echo "==> Installing PostgreSQL..."
helm upgrade -i armada-postgresql bitnami/postgresql \
  --namespace "$NAMESPACE" \
  --values postgres-values.yaml \
  --wait --timeout 5m

# Create additional databases needed by Armada components
echo "==> Creating Armada databases..."
PGADMINPASS=$(kubectl get secret armada-postgres-secret -n "$NAMESPACE" \
  -o jsonpath='{.data.postgres-password}' | base64 -d)
for DB in scheduler lookout; do
  kubectl exec -n "$NAMESPACE" armada-postgresql-0 -- \
    env PGPASSWORD="$PGADMINPASS" psql -U postgres \
    -c "CREATE DATABASE $DB;" 2>/dev/null || true
  kubectl exec -n "$NAMESPACE" armada-postgresql-0 -- \
    env PGPASSWORD="$PGADMINPASS" psql -U postgres \
    -c "GRANT ALL PRIVILEGES ON DATABASE $DB TO armada;" 2>/dev/null || true
  kubectl exec -n "$NAMESPACE" armada-postgresql-0 -- \
    env PGPASSWORD="$PGADMINPASS" psql -U postgres -d "$DB" \
    -c "GRANT ALL ON SCHEMA public TO armada;" 2>/dev/null || true
done

# ---------------------------------------------------------------------------
# 4. Redis (Bitnami)
# ---------------------------------------------------------------------------
echo "==> Installing Redis..."
helm upgrade -i armada-redis bitnami/redis \
  --namespace "$NAMESPACE" \
  --values redis-values.yaml \
  --wait --timeout 5m

# ---------------------------------------------------------------------------
# 5. Apache Pulsar (minimal single-node config)
# NOTE: The chart installs a victoria-metrics monitoring stack alongside Pulsar.
# ---------------------------------------------------------------------------
echo "==> Installing Pulsar (this takes several minutes)..."
helm upgrade -i armada-pulsar apache/pulsar \
  --namespace "$NAMESPACE" \
  --values pulsar-values.yaml \
  --timeout 15m || true  # helm may time out but pods continue starting

echo "==> Waiting for Pulsar broker to be ready..."
kubectl wait --for=condition=ready pod \
  -l component=broker -n "$NAMESPACE" --timeout=10m

# ---------------------------------------------------------------------------
# 6. Kubernetes PriorityClasses required by Armada
# ---------------------------------------------------------------------------
echo "==> Creating Armada PriorityClasses..."
kubectl apply -f - <<'YAML'
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: armada-default
value: 1000
globalDefault: false
description: "Default priority class for Armada jobs"
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: armada-preemptible
value: 900
globalDefault: false
description: "Preemptible priority class for Armada jobs"
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: armada-resilient
value: 1100
globalDefault: false
description: "Resilient (high priority) class for Armada jobs"
YAML

# ---------------------------------------------------------------------------
# 7. Armada Operator
# ---------------------------------------------------------------------------
echo "==> Installing Armada Operator..."
helm upgrade -i armada-operator gresearch/armada-operator \
  --namespace "$NAMESPACE" \
  --wait --timeout 5m

# ---------------------------------------------------------------------------
# 8. Armada components (Server, Scheduler, SchedulerIngester, Lookout, Executor)
# ---------------------------------------------------------------------------
echo "==> Applying Armada component CRs..."
ARMADA_POSTGRES_PASSWORD="$PGPASS" envsubst < armada-server.yaml          | kubectl apply -f -
ARMADA_POSTGRES_PASSWORD="$PGPASS" envsubst < armada-scheduler.yaml       | kubectl apply -f -
ARMADA_POSTGRES_PASSWORD="$PGPASS" envsubst < armada-scheduleringester.yaml | kubectl apply -f -
ARMADA_POSTGRES_PASSWORD="$PGPASS" envsubst < armada-lookout.yaml         | kubectl apply -f -
kubectl apply -f armada-executor.yaml

# Executor Deployment created manually due to armada-operator v0.7.0 bug
# (operator generates invalid port spec for the executor Deployment).
# Wait for operator to create ServiceAccount and RBAC first.
echo "==> Waiting for executor RBAC to be created..."
for i in $(seq 1 12); do
  kubectl get serviceaccount armada-executor -n "$NAMESPACE" &>/dev/null && break
  sleep 5
done
kubectl apply -f armada-executor-deployment.yaml

# ---------------------------------------------------------------------------
# 9. Fix Lookout secret key (operator uses old 'lookoutapiPort' key;
#    latest image requires 'apiPort').
# ---------------------------------------------------------------------------
echo "==> Patching Lookout config secret..."
sleep 10  # give operator time to create the secret
NEW_CONFIG=$(printf 'apiPort: 8080\npostgres:\n  connection:\n    dbname: lookout\n    host: armada-postgresql.armada.svc.cluster.local\n    password: %s\n    port: 5432\n    sslmode: disable\n    user: armada\nuiConfig:\n  armadaApiBaseUrl: http://armada-server.armada.svc.cluster.local:8080\n' "$PGPASS")
kubectl patch secret armada-lookout -n "$NAMESPACE" \
  --type='json' \
  -p="[{\"op\":\"replace\",\"path\":\"/data/armada-lookout-config.yaml\",\"value\":\"$(echo "$NEW_CONFIG" | base64 -w0)\"}]" 2>/dev/null || true

echo ""
echo "==> Waiting for Armada pods to be ready..."
for dep in armada-server armada-scheduler armada-scheduleringester armada-lookout armada-executor; do
  kubectl rollout status deployment/$dep -n "$NAMESPACE" --timeout=3m 2>/dev/null || true
done

echo ""
echo "Done! Check pod status with:"
echo "  kubectl get pods -n $NAMESPACE"
echo ""
echo "Lookout UI:  https://armada.carlboettiger.info"
echo "gRPC API:    armada-api.carlboettiger.info:443"
