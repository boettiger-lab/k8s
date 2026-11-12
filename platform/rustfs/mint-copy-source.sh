#!/usr/bin/env bash
# Create (or rotate) the read-only MinIO key the bulk copy into rustfs-s3 reads with,
# and store it as Secret rustfs/minio-copy-source. The secret is generated here and
# piped straight into MinIO and Kubernetes; it is never printed or written to disk.
#
# Its own user (not the off-box backup's), so it can be revoked on its own once the
# cutover is done:  mc admin user remove <alias> rustfs-copy
#
# Usage: bash platform/rustfs/mint-copy-source.sh   (safe to re-run: rotates the secret)
# The MinIO image has no grep/sed; keep the in-pod part to mc and sh builtins.
set -euo pipefail
NS=rustfs
USER_NAME=rustfs-copy
POLICY=rustfs-copy-read
MINIO=(kubectl -n minio exec -i deploy/minio-deployment --)

SECRET=$(openssl rand -hex 32)

POLICY_JSON='{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Action":["s3:ListAllMyBuckets","s3:GetBucketLocation","s3:ListBucket","s3:GetObject"],
 "Resource":["arn:aws:s3:::*"]}]}'

printf '%s\n%s\n' "$SECRET" "$POLICY_JSON" | "${MINIO[@]}" sh -c '
  set -e
  export MC_CONFIG_DIR=$(mktemp -d)
  trap "rm -rf $MC_CONFIG_DIR /tmp/copy-policy.json" EXIT
  read -r SK
  cat > /tmp/copy-policy.json
  mc alias set l http://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
  mc admin policy create l '"$POLICY"' /tmp/copy-policy.json
  mc admin user add l '"$USER_NAME"' "$SK" >/dev/null && echo "user '"$USER_NAME"' set"
  mc admin policy attach l '"$POLICY"' --user '"$USER_NAME"' >/dev/null 2>&1 || true
  mc admin user info l '"$USER_NAME"'
'

printf '%s' "$SECRET" | kubectl -n "$NS" create secret generic minio-copy-source \
  --from-literal=access-key-id="$USER_NAME" \
  --from-file=secret-access-key=/dev/stdin \
  --dry-run=client -o yaml | kubectl apply -f -
echo "Secret $NS/minio-copy-source is ready."
