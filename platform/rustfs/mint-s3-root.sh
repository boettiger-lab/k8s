#!/usr/bin/env bash
# Create the root credential for rustfs-s3 (s3.yaml) as Secret rustfs/rustfs-s3-root.
# Generated here and piped into the Secret; never printed or written to disk. Run
# ONCE, before the first start: RustFS records the root key on first boot, so
# rotating it later is a RustFS-side change, not just a new Secret.
# Usage: bash platform/rustfs/mint-s3-root.sh
set -euo pipefail
if kubectl -n rustfs get secret rustfs-s3-root >/dev/null 2>&1; then
  echo "Secret rustfs/rustfs-s3-root already exists; not touching it."; exit 0
fi
kubectl -n rustfs create secret generic rustfs-s3-root \
  --from-literal=access-key="rustfs-s3-$(openssl rand -hex 4)" \
  --from-file=secret-key=<(openssl rand -hex 32 | tr -d '\n')
echo "Secret rustfs/rustfs-s3-root is ready. Read it with:"
echo "  kubectl -n rustfs get secret rustfs-s3-root -o jsonpath='{.data.secret-key}' | base64 -d"
