#!/usr/bin/env bash
# MinIO -> rustfs-s3 cutover (cluster-ops object-store-migration.md, "Cutover").
# Run by the owner, in an announced midweek window (not Saturday).
#
#   bash platform/rustfs/cutover.sh               # the cutover
#   bash platform/rustfs/cutover.sh --rollback D  # undo, D = the backup dir it printed
#
# Before: NRP's minio-sync and minio-anon-reconcile suspended (the script asks), and
# s3-cutover-certs.yaml applied (it checks). MinIO itself is never modified or
# deleted here: it is scaled to 0, so rollback is a scale-up.
#
# Downtime runs from step 2 (MinIO's public hosts dropped) to step 7 (hosts on RustFS):
# a final copy pass (~10 min) plus a few minutes. In-cluster clients keep reaching
# MinIO until step 6, so the final pass may miss their last writes; the counts it
# prints show any gap.
set -euo pipefail
cd "$(dirname "$0")/../.."
IMAGE=quay.io/minio/minio@sha256:14cea493d9a34af32f524e538b8346cf79f3321eff8e708c1e2960462bd8936e
say() { printf '\n== %s\n' "$*"; }
die() { echo "ABORT: $*" >&2; exit 1; }

clean_yaml() {  # strip server-set fields so a saved object can be re-applied
  python3 -c '
import sys, yaml
d = yaml.safe_load(sys.stdin)
m = d["metadata"]
for k in ("uid","resourceVersion","creationTimestamp","generation","managedFields","selfLink"): m.pop(k, None)
m.get("annotations", {}).pop("kubectl.kubernetes.io/last-applied-configuration", None)
d.pop("status", None)
s = d.get("spec", {})
for k in ("clusterIP","clusterIPs"): s.pop(k, None)
print(yaml.safe_dump(d, sort_keys=False))'
}

if [ "${1:-}" = "--rollback" ]; then
  B=${2:?usage: --rollback <backup dir>}
  echo "Rolling back. Writes made to rustfs-s3 since the cutover are NOT copied back to MinIO."
  read -r -p "Type 'rollback' to continue: " a; [ "$a" = rollback ] || exit 1
  kubectl delete -f platform/rustfs/s3-cutover-ingress.yaml --ignore-not-found
  kubectl -n minio delete svc minio-svc --ignore-not-found
  kubectl apply -f "$B/minio-svc.yaml" -f "$B/minio-ingress.yaml" -f "$B/data-ingress.yaml"
  kubectl -n minio scale deploy/minio-deployment --replicas=1
  kubectl -n minio rollout status deploy/minio-deployment --timeout=300s
  echo "MinIO is back on minio. and data. and minio-svc. Resume the NRP jobs."
  exit 0
fi

say "1. Preflight"
kubectl -n rustfs rollout status deploy/rustfs-s3 --timeout=30s >/dev/null || die "rustfs-s3 not ready"
for c in minio-alias-tls data-console-tls; do
  [ "$(kubectl -n rustfs get certificate $c -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ] \
    || die "certificate rustfs/$c not Ready: kubectl apply -f platform/rustfs/s3-cutover-certs.yaml, wait, re-run"
done
# Any NetworkPolicy that admits MinIO but not rustfs-s3 would cut its pods off.
bad=$(kubectl get netpol -A -o json | python3 -c '
import json, sys
for p in json.load(sys.stdin)["items"]:
    eg = json.dumps(p["spec"].get("egress", []))
    if "minio" in eg and "rustfs" not in eg:
        print(p["metadata"]["namespace"] + "/" + p["metadata"]["name"])')
# jupyter/singleuser names the minio namespace but also allows all private IPs.
bad=$(echo "$bad" | grep -v -x 'jupyter/singleuser' || true)
[ -z "$bad" ] || die "these NetworkPolicies allow MinIO but not rustfs-s3: $bad"
echo "rustfs-s3 ready; certificates ready; NetworkPolicies admit rustfs-s3"
read -r -p "Are NRP's minio-sync and minio-anon-reconcile suspended, and the window announced? (yes) " a
[ "$a" = yes ] || die "not confirmed"

B=$HOME/tmp/s3-cutover-backup-$(date -u +%Y%m%dT%H%M%SZ); mkdir -p "$B"
kubectl -n minio get svc minio-svc -o yaml | clean_yaml > "$B/minio-svc.yaml"
for i in minio-ingress data-ingress; do kubectl -n minio get ingress $i -o yaml | clean_yaml > "$B/$i.yaml"; done
echo "Backup of MinIO's Service and Ingresses (for --rollback): $B"

say "2. Drop MinIO's public hosts (downtime starts)"
kubectl -n minio delete ingress minio-ingress data-ingress

say "3. Final copy pass"
J=s3-copy-final-$(date -u +%m%d%H%M)
kubectl -n rustfs create job --from=cronjob/s3-bulk-copy "$J"
kubectl -n rustfs wait job/"$J" --for=jsonpath='{.status.conditions[?(@.status=="True")].type}' --timeout=3h >/dev/null
kubectl -n rustfs logs job/"$J" | grep -E '^[0-9]{2}:.*(FAILED|SKIP|ABORT|done)' || true
if [ "$(kubectl -n rustfs get job "$J" -o jsonpath='{.status.succeeded}')" != 1 ]; then
  echo "Final pass FAILED (logs: kubectl -n rustfs logs job/$J). MinIO is still running."
  echo "Fix and re-run this script, or roll back: bash $0 --rollback $B"; exit 1
fi
kubectl -n rustfs logs job/"$J" | grep ' src=' | python3 -c '
import sys, re
d = []
for l in sys.stdin:
    (sc, sb), (dc, db) = [(int(a), int(b)) for a, b in re.findall(r"\{(\d+),(\d+)\}", l.replace("\"", ""))]
    if (sc, sb) != (dc, db): d.append(f"{l.split()[0]} ({sc-dc:+d} objects)")
print("counts match" if not d else "still differing (live in-cluster writers): " + ", ".join(d))'

say "4. Users, policies and keys: MinIO IAM export -> rustfs-s3 import"
POD=s3-cutover-iam
kubectl -n rustfs run "$POD" --image="$IMAGE" --restart=Never --command \
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"cirrus"},"containers":[{"name":"'"$POD"'","image":"'"$IMAGE"'","command":["sleep","900"],
    "env":[{"name":"AK","valueFrom":{"secretKeyRef":{"name":"rustfs-s3-root","key":"access-key"}}},
           {"name":"SK","valueFrom":{"secretKeyRef":{"name":"rustfs-s3-root","key":"secret-key"}}}]}]}}' \
  -- sleep 900 >/dev/null
trap 'kubectl -n rustfs delete pod '"$POD"' --wait=false >/dev/null 2>&1' EXIT
kubectl -n rustfs wait pod/"$POD" --for=condition=Ready --timeout=120s >/dev/null
# The export holds every user's secret: it goes pod -> pipe -> pod and is deleted on both ends.
kubectl -n minio exec deploy/minio-deployment -- sh -c '
  set -e; export MC_CONFIG_DIR=$(mktemp -d); W=$(mktemp -d); trap "rm -rf $MC_CONFIG_DIR $W" EXIT
  mc alias set l http://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
  mc -q admin cluster iam export l -o "$W/iam.zip" >/dev/null; cat "$W/iam.zip"' \
| kubectl -n rustfs exec -i "$POD" -- sh -c '
  set -e; export MC_CONFIG_DIR=/tmp/mc; trap "rm -f /tmp/iam.zip" EXIT
  cat > /tmp/iam.zip
  mc alias set d http://rustfs-s3.rustfs.svc:9000 "$AK" "$SK" >/dev/null
  mc admin cluster iam import d /tmp/iam.zip'
m=$(kubectl -n minio exec deploy/minio-deployment -- sh -c 'export MC_CONFIG_DIR=$(mktemp -d); mc alias set l http://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null; mc admin user list l; rm -rf $MC_CONFIG_DIR' | wc -l)
r=$(kubectl -n rustfs exec "$POD" -- sh -c 'export MC_CONFIG_DIR=/tmp/mc; mc admin user list d' | wc -l)
echo "users: MinIO $m, rustfs-s3 $r"
[ "$r" -ge "$m" ] || die "rustfs-s3 has fewer users than MinIO. MinIO is still running; investigate, then re-run or roll back: bash $0 --rollback $B"

say "5. Bucket settings (anonymous policies, lifecycle, versioning)"
bash platform/rustfs/copy-bucket-settings.sh

say "6. Stop MinIO (scaled to 0, data untouched)"
kubectl -n minio scale deploy/minio-deployment --replicas=0
kubectl -n minio wait pod -l k8s-app=minio-app --for=delete --timeout=180s || true

say "7. Switch: minio. and data. -> rustfs-s3; minio-svc -> alias of rustfs-s3"
kubectl apply -f platform/rustfs/s3-cutover-ingress.yaml
kubectl -n minio delete svc minio-svc
kubectl apply -f platform/rustfs/s3-cutover-minio-svc.yaml
# The bulk copy would now sync rustfs-s3 onto itself.
kubectl -n rustfs delete cronjob s3-bulk-copy --ignore-not-found

say "8. Verify"
sleep 10
for u in https://minio.carlboettiger.info/public-dem https://s3.carlboettiger.info/public-dem; do
  printf '%-45s anonymous list %s\n' "$u" "$(curl -s -o /dev/null -w '%{http_code}' "$u?list-type=2&max-keys=1")"
done
printf '%-45s %s\n' https://data.carlboettiger.info "$(curl -s -o /dev/null -w '%{http_code}' https://data.carlboettiger.info/)"
# An imported key, through the in-cluster alias: offbox-read must list every bucket.
kubectl -n offbox-backup run s3-cutover-verify --image=rclone/rclone:1.75.2 --restart=Never --rm -i --quiet \
  --overrides='{"spec":{"containers":[{"name":"s3-cutover-verify","image":"rclone/rclone:1.75.2","args":["lsd","src:"],
    "env":[{"name":"RCLONE_CONFIG_SRC_TYPE","value":"s3"},{"name":"RCLONE_CONFIG_SRC_PROVIDER","value":"Other"},
           {"name":"RCLONE_CONFIG_SRC_FORCE_PATH_STYLE","value":"true"},
           {"name":"RCLONE_CONFIG_SRC_ENDPOINT","value":"http://minio-svc.minio.svc:9000"},
           {"name":"RCLONE_CONFIG_SRC_ACCESS_KEY_ID","valueFrom":{"secretKeyRef":{"name":"offbox-source","key":"access-key-id"}}},
           {"name":"RCLONE_CONFIG_SRC_SECRET_ACCESS_KEY","valueFrom":{"secretKeyRef":{"name":"offbox-source","key":"secret-access-key"}}}]}]}}' \
  | wc -l | sed 's/^/offbox-read key via minio-svc: buckets listed = /'

cat <<MSG

Cutover done. Next:
  - resume NRP's minio-sync and minio-anon-reconcile (unchanged: same keys, minio. host)
  - from NRP: check-backup-coverage.sh, check-backup-freshness.sh, check-pins.sh
  - rollback, if needed: bash $0 --rollback $B
  - MinIO stays scaled to 0, data intact, until the rollback window ends
MSG
