#!/usr/bin/env bash
set -euo pipefail

# Usage: sudo ./set-write-kubeconfig-mode.sh [MODE]
# Example: sudo ./set-write-kubeconfig-mode.sh 0644
# Sets write-kubeconfig-mode in /etc/rancher/k3s/config.yaml and restarts k3s

MODE=${1:-0644}
CONFIG_DIR=/etc/rancher/k3s
CONFIG_FILE=${CONFIG_DIR}/config.yaml

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run with sudo/root." >&2
  exit 1
fi

mkdir -p "${CONFIG_DIR}"

touch "${CONFIG_FILE}"
if grep -q '^write-kubeconfig-mode:' "${CONFIG_FILE}"; then
  # Replace existing setting
  sed -i "s/^write-kubeconfig-mode:.*/write-kubeconfig-mode: \"${MODE}\"/" "${CONFIG_FILE}"
else
  # Append setting
  echo "write-kubeconfig-mode: \"${MODE}\"" >> "${CONFIG_FILE}"
fi

echo "Updated ${CONFIG_FILE} to set write-kubeconfig-mode: ${MODE}"

echo "Restarting k3s service..."
systemctl restart k3s

echo "Done. Verify permissions:"
ls -l /etc/rancher/k3s/k3s.yaml || true
