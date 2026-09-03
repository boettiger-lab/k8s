#!/usr/bin/env bash
# 01-backup-nimbus.sh -- capture everything that exists ONLY in nimbus's
# standalone k3s cluster, before 02-join.sh destroys it.
#
#   ./01-backup-nimbus.sh          # run on nimbus, as cboettig, no sudo needed
#
# k3s-uninstall.sh deletes /var/lib/rancher/k3s -- the entire etcd/sqlite
# datastore. Anything that was only ever `kubectl apply`d and never committed
# (mcp-gpu-nimbus, nimbus-carbon-api) or that cannot be regenerated (the NGC and
# HuggingFace pull credentials) is gone at that moment. This script is the
# difference between a 20-minute migration and a bad afternoon.
#
# Output goes to secrets/nimbus-join-backup/ at the repo root, which is
# git-ignored (the /secrets/ rule in .gitignore). Nothing here is committed.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$REPO_ROOT/secrets/nimbus-join-backup"

# Refuse to run against the wrong cluster. After the join this script would
# otherwise happily dump cirrus's secrets into a local directory.
CTX_NODES="$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"
if [ "$CTX_NODES" != "nimbus" ]; then
    echo "refusing to run: kubectl points at a cluster whose nodes are '$CTX_NODES'," >&2
    echo "not the standalone single-node nimbus cluster this script is for." >&2
    exit 1
fi

mkdir -p "$OUT"
chmod 700 "$OUT"
echo "==> backing up to $OUT"

# --- 1. Secrets that cannot be regenerated from this repo -------------------
# Cert-manager will re-issue every *-tls secret on cirrus, and cf-api-token
# already exists there, so neither is worth carrying over. These four are not
# reproducible without going back to NGC / HuggingFace / GitHub.
echo "==> secrets"
for s in huggingface-token vllm-api-key ngc-pull ghcr-pull; do
    if kubectl -n default get secret "$s" >/dev/null 2>&1; then
        kubectl -n default get secret "$s" -o yaml \
          | python3 -c 'import sys,yaml; d=yaml.safe_load(sys.stdin); m=d["metadata"]; [m.pop(k,None) for k in ("creationTimestamp","resourceVersion","uid","managedFields","namespace","ownerReferences")]; d.pop("status",None); print(yaml.safe_dump(d,default_flow_style=False))' \
          > "$OUT/secret-$s.yaml"
        echo "    saved $s"
    else
        echo "    MISSING $s -- note it and move on"
    fi
done

# --- 2. Live manifests with no source in this repo --------------------------
# mcp-gpu-nimbus and nimbus-carbon-api were applied by hand. Their committed
# copies now live in mcp/nimbus/ and monitoring/nimbus-carbon-api.yaml, but dump
# the running objects anyway so any drift is visible in the diff.
echo "==> live manifests (drift check against the committed copies)"
for obj in deploy/mcp-gpu-nimbus svc/mcp-gpu-nimbus ing/mcp-gpu-nimbus \
           deploy/nimbus-carbon-api svc/nimbus-carbon-api ing/nimbus-carbon-api \
           deploy/qwen38 svc/vllm-nimbus-service ing/vllm-nimbus-ingress; do
    name="$(echo "$obj" | tr / -)"
    kubectl -n default get "$obj" -o yaml > "$OUT/live-$name.yaml" 2>/dev/null \
        && echo "    saved $obj" || echo "    absent $obj"
done

# --- 3. Node-level state ----------------------------------------------------
echo "==> node state"
kubectl get nodes -o yaml            > "$OUT/live-node-nimbus.yaml"
kubectl get pods -A -o wide          > "$OUT/inventory-pods.txt"
kubectl get pvc,pv -A                > "$OUT/inventory-storage.txt"
kubectl get ingress,svc -A           > "$OUT/inventory-endpoints.txt"
cp /etc/rancher/k3s/config.yaml      "$OUT/etc-rancher-k3s-config.yaml" 2>/dev/null || true

echo
echo "==> done. Contents:"
ls -la "$OUT"
echo
echo "Confirm the four secrets are present and non-empty before running 02-join.sh:"
echo "  grep -c . $OUT/secret-*.yaml"
