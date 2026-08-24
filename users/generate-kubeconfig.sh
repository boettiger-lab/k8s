#!/bin/bash

# Generate a kubeconfig file for a namespace-scoped user
# This reads cluster config and creates a user kubeconfig that can be used locally or remotely.
#
# Usage:
#   ./generate-kubeconfig.sh [USERID] [--server <HOSTNAME_OR_IP[:PORT]>]
#
# You can also set the server address via environment variable:
#   SERVER_ADDRESS="nimbus.carlboettiger.info" ./generate-kubeconfig.sh [USERID]
# or
#   K3S_SERVER_ADDRESS="nimbus.carlboettiger.info" ./generate-kubeconfig.sh [USERID]
#
# Notes:
# - If no server override is provided, the cluster server from the current kubeconfig is used.
#   On k3s, this may be https://127.0.0.1:6443 which will NOT work from remote machines.
#   In that case, this script will attempt to auto-detect a better address (FQDN or primary IP).

set -euo pipefail

# Helper: normalize a host/URL into https://HOST:PORT if needed
normalize_server() {
  local input="$1"
  # If input already starts with http, leave scheme as-is
  if [[ "$input" =~ ^https?:// ]]; then
    echo "$input"
    return 0
  fi
  # If input looks like host:port, use that; else append :6443
  if [[ "$input" == *:* ]]; then
    echo "https://$input"
  else
    echo "https://$input:6443"
  fi
}

# Parse args
USERID_INPUT="${1:-}"
SERVER_OVERRIDE=""

if [[ $# -ge 2 ]]; then
  # Support: ./generate-kubeconfig.sh USERID --server HOST
  if [[ "${2:-}" == "--server" ]]; then
    SERVER_OVERRIDE="${3:-}"
    if [[ -z "$SERVER_OVERRIDE" ]]; then
      echo "Error: --server requires an argument" >&2
      exit 1
    fi
  fi
fi

# Also allow env var overrides
if [[ -z "$SERVER_OVERRIDE" ]]; then
  SERVER_OVERRIDE="${SERVER_ADDRESS:-${K3S_SERVER_ADDRESS:-}}"
fi

# USERID can be provided as first argument, or via env; defaults to invoking user (or SUDO_USER when run with sudo)
if [ -n "$USERID_INPUT" ] && [[ "$USERID_INPUT" != "--server"* ]]; then
  USERID="$USERID_INPUT"
else
  USERID="${USERID:-${SUDO_USER:-$USER}}"
fi
NAMESPACE="${USERID}"
USERNAME="${USERID}"
KUBECONFIG_FILE="${USERNAME}-kubeconfig.yaml"

echo "Generating kubeconfig for user: ${USERNAME} (namespace=${NAMESPACE})"

# Create a long-lived token (1 year)
TOKEN=$(kubectl create token "${USERNAME}" -n "${NAMESPACE}" --duration=8760h)

# Get cluster info (requires reading admin kubeconfig)
CLUSTER_NAME=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')
CLUSTER_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CLUSTER_CA=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

# Determine the server address to use in the generated kubeconfig
USE_SERVER="$CLUSTER_SERVER"

# If a server override is provided (CLI or ENV), use it
if [[ -n "$SERVER_OVERRIDE" ]]; then
  USE_SERVER="$(normalize_server "$SERVER_OVERRIDE")"
  echo "Using provided server: $USE_SERVER"
else
  # If the current server points to localhost, attempt auto-detect
  if [[ "$CLUSTER_SERVER" =~ 127\.0\.0\.1|localhost ]]; then
    # Prefer FQDN when available
    FQDN=$(hostname -f 2>/dev/null || true)
    if [[ -n "$FQDN" && "$FQDN" != "localhost" && "$FQDN" == *.* ]]; then
      USE_SERVER="$(normalize_server "$FQDN")"
      echo "Detected FQDN, using server: $USE_SERVER"
    else
      # Fallback to primary IP
      PRIMARY_IP=$(hostname -I | awk '{print $1}')
      if [[ -n "$PRIMARY_IP" ]]; then
        USE_SERVER="$(normalize_server "$PRIMARY_IP")"
        echo "Detected IP, using server: $USE_SERVER"
      else
        echo "Warning: Could not auto-detect a non-localhost server address; using $CLUSTER_SERVER" >&2
      fi
    fi
  fi
fi

# Write CA cert to temp file
CA_FILE=$(mktemp)
echo "${CLUSTER_CA}" | base64 -d > "${CA_FILE}"

# Create kubeconfig for the user (no sudo needed - writing to local file)
kubectl config set-cluster "${CLUSTER_NAME}" \
  --server="${USE_SERVER}" \
  --certificate-authority="${CA_FILE}" \
  --kubeconfig="${KUBECONFIG_FILE}" \
  --embed-certs=true

# Clean up temp file
rm -f "${CA_FILE}"

kubectl config set-credentials "${USERNAME}" \
  --token="${TOKEN}" \
  --kubeconfig="${KUBECONFIG_FILE}"

kubectl config set-context "${USERNAME}-context" \
  --cluster="${CLUSTER_NAME}" \
  --user="${USERNAME}" \
  --namespace="${NAMESPACE}" \
  --kubeconfig="${KUBECONFIG_FILE}"

kubectl config use-context "${USERNAME}-context" \
  --kubeconfig="${KUBECONFIG_FILE}"

# Fix ownership if run with sudo
if [ -n "${SUDO_USER:-}" ]; then
  chown "$SUDO_USER":"$SUDO_USER" "${KUBECONFIG_FILE}"
fi

echo ""
echo "Kubeconfig generated: ${KUBECONFIG_FILE}"
echo ""
echo "Test the configuration with:"
echo "  kubectl --kubeconfig=${KUBECONFIG_FILE} get pods"
echo ""
echo "Or set as default:"
echo "  export KUBECONFIG=$(pwd)/${KUBECONFIG_FILE}"

if [[ -n "${SERVER_OVERRIDE}" ]]; then
  echo ""
  echo "Server endpoint used: ${USE_SERVER}"
  echo "This kubeconfig should work from remote machines without edits."
else
  echo ""
  echo "Note: If this kubeconfig fails remotely and points to 127.0.0.1, regenerate with a server override, e.g.:"
  echo "  sudo ./generate-kubeconfig.sh ${USERID} --server nimbus.carlboettiger.info"
fi
