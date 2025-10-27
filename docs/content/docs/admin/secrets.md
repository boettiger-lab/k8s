---
title: "Secrets Management"
weight: 2
bookToc: true
---

# Secrets Management

Best practices and tools for managing sensitive data in Kubernetes.

## Overview

Kubernetes secrets are used to store sensitive information such as:
- Passwords and API tokens
- TLS certificates
- SSH keys
- OAuth credentials
- Database connection strings

## Creating Secrets

### From Literal Values

```bash
kubectl create secret generic my-secret \
  --from-literal=username=admin \
  --from-literal=password=secret123 \
  -n <namespace>
```

### From Files

```bash
# Single file
kubectl create secret generic my-secret \
  --from-file=config.json \
  -n <namespace>

# Multiple files
kubectl create secret generic my-secret \
  --from-file=ssh-privatekey=~/.ssh/id_rsa \
  --from-file=ssh-publickey=~/.ssh/id_rsa.pub \
  -n <namespace>
```

### From Environment File

```bash
# Create .env file
cat > .env <<EOF
USERNAME=admin
PASSWORD=secret123
API_KEY=abc123xyz
EOF

# Create secret
kubectl create secret generic my-secret \
  --from-env-file=.env \
  -n <namespace>

# Clean up
rm .env
```

### TLS Secrets

```bash
kubectl create secret tls my-tls-secret \
  --cert=path/to/cert.crt \
  --key=path/to/key.key \
  -n <namespace>
```

### Docker Registry Secrets

```bash
kubectl create secret docker-registry regcred \
  --docker-server=registry.example.com \
  --docker-username=user \
  --docker-password=password \
  --docker-email=user@example.com \
  -n <namespace>
```

## Using Secrets in Pods

### As Environment Variables

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-pod
spec:
  containers:
  - name: app
    image: myapp
    env:
    - name: USERNAME
      valueFrom:
        secretKeyRef:
          name: my-secret
          key: username
    - name: PASSWORD
      valueFrom:
        secretKeyRef:
          name: my-secret
          key: password
```

### All Secret Keys as Environment Variables

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-pod
spec:
  containers:
  - name: app
    image: myapp
    envFrom:
    - secretRef:
        name: my-secret
```

### As Mounted Files

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-pod
spec:
  containers:
  - name: app
    image: myapp
    volumeMounts:
    - name: secret-volume
      mountPath: /etc/secrets
      readOnly: true
  volumes:
  - name: secret-volume
    secret:
      secretName: my-secret
```

This creates files in `/etc/secrets/` with filenames as keys and contents as values.

### Specific Keys as Files

```yaml
volumes:
- name: secret-volume
  secret:
    secretName: my-secret
    items:
    - key: username
      path: credentials/username.txt
    - key: password
      path: credentials/password.txt
```

## Managing Secrets

### View Secrets

```bash
# List secrets
kubectl get secrets -n <namespace>

# View secret metadata (not values)
kubectl describe secret my-secret -n <namespace>

# View secret YAML (values are base64 encoded)
kubectl get secret my-secret -n <namespace> -o yaml

# Decode a specific key
kubectl get secret my-secret -n <namespace> -o jsonpath='{.data.password}' | base64 -d
```

### Update Secrets

```bash
# Edit directly
kubectl edit secret my-secret -n <namespace>

# Or recreate
kubectl delete secret my-secret -n <namespace>
kubectl create secret generic my-secret \
  --from-literal=password=newpassword \
  -n <namespace>

# Or patch
kubectl patch secret my-secret -n <namespace> \
  -p '{"data":{"password":"'$(echo -n newpassword | base64)'"}}'
```

### Delete Secrets

```bash
kubectl delete secret my-secret -n <namespace>
```

## Best Practices

### 1. Never Commit Secrets to Git

Add to `.gitignore`:

```
# Secrets
secrets.sh
*.env
*-secret.yaml
kubeconfig*
*.key
*.pem
```

### 2. Use Separate Files for Secrets

Create template files:

```bash
# secrets.sh.example
export DB_PASSWORD="CHANGE_ME"
export API_KEY="CHANGE_ME"
```

Users copy and customize:

```bash
cp secrets.sh.example secrets.sh
# Edit secrets.sh with actual values
```

### 3. Limit Secret Access

Use RBAC to restrict secret access:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: secret-reader
  namespace: default
rules:
- apiGroups: [""]
  resources: ["secrets"]
  resourceNames: ["specific-secret"]
  verbs: ["get"]
```

### 4. Rotate Secrets Regularly

```bash
# Example rotation script
NEW_PASSWORD=$(openssl rand -base64 32)

kubectl patch secret my-secret -n <namespace> \
  -p '{"data":{"password":"'$(echo -n $NEW_PASSWORD | base64)'"}}'

# Update applications to use new password
kubectl rollout restart deployment/my-app -n <namespace>
```

### 5. Use Namespaces for Isolation

Create secrets in appropriate namespaces:

```bash
kubectl create secret generic db-secret \
  --from-literal=password=secret123 \
  -n production

kubectl create secret generic db-secret \
  --from-literal=password=devpass \
  -n development
```

### 6. Encrypt Secrets at Rest

Enable encryption at rest in K3s by creating an encryption configuration.

### 7. Use External Secret Managers

Consider using external secret managers for production:
- HashiCorp Vault
- AWS Secrets Manager
- Azure Key Vault
- External Secrets Operator

## Secret Management Scripts

### Helper Script for Setting Secrets

```bash
#!/bin/bash
# set-secret.sh

NAMESPACE=${1:-default}
SECRET_NAME=${2:-my-secret}

# Prompt for values
read -p "Enter username: " USERNAME
read -sp "Enter password: " PASSWORD
echo

# Create secret
kubectl create secret generic $SECRET_NAME \
  --from-literal=username=$USERNAME \
  --from-literal=password=$PASSWORD \
  -n $NAMESPACE \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Secret $SECRET_NAME created/updated in namespace $NAMESPACE"
```

Usage:

```bash
chmod +x set-secret.sh
./set-secret.sh production db-credentials
```

### Backup Secrets

```bash
#!/bin/bash
# backup-secrets.sh

NAMESPACE=${1:-default}
OUTPUT_DIR="secrets-backup-$(date +%Y%m%d)"

mkdir -p $OUTPUT_DIR

kubectl get secrets -n $NAMESPACE -o json | \
  jq -r '.items[] | select(.type=="Opaque") | .metadata.name' | \
  while read secret; do
    kubectl get secret $secret -n $NAMESPACE -o yaml > "$OUTPUT_DIR/${secret}.yaml"
  done

echo "Secrets backed up to $OUTPUT_DIR"
```

### Restore Secrets

```bash
#!/bin/bash
# restore-secrets.sh

BACKUP_DIR=$1
NAMESPACE=${2:-default}

if [ -z "$BACKUP_DIR" ]; then
  echo "Usage: $0 <backup-directory> [namespace]"
  exit 1
fi

for file in $BACKUP_DIR/*.yaml; do
  kubectl apply -f $file -n $NAMESPACE
done

echo "Secrets restored to namespace $NAMESPACE"
```

## Common Secret Patterns

### Database Credentials

```bash
kubectl create secret generic postgres-secret \
  --from-literal=postgres-user=dbuser \
  --from-literal=postgres-password=dbpass123 \
  --from-literal=postgres-db=mydb \
  -n default
```

Usage:

```yaml
env:
- name: POSTGRES_USER
  valueFrom:
    secretKeyRef:
      name: postgres-secret
      key: postgres-user
- name: POSTGRES_PASSWORD
  valueFrom:
    secretKeyRef:
      name: postgres-secret
      key: postgres-password
```

### API Tokens

```bash
kubectl create secret generic api-tokens \
  --from-literal=github-token=ghp_xxx \
  --from-literal=cloudflare-token=xxx \
  -n default
```

### OAuth Credentials

```bash
kubectl create secret generic oauth-credentials \
  --from-literal=client-id=xxx \
  --from-literal=client-secret=yyy \
  --from-literal=callback-url=https://example.com/callback \
  -n default
```

### SSH Keys

```bash
kubectl create secret generic ssh-key \
  --from-file=ssh-privatekey=$HOME/.ssh/id_rsa \
  --from-file=ssh-publickey=$HOME/.ssh/id_rsa.pub \
  -n default
```

## Troubleshooting

### Secret Not Found

```bash
# Verify secret exists
kubectl get secrets -n <namespace>

# Check secret is in correct namespace
kubectl get secrets --all-namespaces | grep my-secret
```

### Incorrect Values

```bash
# Decode and verify
kubectl get secret my-secret -n <namespace> -o json | \
  jq -r '.data | to_entries[] | "\(.key): \(.value | @base64d)"'
```

### Pod Can't Access Secret

1. **Check secret exists in same namespace**:
```bash
kubectl get secret my-secret -n <namespace>
```

2. **Verify secret name in pod spec**:
```bash
kubectl get pod <pod-name> -n <namespace> -o yaml | grep -A 5 secret
```

3. **Check RBAC permissions**:
```bash
kubectl auth can-i get secrets --as=system:serviceaccount:<namespace>:<serviceaccount>
```

### Base64 Encoding Issues

```bash
# Correct encoding
echo -n "password" | base64

# Incorrect (includes newline)
echo "password" | base64
```

Always use `-n` flag with echo to avoid trailing newlines.

## Related Resources

- [Kubernetes Secrets Documentation](https://kubernetes.io/docs/concepts/configuration/secret/)
- [External Secrets Operator](https://external-secrets.io/)
- [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets)
- [HashiCorp Vault](https://www.vaultproject.io/)
