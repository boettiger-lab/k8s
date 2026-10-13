#!/bin/bash
# Install or upgrade Dex. Run ./setup-secrets.sh first.
set -e
cd "$(dirname "$0")"
helm repo add dex https://charts.dexidp.io >/dev/null 2>&1 || true
helm repo update dex
helm upgrade -i dex dex/dex -n dex --create-namespace --version 0.25.2 -f values.yaml
