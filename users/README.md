# Namespace-Scoped User Authentication

This directory contains configuration for setting up user authentication with namespace-scoped permissions in K3s.

## Overview

The configuration creates:
- A dedicated namespace named after the user (`$USERID`, defaults to your current `$USER`)
- A ServiceAccount for that user
- A Role with permissions limited to that namespace
- A RoleBinding that connects the ServiceAccount to the Role
- A ClusterRole granting read-only access to cluster Nodes (plus pods/events for better `kubectl describe node`)
- A ClusterRoleBinding that connects the ServiceAccount to the ClusterRole
- A kubeconfig file for the user to access the cluster

## Permissions

The user ($USERID) has the following permissions within the `$USERID` namespace:

- **Core resources**: pods, services, configmaps, secrets, persistentvolumeclaims
- **Apps**: deployments
- **Batch**: jobs
- **Networking**: ingresses

All with full CRUD permissions (get, list, watch, create, update, delete, patch).

The user **cannot**:
- Access or modify other namespaces' resources (except read-only access to pods/events for `describe node`)
- Create or modify cluster-wide resources
- Manage RBAC permissions

## Setup

### Automated Setup (Recommended)

The setup is split into two scripts:

**1. Setup RBAC permissions**:
```bash
# Run with an optional username argument (defaults to your login user)
./setup.sh [USERID]
```

This creates the namespace, ServiceAccount, Role, and RoleBinding.
**2. Generate the user's kubeconfig**:
```bash
./generate-kubeconfig.sh [USERID]
# For remote kubeconfig that works off-box, provide your cluster address (FQDN or IP):
./generate-kubeconfig.sh [USERID] --server nimbus.carlboettiger.info
```
This creates `${USERID}-kubeconfig.yaml` with the user's credentials. 

### Manual Setup

```bash
# 1. Create namespace and apply RBAC (uses templates internally)
./setup.sh [USERID]

# 2. Generate a ServiceAccount token (valid for 1 year)
USERID=${USERID:-$USER}
TOKEN=$(kubectl create token "$USERID" -n "$USERID" --duration=8760h)

# 3. Get cluster connection details (requires to read /etc/rancher/k3s/k3s.yaml)
CLUSTER_NAME=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')
CLUSTER_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CLUSTER_CA=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

# 4. Build the kubeconfig file (no needed - writing to local file)
KCFG="${USERID}-kubeconfig.yaml"

# 4a. Add the cluster information (where to connect)
kubectl config set-cluster ${CLUSTER_NAME} \
  --server=${CLUSTER_SERVER} \
  --certificate-authority-data=${CLUSTER_CA} \
  --kubeconfig=${KCFG} \
  --embed-certs=true

# 4b. Add the user credentials (how to authenticate)
kubectl config set-credentials ${USERID} \
  --token=${TOKEN} \
  --kubeconfig=${KCFG}

# 4c. Create a context (combine cluster + user + default namespace)
kubectl config set-context ${USERID}-context \
  --cluster=${CLUSTER_NAME} \
  --user=${USERID} \
  --namespace=${USERID} \
  --kubeconfig=${KCFG}

# 4d. Set this context as the default
kubectl config use-context ${USERID}-context \
  --kubeconfig=${KCFG}
```

**Note**: These scripts read the admin kubeconfig at `/etc/rancher/k3s/k3s.yaml`. With `write-kubeconfig-mode: 0644` in your k3s setup, this file is world-readable and sudo is not required.

## Using the kubeconfig

Once setup is complete, the user can authenticate using the generated kubeconfig:

```bash
# Use with explicit kubeconfig flag
kubectl --kubeconfig=${USERID}-kubeconfig.yaml get pods

# Or set as default
export KUBECONFIG=/path/to/${USERID}-kubeconfig.yaml
kubectl get pods
```

### Remote access considerations

On k3s, the admin kubeconfig typically points to `https://127.0.0.1:6443`, which won't work from remote machines. To generate a remote-ready kubeconfig, pass your server's hostname or IP when generating the kubeconfig:

```bash
./generate-kubeconfig.sh ${USERID} --server nimbus.carlboettiger.info
```

Alternatively, you can set an environment variable instead of the flag:

```bash
SERVER_ADDRESS=nimbus.carlboettiger.info ./generate-kubeconfig.sh ${USERID}
# or
K3S_SERVER_ADDRESS=nimbus.carlboettiger.info ./generate-kubeconfig.sh ${USERID}
```

If no server is specified and the current cluster server is `127.0.0.1`, the script will try to auto-detect a suitable FQDN or primary IP address.

## Testing

Verify the user has correct permissions:

```bash
# Should work - create a pod in the user's namespace
kubectl --kubeconfig=${USERID}-kubeconfig.yaml run nginx --image=nginx

# Should work - list pods
kubectl --kubeconfig=${USERID}-kubeconfig.yaml get pods

# Should fail - cannot access other namespaces
kubectl --kubeconfig=${USERID}-kubeconfig.yaml get pods -n kube-system

# Should work - can read cluster Nodes
kubectl --kubeconfig=${USERID}-kubeconfig.yaml get nodes

# Should work - can describe a node (may include pods/events if permitted)
kubectl --kubeconfig=${USERID}-kubeconfig.yaml describe node $(kubectl get nodes -o name | head -n1 | cut -d/ -f2)

Note on `describe`:
- `kubectl describe` is a client-side convenience that performs one or more API calls (e.g., `get`, `list`). There is no `describe` verb in Kubernetes RBAC.
- For Nodes, `describe` requires:
  - `get`, `list` on `nodes` (cluster-scoped)
  - optionally `get`, `list` on namespaced `pods` across all namespaces to show the "Non-terminated Pods" section
  - optionally `get`, `list` on namespaced `events` across all namespaces to show related events
```

## Token Expiration

The generated token is valid for 1 year (8760 hours). To renew:

```bash
# Generate new token
NEW_TOKEN=$(kubectl create token ${USERID} -n ${USERID} --duration=8760h)

# Update the kubeconfig
kubectl config set-credentials ${USERID} --token=${NEW_TOKEN} --kubeconfig=${USERID}-kubeconfig.yaml
```

## Modifying Permissions

To add or remove permissions, edit `role.yaml` (namespace-scoped) or `clusterrole.yaml` (cluster-scoped) and reapply:

```bash
env USERID=$USERID envsubst < role.yaml | kubectl apply -f -
env USERID=$USERID envsubst < clusterrole.yaml | kubectl apply -f -
```

Changes take effect immediately without needing to regenerate the kubeconfig.

## Cleanup

To remove the user and all associated resources:

```bash
kubectl delete namespace ${USERID}
```

This will delete the namespace and all resources within it, including the ServiceAccount, Role, and RoleBinding.
