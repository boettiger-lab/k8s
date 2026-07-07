#!/bin/bash
# Install OpenEBS ZFS LocalPV driver on the active cluster (cirrus + thelio).
#
# Only the lightweight zfs-localpv driver is needed here. The full openebs/openebs
# umbrella chart (Mayastor + its etcd/MinIO/Loki stack, LVM LocalPV, etc.) is overkill
# for single-node-pool ZFS storage and was removed from this cluster -- do NOT reinstall it.
#
# The ZFS pool `tank` is a pre-existing native pool on both nodes; it is not created here.

set -e

# Add ZFS LocalPV repo (separate from the full OpenEBS umbrella repo)
helm repo add openebs-zfs https://openebs.github.io/zfs-localpv
helm repo update

# Install ZFS LocalPV driver
helm upgrade --install zfs-localpv openebs-zfs/zfs-localpv \
  -n openebs \
  --create-namespace \
  --wait

echo ""
echo "✅ ZFS LocalPV driver installed!"
echo ""
echo "Next step:"
echo "  kubectl apply -f openebs/cirrus/zfs-storage.yml"
echo ""
kubectl get pods -n openebs -l role=openebs-zfs
