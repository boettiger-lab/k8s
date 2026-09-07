# PostgreSQL on Kubernetes

This directory contains the Kubernetes manifests and scripts to deploy PostgreSQL on your cluster.

## Quick Start

1. **Set up secrets:**
   ```bash
   cp secrets.sh.example secrets.sh
   # Edit secrets.sh with your actual password
   ```

2. **Deploy PostgreSQL:**
   ```bash
   chmod +x deploy.sh
   ./deploy.sh
   ```

3. **Connect to PostgreSQL:**
   - From within the cluster: `psql -h postgres-service.postgres.svc.cluster.local -U postgres -d postgres`
   - From outside (port-forward): `kubectl port-forward service/postgres-service 5432:5432 -n postgres`

4. **Clean up:**
   ```bash
   chmod +x cleanup.sh
   ./cleanup.sh
   ```

## Files

- `secrets.sh.example` - Template for secrets configuration (copy to `secrets.sh`)
- `secrets.sh` - Your actual secrets (gitignored, create from example)
- `.gitignore` - Ensures secrets don't get committed
- `postgres-pvc.yaml` - Persistent Volume Claim for data storage (10Gi)
- `postgres-deployment.yaml` - PostgreSQL deployment with health checks
- `postgres-service.yaml` - Service to expose PostgreSQL within the cluster
- `deploy.sh` - Script to deploy all resources
- `cleanup.sh` - Script to remove all resources

## Configuration

### Default Credentials

Credentials are set in your local `secrets.sh` file:
- **Host:** postgres-service.postgres.svc.cluster.local
- **Port:** 5432
- **Database:** Set in `secrets.sh` (default: postgres)
- **Username:** Set in `secrets.sh` (default: postgres)
- **Password:** Set in `secrets.sh`

⚠️ **Security Note:** Never commit `secrets.sh` to version control!

### Storage
- Default storage request: 10Gi
- Access mode: ReadWriteOnce
- You may need to specify a `storageClassName` in `postgres-pvc.yaml` depending on your cluster setup

### Resource Limits
- Memory: 256Mi request, 512Mi limit
- CPU: 250m request, 500m limit

## Customization

### Changing Credentials
Edit your local `secrets.sh` file:
```bash
export POSTGRES_PASSWORD="your-new-secure-password"
export POSTGRES_DB="your-database-name"
export POSTGRES_USER="your-username"
```

### Storage Class
If your cluster uses a specific storage class, uncomment and modify the `storageClassName` in `postgres-pvc.yaml`.

### PostgreSQL Version
To use a different PostgreSQL version, modify the `image` field in `postgres-deployment.yaml`:
```yaml
image: postgres:14  # or postgres:13, postgres:16, etc.
```

## Connection Examples

### From a Pod in the Cluster
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: postgres-client
  namespace: postgres
spec:
  containers:
  - name: postgres-client
    image: postgres:17
    command: ['sh', '-c', 'sleep 3600']
    env:
    - name: PGPASSWORD
      value: "postgres123"
```

Then exec into the pod:
```bash
kubectl exec -it postgres-client -n postgres -- psql -h postgres-service.postgres.svc.cluster.local -U postgres -d postgres
```

### Environment Variables for Applications
```yaml
env:
- name: DATABASE_URL
  value: "postgresql://postgres:postgres123@postgres-service.postgres.svc.cluster.local:5432/postgres"
- name: POSTGRES_HOST
  value: "postgres-service.postgres.svc.cluster.local"
- name: POSTGRES_PORT
  value: "5432"
- name: POSTGRES_DB
  value: "postgres"
- name: POSTGRES_USER
  value: "postgres"
- name: POSTGRES_PASSWORD
  valueFrom:
    secretKeyRef:
      name: postgres-secret
      key: postgres-password
```

## Troubleshooting

### Check Pod Status
```bash
kubectl get pods -l app=postgres -n postgres
kubectl describe pod -l app=postgres -n postgres
```

### Check Logs
```bash
kubectl logs -l app=postgres -n postgres
```

### Check PVC Status
```bash
kubectl get pvc postgres-pvc -n postgres
```

### Test Connection
```bash
kubectl run postgres-client --rm -i --tty --image postgres:17 -n postgres -- psql -h postgres-service.postgres.svc.cluster.local -U postgres -d postgres
```

## High Availability Notes

This setup deploys a single PostgreSQL instance. For production environments, consider:

1. **PostgreSQL Operator** - Use operators like Zalando's PostgreSQL Operator or Crunchy Data PostgreSQL Operator
2. **Backup Strategy** - Implement automated backups using tools like pgBackRest or Barman
3. **Monitoring** - Add monitoring with tools like pg_stat_statements and exporters for Prometheus
4. **Resource Tuning** - Adjust memory and CPU limits based on your workload

## Security Considerations

1. **Change Default Password** - Always change the default password in production
2. **Network Policies** - Consider implementing Kubernetes Network Policies to restrict access
3. **TLS** - Configure SSL/TLS for encrypted connections
4. **RBAC** - Use Kubernetes RBAC to control access to PostgreSQL resources
