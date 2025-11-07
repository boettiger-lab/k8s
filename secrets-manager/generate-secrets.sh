#!/usr/bin/env bash

# generate-secrets.sh
# Helper script to create an opaque Kubernetes Secret from a .env file.

set -euo pipefail

# Directory of this script
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Optional argument: path to .env file (defaults to ./.env)
if [[ $# -ge 1 ]]; then
  # If argument is an absolute path, use it directly; otherwise treat as relative to script directory
  if [[ "$1" = /* ]]; then
    ENV_FILE="$1"
  else
    ENV_FILE="${DIR}/$1"
  fi
else
  ENV_FILE="${DIR}/.env"
fi

OUTPUT_FILE="${DIR}/secret.yaml"

# Verify .env exists
if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Error: .env file not found at ${ENV_FILE}"
  exit 1
fi

# Begin Secret manifest
cat > "${OUTPUT_FILE}" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: app-secret
type: Opaque
data:
EOF

# Process each line in .env
while IFS= read -r line || [[ -n "$line" ]]; do
  # Trim leading/trailing whitespace
  line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  # Skip empty lines and comments
  [[ -z "$line" || "$line" == \#* ]] && continue

  # Split into key and value on the first '='
  key="${line%%=*}"
  value="${line#*=}"

  # Remove possible surrounding quotes from value
  value="$(echo "$value" | sed -e 's/^["'"'"']//' -e 's/["'"'"']$//')"

  # Base64 encode the value (no newline)
  b64_value="$(printf '%s' "$value" | base64 -w 0)"

  # Append to manifest
  printf '  %s: %s\n' "$key" "$b64_value" >> "${OUTPUT_FILE}"
done < "${ENV_FILE}"

echo "Secret manifest generated at ${OUTPUT_FILE}"
