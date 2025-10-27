#!/usr/bin/env bash
set -euo pipefail

# Usage: ./configure-remote-access.sh [SERVER_ADDRESS]
# Generates a kubeconfig file that can be used from a remote machine
# If no argument is provided, attempts to use the FQDN or falls back to IP address
#
# Examples:
#   ./configure-remote-access.sh                        # Auto-detect (tries FQDN first)
#   ./configure-remote-access.sh nimbus.carlboettiger.info
#   ./configure-remote-access.sh 192.168.1.100

# Get the server address
if [ $# -eq 0 ]; then
  # Try to get the fully qualified domain name first
  SERVER_FQDN=$(hostname -f 2>/dev/null || true)
  
  if [ -n "$SERVER_FQDN" ] && [ "$SERVER_FQDN" != "localhost" ] && [[ "$SERVER_FQDN" == *.* ]]; then
    SERVER_ADDRESS="$SERVER_FQDN"
    echo "Using FQDN: $SERVER_ADDRESS"
  else
    echo "No FQDN found, detecting server IP address..."
    # Try to get the main IP address (non-loopback)
    SERVER_ADDRESS=$(hostname -I | awk '{print $1}')
    if [ -z "$SERVER_ADDRESS" ]; then
      echo "Could not auto-detect address. Please provide it as an argument:"
      echo "  $0 <server-hostname-or-ip>"
      echo ""
      echo "Examples:"
      echo "  $0 nimbus.carlboettiger.info"
      echo "  $0 192.168.1.100"
      exit 1
    fi
    echo "Detected IP: $SERVER_ADDRESS"
  fi
else
  SERVER_ADDRESS=$1
  echo "Using provided address: $SERVER_ADDRESS"
fi

# Check if k3s.yaml exists
K3S_CONFIG="/etc/rancher/k3s/k3s.yaml"
if [ ! -f "$K3S_CONFIG" ]; then
  echo "Error: K3s config file not found at $K3S_CONFIG"
  echo "Is K3s installed?"
  exit 1
fi

# Check if we can read it
if [ ! -r "$K3S_CONFIG" ]; then
  echo "Error: Cannot read $K3S_CONFIG"
  echo "Run with sudo or ensure the file has appropriate permissions."
  echo "You can run: sudo ./set-write-kubeconfig-mode.sh 0644"
  exit 1
fi

# Create remote kubeconfig
OUTPUT_FILE="k3s-remote-kubeconfig.yaml"
echo "Creating remote kubeconfig at: $OUTPUT_FILE"

# Replace 127.0.0.1 with the actual server address
sed "s/127.0.0.1:6443/${SERVER_ADDRESS}:6443/g" "$K3S_CONFIG" > "$OUTPUT_FILE"

echo ""
echo "✓ Remote kubeconfig created successfully!"
echo ""
echo "Server address: https://${SERVER_ADDRESS}:6443"
echo "Output file: $OUTPUT_FILE"
echo ""
echo "To use from a remote machine:"
echo "  1. Copy this file to your remote machine:"
echo "     scp $OUTPUT_FILE user@remote-machine:~/.kube/config"
echo ""
echo "  2. Or use it directly with kubectl:"
echo "     kubectl --kubeconfig=$OUTPUT_FILE get nodes"
echo ""
echo "  3. Or set it as your default kubeconfig:"
echo "     export KUBECONFIG=\$HOME/.kube/k3s-config"
echo "     cp $OUTPUT_FILE \$HOME/.kube/k3s-config"
echo ""
echo "⚠️  SECURITY NOTE:"
echo "  - This kubeconfig contains admin credentials with full cluster access"
echo "  - Keep it secure and transfer it safely (use scp, not email/chat)"
echo "  - Consider creating namespace-scoped users instead (see ../users/README.md)"
echo "  - Ensure port 6443 is accessible on the k3s server (firewall rules)"
echo ""
