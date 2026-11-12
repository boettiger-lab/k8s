#!/usr/bin/env bash
# Read-only access to the JuiceFS homes for the off-box copy, stored as Secret
# offbox-backup/offbox-juicefs:
#   - a RustFS user `offbox-read` on the pilot RustFS, Get/List on `juicefs-homes` only;
#   - a Postgres role `offbox_dump` with `pg_read_all_data` on the JuiceFS metadata DB.
# Secrets are generated here and never printed or written to disk (the RustFS one is
# briefly an argument to the local mc process, as `mc admin user add` requires).
# Safe to re-run: it rotates both.
#
# Needs: kubectl, mc (local), openssl.
# Usage: bash platform/offbox-backup/mint-juicefs-access.sh
set -euo pipefail
NS=offbox-backup
RS_USER=offbox-read
RS_POLICY=offbox-juicefs-homes-read
PG_ROLE=offbox_dump
PORT=19100

RS_SECRET=$(openssl rand -hex 32)
PG_SECRET=$(openssl rand -hex 32)

# --- RustFS (pilot): local mc through a port-forward, throwaway mc config.
export MC_CONFIG_DIR=$(mktemp -d)
POL=$(mktemp)
kubectl -n rustfs port-forward svc/rustfs $PORT:9000 >/dev/null 2>&1 & PF=$!
trap 'kill $PF 2>/dev/null; rm -rf "$MC_CONFIG_DIR" "$POL"' EXIT
sleep 3
RS_ROOT_AK=$(kubectl -n rustfs get secret rustfs-secrets -o jsonpath='{.data.access-key}' | base64 -d)
RS_ROOT_SK=$(kubectl -n rustfs get secret rustfs-secrets -o jsonpath='{.data.secret-key}' | base64 -d)
mc alias set rs "http://localhost:$PORT" "$RS_ROOT_AK" "$RS_ROOT_SK" >/dev/null
unset RS_ROOT_AK RS_ROOT_SK
cat > "$POL" <<'JSON'
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["s3:GetBucketLocation","s3:ListBucket"],"Resource":["arn:aws:s3:::juicefs-homes"]},
 {"Effect":"Allow","Action":["s3:GetObject"],"Resource":["arn:aws:s3:::juicefs-homes/*"]}]}
JSON
mc admin policy create rs "$RS_POLICY" "$POL"
mc admin user add rs "$RS_USER" "$RS_SECRET" >/dev/null && echo "rustfs user $RS_USER set"
mc admin policy attach rs "$RS_POLICY" --user "$RS_USER" >/dev/null 2>&1 || true
mc admin user info rs "$RS_USER"

# --- Postgres: SQL on stdin, so the password never appears in an argv.
kubectl -n juicefs exec -i deploy/juicefs-pg -- psql -q -U juicefs -d juicefs -v ON_ERROR_STOP=1 <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$PG_ROLE') THEN
    CREATE ROLE $PG_ROLE LOGIN;
  END IF;
END \$\$;
ALTER ROLE $PG_ROLE WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD '$PG_SECRET';
GRANT pg_read_all_data TO $PG_ROLE;
SQL
echo "postgres role $PG_ROLE set (pg_read_all_data)"

# --- Secret
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$NS" create secret generic offbox-juicefs \
  --from-literal=homes-access-key="$RS_USER" \
  --from-file=homes-secret-key=<(printf '%s' "$RS_SECRET") \
  --from-file=pg-password=<(printf '%s' "$PG_SECRET") \
  --dry-run=client -o yaml | kubectl apply -f -
echo "Secret $NS/offbox-juicefs is ready."
