#!/usr/bin/env bash
# Create (or rotate) Postgres role `pg_exporter` (pg_monitor only) on the JuiceFS
# metadata DB, and Secret juicefs/pg-exporter for postgres_exporter. The password
# is generated here and passed on stdin; it is never printed or written to disk.
# Usage: bash platform/juicefs/mint-pg-exporter-role.sh
set -euo pipefail
PW=$(openssl rand -hex 32)
kubectl -n juicefs exec -i deploy/juicefs-pg -- psql -q -U juicefs -d juicefs -v ON_ERROR_STOP=1 <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'pg_exporter') THEN
    CREATE ROLE pg_exporter LOGIN;
  END IF;
END \$\$;
ALTER ROLE pg_exporter WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD '$PW' CONNECTION LIMIT 3;
GRANT pg_monitor TO pg_exporter;
SQL
echo "postgres role pg_exporter set (pg_monitor, connection limit 3)"
kubectl -n juicefs create secret generic pg-exporter \
  --from-file=password=<(printf '%s' "$PW") \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n juicefs rollout restart deploy/pg-exporter 2>/dev/null || true
echo "Secret juicefs/pg-exporter is ready."
