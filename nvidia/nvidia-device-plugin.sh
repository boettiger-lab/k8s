#!/bin/bash
# Install/upgrade the NVIDIA device plugin (+ node-feature-discovery subchart).
#
# nvidia-device-plugin-config.yaml carries the tolerations for BOTH tainted
# nodes -- nimbus (dedicated=nimbus) and thelio (hub.jupyter.org/dedicated=user)
# -- in a single list. Applying it against the wrong cluster, or with a stale
# copy of that file, is how a GPU node stops advertising nvidia.com/gpu.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

# Guard the context. nimbus keeps two kubeconfigs side by side during the join
# (its own, and ~/.kube/cirrus-config), and this script is a bare `helm upgrade`
# against whichever is active -- so running it one export too early would
# reinstall the plugin on nimbus's soon-to-be-destroyed standalone cluster
# instead of preparing cirrus. See ../k3s/nimbus-join/README.md step 2.
NODES="$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
if ! echo "$NODES" | grep -qx cirrus; then
    echo "refusing to run: kubectl sees nodes [$(echo "$NODES" | tr '\n' ' ')]," >&2
    echo "but not cirrus. This chart is cluster-wide and belongs on the cirrus" >&2
    echo "cluster. Set KUBECONFIG (e.g. ~/.kube/cirrus-config) and re-run." >&2
    exit 1
fi
echo "==> cluster nodes: $(echo "$NODES" | tr '\n' ' ')"

helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm repo update nvdp

# check available versions
#helm search repo nvdp --devel

helm upgrade -i nvdp nvdp/nvidia-device-plugin \
  --namespace nvidia-device-plugin \
  --create-namespace \
  --version 0.19.2 \
  --wait \
  --values nvidia-device-plugin-config.yaml

# Every GPU node should have a plugin pod. A node missing here is almost always
# a taint with no matching toleration in the values file.
echo
kubectl get pods -n nvidia-device-plugin -o wide
