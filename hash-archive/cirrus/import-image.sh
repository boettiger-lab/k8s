#!/bin/bash
# Import the local Docker image into k3s's containerd.
#
# WHY: `cboettig/hash-archive:latest` exists only in this host's Docker daemon
# (built ~6 years ago, never pushed). k3s uses its own containerd and cannot
# see Docker's image store, so the pod would fail ImagePullBackOff without this.
#
# This is a BRIDGE, not the end state — see README.md "Image provenance".
#
#   sudo /home/cboettig/Documents/boettiger-lab/k8s/hash-archive/cirrus/import-image.sh
set -e

IMAGE="ghcr.io/boettiger-lab/hash-archive:latest"

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "ERROR: $IMAGE not found in the local Docker daemon."
  echo "       Build it first (see the header of this script)."
  exit 1
fi

echo "Exporting $IMAGE from Docker and importing into k3s containerd..."
echo "(~663 MB, takes a minute)"
docker save "$IMAGE" | k3s ctr images import -

echo
echo "Verifying it landed:"
k3s ctr images ls | grep -i hash-archive || {
  echo "ERROR: image not visible to containerd after import"; exit 1; }
echo
echo "OK. The deployment references docker.io/${IMAGE}"
