#!/bin/bash
# Install OpenEBS ZFS LocalPV driver (lightweight - for single-node ZFS storage)
# The full openebs/openebs chart is for replicated storage across multiple nodes
# and is overkill for single-node setups with local ZFS pools.

set -e

# Add ZFS LocalPV repo (separate from the full OpenEBS repo)
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
echo "Next steps:"
echo "  1. Create ZFS pool: sudo bash setup-zfs-pool.sh 2000"
echo "  2. Apply storage class: kubectl apply -f zfs-storage.yml"
echo ""
kubectl get pods -n openebs -l role=openebs-zfs
