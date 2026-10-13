#!/bin/bash
# Create the `dex-github` Secret holding the GitHub OAuth app's client secret.
# The app: GitHub -> Settings -> Developer settings -> OAuth Apps, client ID
# Ov23liOV5rxCR1fEEInJ, callback https://dex.carlboettiger.info/callback.
# Generate a new client secret there if the old one is lost.
set -e
NAMESPACE=dex
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
read -r -s -p "GitHub OAuth client secret: " SECRET; echo
[ -n "$SECRET" ] || { echo "empty secret, aborting" >&2; exit 1; }
kubectl -n "$NAMESPACE" create secret generic dex-github \
  --from-literal=clientSecret="$SECRET" --dry-run=client -o yaml | kubectl apply -f -
echo "dex-github secret set. Run ./up.sh (or restart Dex: kubectl -n dex rollout restart deploy/dex)."
