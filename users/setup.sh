#!/bin/bash

# Setup RBAC permissions for namespace-scoped user authentication in K3s
# This creates the namespace, ServiceAccount, Role, and RoleBinding
# Requires cluster admin access via kubeconfig (e.g., ~/.kube/config)

# USERID can be provided as first argument, or via env; defaults to invoking user (or SUDO_USER when run with sudo)
USERID_INPUT="$1"
if [ -n "$USERID_INPUT" ]; then
	USERID="$USERID_INPUT"
else
	USERID="${USERID:-${SUDO_USER:-$USER}}"
fi
NAMESPACE="${USERID}"

echo "Using USERID=${USERID} (namespace=${NAMESPACE})"

echo "Creating namespace: ${NAMESPACE}"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo "Applying RBAC configuration (templated with USERID) ..."
# Ensure USERID is available to envsubst
export USERID

# Render templates and apply
for f in serviceaccount.yaml role.yaml rolebinding.yaml; do
	if [ -f "$f" ]; then
		envsubst < "$f" | kubectl apply -f -
	else
		echo "Missing file: $f" >&2
		exit 1
	fi
done

echo ""
echo "RBAC setup complete!"
echo ""
echo "Next step: Generate the kubeconfig file"
echo "  ./generate-kubeconfig.sh ${USERID} --server <your-cluster-hostname-or-ip>"
echo "    e.g., ./generate-kubeconfig.sh ${USERID} --server nimbus.carlboettiger.info"
