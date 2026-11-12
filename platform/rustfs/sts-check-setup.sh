#!/usr/bin/env bash
# One-time setup for sts-check.sh: deploy Dex's `rustfs-s3` client, roll rustfs-s3
# with the OIDC settings in s3.yaml, and create the test bucket `sts-test` plus the
# test policy `boettiger-lab:owners` (access only to sts-test/users/<GitHub login>/).
# Remove the test policy and bucket afterwards with: bash sts-check-setup.sh --remove
set -euo pipefail
cd "$(dirname "$0")/../.."
IMAGE=quay.io/minio/minio@sha256:14cea493d9a34af32f524e538b8346cf79f3321eff8e708c1e2960462bd8936e
POD=s3-sts-setup

mc_pod() {   # run an mc script inside a throwaway pod holding rustfs-s3's root key
  kubectl -n rustfs run "$POD" --image="$IMAGE" --restart=Never --command \
    --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"cirrus"},"containers":[{"name":"'"$POD"'","image":"'"$IMAGE"'","command":["sleep","600"],
      "env":[{"name":"AK","valueFrom":{"secretKeyRef":{"name":"rustfs-s3-root","key":"access-key"}}},
             {"name":"SK","valueFrom":{"secretKeyRef":{"name":"rustfs-s3-root","key":"secret-key"}}}]}]}}' \
    -- sleep 600 >/dev/null
  trap 'kubectl -n rustfs delete pod "$POD" --wait=false >/dev/null 2>&1' EXIT
  kubectl -n rustfs wait pod/"$POD" --for=condition=Ready --timeout=120s >/dev/null
  { echo 'export MC_CONFIG_DIR=/tmp/mc; mc alias set d http://rustfs-s3.rustfs.svc:9000 "$AK" "$SK" >/dev/null'; cat; } \
    | kubectl -n rustfs exec -i "$POD" -- sh
}

if [ "${1:-}" = "--remove" ]; then
  mc_pod <<'SH'
mc admin policy rm d boettiger-lab:owners
mc rb --force d/sts-test
SH
  exit 0
fi

bash platform/dex/up.sh
kubectl -n dex rollout status deploy/dex --timeout=120s
kubectl apply -f platform/rustfs/s3.yaml
kubectl -n rustfs rollout status deploy/rustfs-s3 --timeout=300s

mc_pod <<'SH'
set -e
mc mb --ignore-existing d/sts-test
cat > /tmp/p.json <<'JSON'
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["s3:ListBucket"],"Resource":["arn:aws:s3:::sts-test"],
  "Condition":{"StringLike":{"s3:prefix":["users/${jwt:preferred_username}/","users/${jwt:preferred_username}/*"]}}},
 {"Effect":"Allow","Action":["s3:GetObject","s3:PutObject","s3:DeleteObject"],
  "Resource":["arn:aws:s3:::sts-test/users/${jwt:preferred_username}/*"]}]}
JSON
mc admin policy create d boettiger-lab:owners /tmp/p.json
mc admin policy info d boettiger-lab:owners >/dev/null && echo "policy boettiger-lab:owners ready"
SH
echo "Setup done. Next: bash platform/rustfs/sts-check.sh"
