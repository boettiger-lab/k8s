#!/bin/bash
# Install the OpenEBS ZFS LocalPV driver.
#
# Only the lightweight zfs-localpv driver is needed. The full openebs/openebs umbrella
# chart (Mayastor + its etcd/MinIO/Loki stack, LVM LocalPV, etc.) is overkill for
# node-local ZFS storage and was removed from this cluster -- do NOT reinstall it.
#
# The ZFS pool `tank` is a pre-existing native pool on the host; it is not created here.

set -e
cd "$(dirname "$0")"

CHART_VERSION=2.11.2

# Add ZFS LocalPV repo (separate from the full OpenEBS umbrella repo)
helm repo add openebs-zfs https://openebs.github.io/zfs-localpv
helm repo update

# csi-resizer v2 needs VolumeAttributesClass RBAC the chart lacks (see values.yaml)
kubectl apply -f resizer-vac-rbac.yaml

# Install ZFS LocalPV driver
helm upgrade --install zfs-localpv openebs-zfs/zfs-localpv \
  --version "$CHART_VERSION" \
  -n openebs \
  --create-namespace \
  -f values.yaml \
  --wait

echo ""
echo "✅ ZFS LocalPV driver installed!"
echo ""
echo "Next step:"
echo "  kubectl apply -f platform/openebs/storageclass.yaml"
echo ""
kubectl get pods -n openebs -l role=openebs-zfs
