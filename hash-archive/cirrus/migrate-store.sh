#!/bin/bash
# Copy the existing hash-archive LevelDB store into the k8s PVC.
#
# Source: /minio/hash-archive/hash-archive.db/  (LevelDB dir, ~624 KB)
# Target: PVC hash-archive-data (openebs-zfs -> cirrus `tank`)
#
# IMPORTANT: LevelDB tolerates no concurrent writers, and copying a live store
# can capture an inconsistent snapshot. This script therefore STOPS the Docker
# container first. It does not delete it — roll back with `docker start
# hash-archive` if anything goes wrong.
#
#   sudo /home/cboettig/Documents/boettiger-lab/k8s/hash-archive/cirrus/migrate-store.sh
set -e

SRC=/minio/hash-archive/hash-archive.db
STAGE=/var/tmp/hash-archive-db-stage
NS=hash-archive

[[ -d "$SRC" ]] || { echo "ERROR: $SRC not found"; exit 1; }

echo "== 1. Stopping the Docker container for a consistent copy =="
if docker ps --format '{{.Names}}' | grep -qx hash-archive; then
  docker stop hash-archive
  echo "   stopped (roll back with: docker start hash-archive)"
else
  echo "   not running — continuing"
fi

echo "== 2. Staging $SRC =="
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -a "$SRC"/. "$STAGE"/
# Drop stale lock files — they are recreated on open and copying them can
# confuse a fresh process.
rm -f "$STAGE"/LOCK "$STAGE"/tmp.mdb-lock
chown -R "${SUDO_UID:-0}:${SUDO_GID:-0}" "$STAGE"
ls -la "$STAGE"

echo "== 3. Ensuring namespace + PVC exist =="
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$(dirname "$0")/pvc.yaml"

echo "== 4. Launching a temporary loader pod to populate the PVC =="
kubectl -n "$NS" delete pod store-loader --ignore-not-found --wait=true
kubectl -n "$NS" apply -f - <<'POD'
apiVersion: v1
kind: Pod
metadata:
  name: store-loader
  namespace: hash-archive
spec:
  nodeSelector:
    kubernetes.io/hostname: cirrus
  restartPolicy: Never
  containers:
  - name: loader
    image: busybox:1.36
    command: ["sh","-c","sleep 3600"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: hash-archive-data
POD
kubectl -n "$NS" wait --for=condition=Ready pod/store-loader --timeout=180s

echo "== 5. Copying the store in =="
for f in "$STAGE"/*; do
  echo "   $(basename "$f")"
  kubectl -n "$NS" cp "$f" "store-loader:/data/$(basename "$f")"
done

echo "== 6. Verifying =="
kubectl -n "$NS" exec store-loader -- ls -la /data

echo "== 7. Cleaning up the loader =="
kubectl -n "$NS" delete pod store-loader --wait=true
rm -rf "$STAGE"

echo
echo "Store migrated. Now run ./up.sh"
echo "The Docker container is left STOPPED (not removed) as a rollback point."
