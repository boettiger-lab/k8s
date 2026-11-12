#!/usr/bin/env bash
# Copy bucket settings MinIO -> rustfs-s3: anonymous policy, lifecycle rules,
# versioning, quota. Creates any missing bucket. The bulk copy (bulk-copy.yaml)
# moves objects only; this moves the rest. Re-runnable: run it now and again at
# the cutover to pick up buckets and changes made since.
#
# Reads with MinIO's root inside the MinIO pod; writes with rustfs-s3's root from a
# throwaway pod in namespace rustfs (the MinIO image, for its mc). No credential
# leaves either cluster Secret; the settings themselves are not secret.
#
# Usage: bash platform/rustfs/copy-bucket-settings.sh [--dry-run]
set -euo pipefail
DRY=${1:-}
IMAGE=quay.io/minio/minio@sha256:14cea493d9a34af32f524e538b8346cf79f3321eff8e708c1e2960462bd8936e
POD=s3-settings-copy
WORK=$(mktemp -d); trap 'rm -rf "$WORK"; kubectl -n rustfs delete pod "$POD" --ignore-not-found --wait=false >/dev/null' EXIT

# 1. Export every bucket's settings from MinIO as tagged JSON lines.
kubectl -n minio exec deploy/minio-deployment -- sh -c '
  export MC_CONFIG_DIR=$(mktemp -d); trap "rm -rf $MC_CONFIG_DIR" EXIT
  mc alias set l http://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
  for b in $(mc ls l/ --json | while read -r line; do k=${line#*\"key\":\"}; echo "${k%%/*}"; done); do
    echo "@@ $b"
    mc --json anonymous get-json "l/$b"
    mc --json ilm rule export "l/$b" 2>&1
    mc --json version info "l/$b"
    mc --json quota info "l/$b" 2>&1
  done' > "$WORK/export.txt"

# 2. Turn it into an mc script for rustfs-s3.
python3 - "$WORK/export.txt" > "$WORK/apply.sh" <<'PY'
import json, sys, shlex
buckets, cur = {}, None
for line in open(sys.argv[1]):
    line = line.strip()
    if line.startswith("@@ "):
        cur = line[3:]; buckets[cur] = {}; continue
    if not line.startswith("{") or cur is None: continue
    d = json.loads(line)
    if d.get("status") != "success": continue
    if "anonymous" in d: buckets[cur]["policy"] = d["anonymous"]
    elif "config" in d and "Rules" in d["config"]: buckets[cur]["ilm"] = d["config"]
    elif "versioning" in d: buckets[cur]["versioning"] = d["versioning"]["status"]
    elif "quota" in d: buckets[cur]["quota"] = d["quota"]
if len(buckets) < 100:
    sys.exit(f"only {len(buckets)} buckets exported; refusing")
out = ["set -e"]
summary = {"policy": 0, "ilm": 0, "versioning": 0, "quota": 0}
for b, s in sorted(buckets.items()):
    q = shlex.quote
    out.append(f"mc mb --ignore-existing d/{q(b)} >/dev/null")
    if "policy" in s:
        out.append(f"cat > /tmp/p.json <<'JSON'\n{json.dumps(s['policy'])}\nJSON")
        out.append(f"mc anonymous set-json /tmp/p.json d/{q(b)} >/dev/null"); summary["policy"] += 1
    if "ilm" in s:
        out.append(f"mc ilm import d/{q(b)} >/dev/null <<'JSON'\n{json.dumps(s['ilm'])}\nJSON"); summary["ilm"] += 1
    if s.get("versioning") == "Enabled":
        out.append(f"mc version enable d/{q(b)} >/dev/null"); summary["versioning"] += 1
    if s.get("quota"):
        out.append(f"mc quota set d/{q(b)} --size {int(s['quota'])}B >/dev/null"); summary["quota"] += 1
    out.append(f"echo ok {q(b)}")
print("\n".join(out))
print(f"# {len(buckets)} buckets; " + ", ".join(f"{k} {v}" for k, v in summary.items()), file=sys.stderr)
PY

if [ "$DRY" = "--dry-run" ]; then cat "$WORK/apply.sh"; exit 0; fi

# 3. Apply from a throwaway pod holding rustfs-s3's root key.
kubectl -n rustfs run "$POD" --image="$IMAGE" --restart=Never --command \
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"cirrus"},"containers":[{"name":"'"$POD"'","image":"'"$IMAGE"'","command":["sleep","3600"],
    "env":[{"name":"AK","valueFrom":{"secretKeyRef":{"name":"rustfs-s3-root","key":"access-key"}}},
           {"name":"SK","valueFrom":{"secretKeyRef":{"name":"rustfs-s3-root","key":"secret-key"}}}]}]}}' \
  -- sleep 3600 >/dev/null
kubectl -n rustfs wait pod/"$POD" --for=condition=Ready --timeout=120s >/dev/null
{ echo 'export MC_CONFIG_DIR=$(mktemp -d); mc alias set d http://rustfs-s3.rustfs.svc:9000 "$AK" "$SK" >/dev/null'
  cat "$WORK/apply.sh"; } | kubectl -n rustfs exec -i "$POD" -- sh | grep -c '^ok ' | sed 's/^/buckets configured: /'
