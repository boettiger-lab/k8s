---
title: "User Access Management"
weight: 1
bookToc: true
---

# User Access Management

Configure namespace-scoped user authentication and access control in K3s.

## Overview

This system provides users with:
- Dedicated namespace for their resources
- ServiceAccount for authentication
- Role-based permissions limited to their namespace
- Read-only access to cluster nodes
- Generated kubeconfig for easy access

## Permissions

Users have **full CRUD permissions** within their namespace for:
- Pods
- Services
- ConfigMaps
- Secrets
- PersistentVolumeClaims
- Deployments
- Jobs
- Ingresses

Users have **read-only access** to:
- Cluster nodes
- Pods and events across namespaces (for `kubectl describe node`)

Users **cannot**:
- Access or modify other namespaces' resources
- Create or modify cluster-wide resources
- Manage RBAC permissions

## Setup

### Automated Setup (Recommended)

The setup process is split into two steps:

#### Step 1: Create RBAC Permissions

```bash
# Run with an optional username argument (defaults to your login user)
./setup.sh [USERID]
```

This script:
- Creates a dedicated namespace named after the user
- Creates a ServiceAccount for the user
- Creates a Role with namespace-scoped permissions
- Creates a RoleBinding connecting the ServiceAccount to the Role
- Creates a ClusterRole for node read access
- Creates a ClusterRoleBinding for cluster-level read access

#### Step 2: Generate Kubeconfig

```bash
# For local access
./generate-kubeconfig.sh [USERID]

# For remote access (specify your cluster's hostname or IP)
./generate-kubeconfig.sh [USERID] --server nimbus.carlboettiger.info
```

This generates `${USERID}-kubeconfig.yaml` with the user's credentials.

**Output**: `${USERID}-kubeconfig.yaml` - Give this file to the user

### Manual Setup

If you need to customize the setup:

```bash
# 1. Set the username
export USERID=myuser

# 2. Create namespace and apply RBAC
kubectl create namespace $USERID
kubectl apply -f users/serviceaccount.yaml
kubectl apply -f users/role.yaml
kubectl apply -f users/rolebinding.yaml
kubectl apply -f users/clusterrole.yaml
kubectl apply -f users/clusterrolebinding.yaml

# 3. Generate a ServiceAccount token (valid for 1 year)
TOKEN=$(kubectl create token "$USERID" -n "$USERID" --duration=8760h)

# 4. Get cluster connection details
CLUSTER_NAME=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')
CLUSTER_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CLUSTER_CA=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

# 5. Create kubeconfig
KCFG="${USERID}-kubeconfig.yaml"

kubectl config set-cluster ${CLUSTER_NAME} \
  --server=${CLUSTER_SERVER} \
  --certificate-authority-data=${CLUSTER_CA} \
  --kubeconfig=${KCFG} \
  --embed-certs=true

kubectl config set-credentials ${USERID} \
  --token=${TOKEN} \
  --kubeconfig=${KCFG}

kubectl config set-context ${USERID}-context \
  --cluster=${CLUSTER_NAME} \
  --user=${USERID} \
  --namespace=${USERID} \
  --kubeconfig=${KCFG}

kubectl config use-context ${USERID}-context \
  --kubeconfig=${KCFG}
```

## Using the Kubeconfig

### For Users

Once you receive your kubeconfig file:

#### Option 1: Replace Default Config

```bash
# Backup existing config (if any)
mv ~/.kube/config ~/.kube/config.backup

# Use your new config
cp your-username-kubeconfig.yaml ~/.kube/config

# Test access
kubectl get pods
```

#### Option 2: Use KUBECONFIG Environment Variable

```bash
# Set for current session
export KUBECONFIG=~/your-username-kubeconfig.yaml

# Test access
kubectl get pods

# Add to your shell profile for persistence
echo 'export KUBECONFIG=~/your-username-kubeconfig.yaml' >> ~/.bashrc
```

#### Option 3: Use with kubectl --kubeconfig Flag

```bash
kubectl --kubeconfig=your-username-kubeconfig.yaml get pods
```

### Verify Access

```bash
# Check current context
kubectl config current-context

# View your permissions
kubectl auth can-i --list

# Test creating a pod
kubectl run nginx --image=nginx
kubectl get pods
kubectl delete pod nginx
```

## Common Operations

### Deploy Applications

Users can deploy applications in their namespace:

```bash
# Create a deployment
kubectl create deployment nginx --image=nginx

# Expose as a service
kubectl expose deployment nginx --port=80

# Create an ingress
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: nginx-ingress
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
spec:
  rules:
  - host: myapp.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: nginx
            port:
              number: 80
  tls:
  - hosts:
    - myapp.example.com
    secretName: nginx-tls
EOF
```

### Create Secrets

```bash
# Create a generic secret
kubectl create secret generic my-secret \
  --from-literal=password=mysecretpassword

# Create from file
kubectl create secret generic my-config \
  --from-file=config.json

# Use in pods
kubectl run app --image=myapp --env-from=secret/my-secret
```

### Use Persistent Storage

```bash
# Create a PVC
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-data
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: openebs-zfs
  resources:
    requests:
      storage: 10Gi
EOF

# Use in a pod
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: my-app
spec:
  containers:
  - name: app
    image: nginx
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: my-data
EOF
```

### View Logs

```bash
# View pod logs
kubectl logs <pod-name>

# Follow logs
kubectl logs -f <pod-name>

# View previous container logs
kubectl logs <pod-name> --previous
```

### Execute Commands in Pods

```bash
# Execute a command
kubectl exec <pod-name> -- ls /

# Interactive shell
kubectl exec -it <pod-name> -- /bin/bash
```

## Management (Administrators)

### List All Users

```bash
# List all namespaces (one per user)
kubectl get namespaces

# List service accounts
kubectl get serviceaccounts --all-namespaces
```

### Revoke User Access

```bash
# Delete the user's namespace (this deletes all their resources!)
kubectl delete namespace <username>

# Or just delete the service account to revoke access
kubectl delete serviceaccount <username> -n <username>
```

### Modify Permissions

Edit the Role to add or remove permissions:

```bash
kubectl edit role <username> -n <username>
```

Example modifications:

```yaml
rules:
# Add networking resources
- apiGroups: ["networking.k8s.io"]
  resources: ["networkpolicies"]
  verbs: ["get", "list", "create", "update", "delete"]

# Add batch resources
- apiGroups: ["batch"]
  resources: ["cronjobs"]
  verbs: ["get", "list", "create", "update", "delete"]
```

### Extend Token Lifetime

Generate a new token with different duration:

```bash
# Generate 2-year token
TOKEN=$(kubectl create token <username> -n <username> --duration=17520h)

# Update kubeconfig with new token
kubectl config set-credentials <username> \
  --token=${TOKEN} \
  --kubeconfig=<username>-kubeconfig.yaml
```

### Monitor User Resources

```bash
# View all resources in user's namespace
kubectl get all -n <username>

# Check resource usage
kubectl top pods -n <username>

# View events
kubectl get events -n <username>
```

## Security Considerations

### Token Security

- Tokens are long-lived (1 year by default)
- Treat kubeconfig files as sensitive credentials
- Set appropriate file permissions: `chmod 600 ~/.kube/config`
- Don't commit kubeconfig files to version control
- Rotate tokens regularly

### Network Security

Users' pods are subject to:
- Namespace isolation
- Network policies (if configured)
- Resource quotas (if configured)

### Resource Limits

Consider setting ResourceQuotas per namespace:

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: user-quota
  namespace: <username>
spec:
  hard:
    requests.cpu: "10"
    requests.memory: "20Gi"
    requests.storage: "100Gi"
    persistentvolumeclaims: "10"
    pods: "20"
```

Apply quotas:

```bash
kubectl apply -f user-quota.yaml
```

## Troubleshooting

### Connection Refused

1. **Check server address** in kubeconfig:
```bash
kubectl config view --minify
```

2. **Verify port 6443 is accessible**:
```bash
telnet <server-address> 6443
```

3. **Check firewall rules**:
```bash
sudo ufw status
```

### Forbidden Errors

1. **Verify token is valid**:
```bash
kubectl auth whoami
```

2. **Check permissions**:
```bash
kubectl auth can-i get pods
kubectl auth can-i create deployments
```

3. **Verify ServiceAccount exists**:
```bash
kubectl get serviceaccount <username> -n <username>
```

### Cannot Create Resources

1. **Check you're in the right namespace**:
```bash
kubectl config get-contexts
```

2. **Try specifying namespace explicitly**:
```bash
kubectl get pods -n <username>
```

3. **Check for ResourceQuotas**:
```bash
kubectl describe resourcequota -n <username>
```

## Best Practices

1. **Use Strong Usernames**: Avoid special characters in usernames
2. **Regular Token Rotation**: Rotate tokens periodically (e.g., every 6 months)
3. **Principle of Least Privilege**: Only grant necessary permissions
4. **Resource Quotas**: Set quotas to prevent resource exhaustion
5. **Monitoring**: Regularly audit user activities
6. **Backup**: Keep backups of kubeconfig generation scripts
7. **Documentation**: Document custom permissions for users

## Example Workflows

### Deploying a Web Application

```bash
# Create deployment
kubectl create deployment webapp --image=nginx

# Create service
kubectl expose deployment webapp --port=80 --target-port=80

# Create ingress with HTTPS
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: webapp-ingress
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
spec:
  rules:
  - host: myapp.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: webapp
            port:
              number: 80
  tls:
  - hosts:
    - myapp.example.com
    secretName: webapp-tls
EOF

# Check status
kubectl get ingress
kubectl get certificate
```

### Running a Job

```bash
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: data-processing
spec:
  template:
    spec:
      containers:
      - name: processor
        image: python:3.9
        command: ["python", "-c", "print('Processing data...')"]
      restartPolicy: Never
  backoffLimit: 3
EOF

# Watch job progress
kubectl get jobs -w

# View logs
kubectl logs job/data-processing
```

## Related Resources

- [Kubernetes RBAC Documentation](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)
- [ServiceAccount Documentation](https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/)
- [Kubectl Cheat Sheet](https://kubernetes.io/docs/reference/kubectl/cheatsheet/)
- [K3s Installation Guide]({{< relref "../infrastructure/k3s" >}})
