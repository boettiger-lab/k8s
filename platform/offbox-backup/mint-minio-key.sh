#!/usr/bin/env bash
# Create (or rotate) the read-only source key for the off-box copy, and store it as
# Secret offbox-backup/offbox-source. The secret is generated here and piped
# straight into MinIO and Kubernetes; it is never printed or written to disk.
#
# The key can list every bucket and read every object, and nothing else. At the
# RustFS cutover it is carried over by the IAM import, so the Secret stays valid.
#
# Usage: bash platform/offbox-backup/mint-minio-key.sh
set -euo pipefail
NS=offbox-backup
USER_NAME=offbox-read
POLICY=offbox-read
MINIO=(kubectl -n minio exec -i deploy/minio-deployment --)

SECRET=$(openssl rand -hex 32)

POLICY_JSON='{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Action":["s3:ListAllMyBuckets","s3:GetBucketLocation","s3:ListBucket","s3:GetObject"],
 "Resource":["arn:aws:s3:::*"]}]}'

# mc inside the MinIO pod, with a throwaway config dir; the secret arrives on stdin.
printf '%s\n%s\n' "$SECRET" "$POLICY_JSON" | "${MINIO[@]}" sh -c '
  set -e
  export MC_CONFIG_DIR=$(mktemp -d)
  trap "rm -rf $MC_CONFIG_DIR /tmp/offbox-policy.json" EXIT
  read -r SK
  cat > /tmp/offbox-policy.json
  mc alias set l http://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
  mc admin policy create l '"$POLICY"' /tmp/offbox-policy.json
  mc admin user add l '"$USER_NAME"' "$SK" >/dev/null && echo "user '"$USER_NAME"' set"
  mc admin policy attach l '"$POLICY"' --user '"$USER_NAME"' >/dev/null 2>&1 || true
  mc admin user info l '"$USER_NAME"' | grep -E "Status|PolicyName"
'

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
printf '%s' "$SECRET" | kubectl -n "$NS" create secret generic offbox-source \
  --from-literal=access-key-id="$USER_NAME" \
  --from-file=secret-access-key=/dev/stdin \
  --dry-run=client -o yaml | kubectl apply -f -
echo "Secret $NS/offbox-source is ready."
