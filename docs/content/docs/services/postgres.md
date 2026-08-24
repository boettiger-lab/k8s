---
title: "PostgreSQL"
weight: 2
bookToc: true
---

# PostgreSQL

Deploy PostgreSQL database on Kubernetes with persistent storage.

## Overview

PostgreSQL is deployed as a stateful service with:
- Persistent volume for data storage
- Health checks and readiness probes
- Internal cluster service access
- Optional external access via ingress
- Automatic restarts on failure

## Quick Start

### 1. Set Up Secrets

Copy the example secrets file and configure your credentials:

```bash
cd postgres
cp secrets.sh.example secrets.sh
# Edit secrets.sh with your actual password
nano secrets.sh
```

Example `secrets.sh`:

```bash
export POSTGRES_PASSWORD="your-secure-password"
export POSTGRES_DB="postgres"
export POSTGRES_USER="postgres"
```

### 2. Deploy PostgreSQL

```bash
chmod +x deploy.sh
./deploy.sh
```

This script:
- Creates the `postgres` namespace
- Creates Kubernetes secrets
- Deploys PostgreSQL with persistent storage
- Creates a service for cluster access

### 3. Verify Deployment

```bash
# Check pod status
kubectl get pods -n postgres

# Check service
kubectl get svc -n postgres

# View logs
kubectl logs -n postgres deployment/postgres
```

### 4. Connect to PostgreSQL

**From within the cluster**:

```bash
psql -h postgres-service.postgres.svc.cluster.local -U postgres -d postgres
```

**From your local machine** (using port-forward):

```bash
kubectl port-forward service/postgres-service 5432:5432 -n postgres
psql -h localhost -U postgres -d postgres
```

### 5. Clean Up

```bash
chmod +x cleanup.sh
./cleanup.sh
```

## Configuration

### Files

- `secrets.sh.example` - Template for secrets configuration
- `secrets.sh` - Your actual secrets (gitignored)
- `postgres-pvc.yaml` - Persistent Volume Claim (10Gi)
- `postgres-deployment.yaml` - PostgreSQL deployment
- `postgres-service.yaml` - Service for cluster access
- `postgres-ingress.yaml` - Optional external access
- `deploy.sh` - Deployment script
- `cleanup.sh` - Cleanup script

### Default Credentials

Configure in your `secrets.sh` file:

- **Host**: `postgres-service.postgres.svc.cluster.local`
- **Port**: `5432`
- **Database**: Defined in secrets (default: `postgres`)
- **Username**: Defined in secrets (default: `postgres`)
- **Password**: Defined in secrets

**⚠️ Security Note**: Never commit `secrets.sh` to version control!

### Storage

Default configuration:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-pvc
  namespace: postgres
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
  # storageClassName: openebs-zfs  # Uncomment for specific storage class
```

**Customization**:
- Default storage: 10Gi
- Access mode: ReadWriteOnce (single-node access)
- Specify `storageClassName` for specific storage backend

### Resource Limits

Default limits in `postgres-deployment.yaml`:

```yaml
resources:
  limits:
    memory: "512Mi"
    cpu: "500m"
  requests:
    memory: "256Mi"
    cpu: "250m"
```

Adjust based on your workload requirements.

### PostgreSQL Version

Modify the image tag in `postgres-deployment.yaml`:

```yaml
containers:
- name: postgres
  image: postgres:17  # or postgres:13, postgres:14, postgres:16, etc.
```

## Usage

### Connection from Pods

Create a pod with PostgreSQL client:

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
      valueFrom:
        secretKeyRef:
          name: postgres-secret
          key: postgres-password
```

Connect from the pod:

```bash
kubectl exec -it postgres-client -n postgres -- psql \
  -h postgres-service.postgres.svc.cluster.local \
  -U postgres \
  -d postgres
```

### Connection String

For applications:

```
postgresql://postgres:password@postgres-service.postgres.svc.cluster.local:5432/postgres
```

### Using Environment Variables

Configure applications with environment variables:

```yaml
env:
- name: POSTGRES_HOST
  value: "postgres-service.postgres.svc.cluster.local"
- name: POSTGRES_PORT
  value: "5432"
- name: POSTGRES_DB
  value: "postgres"
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

## Management

### Create Database

```bash
kubectl exec -it deployment/postgres -n postgres -- \
  psql -U postgres -c "CREATE DATABASE mydb;"
```

### Create User

```bash
kubectl exec -it deployment/postgres -n postgres -- \
  psql -U postgres -c "CREATE USER myuser WITH PASSWORD 'mypassword';"
  
kubectl exec -it deployment/postgres -n postgres -- \
  psql -U postgres -c "GRANT ALL PRIVILEGES ON DATABASE mydb TO myuser;"
```

### Run SQL Script

```bash
kubectl cp script.sql postgres/postgres-deployment-xxxxx:/tmp/script.sql
kubectl exec -it deployment/postgres -n postgres -- \
  psql -U postgres -f /tmp/script.sql
```

### View Logs

```bash
kubectl logs -n postgres deployment/postgres -f
```

### Restart PostgreSQL

```bash
kubectl rollout restart deployment/postgres -n postgres
```

## Backup and Recovery

### Manual Backup

```bash
# Backup to file
kubectl exec deployment/postgres -n postgres -- \
  pg_dump -U postgres postgres > backup.sql

# Backup specific database
kubectl exec deployment/postgres -n postgres -- \
  pg_dump -U postgres mydb > mydb_backup.sql

# Compressed backup
kubectl exec deployment/postgres -n postgres -- \
  pg_dump -U postgres postgres | gzip > backup.sql.gz
```

### Restore from Backup

```bash
# Restore from SQL file
kubectl cp backup.sql postgres/postgres-deployment-xxxxx:/tmp/backup.sql
kubectl exec -it deployment/postgres -n postgres -- \
  psql -U postgres -d postgres -f /tmp/backup.sql

# Restore from compressed backup
gunzip -c backup.sql.gz | \
  kubectl exec -i deployment/postgres -n postgres -- \
  psql -U postgres -d postgres
```

### Automated Backups

Create a CronJob for automated backups:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: postgres-backup
  namespace: postgres
spec:
  schedule: "0 2 * * *"  # Daily at 2 AM
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: backup
            image: postgres:17
            env:
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef:
                  name: postgres-secret
                  key: postgres-password
            command:
            - /bin/sh
            - -c
            - |
              pg_dump -h postgres-service.postgres.svc.cluster.local \
                -U postgres postgres > /backup/backup-$(date +%Y%m%d).sql
            volumeMounts:
            - name: backup-volume
              mountPath: /backup
          restartPolicy: OnFailure
          volumes:
          - name: backup-volume
            persistentVolumeClaim:
              claimName: postgres-backup-pvc
```

### Backup to S3/MinIO

```bash
# Create backup and upload to MinIO
kubectl exec deployment/postgres -n postgres -- \
  pg_dump -U postgres postgres | \
  aws s3 cp - s3://backups/postgres/backup-$(date +%Y%m%d).sql \
    --endpoint-url https://minio.carlboettiger.info
```

## External Access

### Via Ingress (TCP)

PostgreSQL requires TCP ingress, which is more complex than HTTP. 

Option 1: Use `postgres-ingress.yaml` (requires TCP ingress configuration in Traefik)

Option 2: Use `kubectl port-forward` (recommended for occasional access)

```bash
kubectl port-forward service/postgres-service 5432:5432 -n postgres
```

Option 3: Use a LoadBalancer service (if available):

```yaml
apiVersion: v1
kind: Service
metadata:
  name: postgres-external
  namespace: postgres
spec:
  type: LoadBalancer
  ports:
  - port: 5432
    targetPort: 5432
  selector:
    app: postgres
```

## Monitoring

### Check Database Size

```bash
kubectl exec deployment/postgres -n postgres -- \
  psql -U postgres -c "SELECT pg_size_pretty(pg_database_size('postgres'));"
```

### Check Connections

```bash
kubectl exec deployment/postgres -n postgres -- \
  psql -U postgres -c "SELECT count(*) FROM pg_stat_activity;"
```

### Check Tables

```bash
kubectl exec deployment/postgres -n postgres -- \
  psql -U postgres -d postgres -c "\dt"
```

### Storage Usage

```bash
# Check PVC usage
kubectl exec deployment/postgres -n postgres -- df -h /var/lib/postgresql/data
```

## Troubleshooting

### Pod Not Starting

```bash
# Check pod status
kubectl describe pod -n postgres <pod-name>

# View logs
kubectl logs -n postgres deployment/postgres

# Common issues:
# - PVC not binding
# - Insufficient resources
# - Secret not found
```

### Connection Refused

1. **Verify service**:
```bash
kubectl get svc -n postgres
kubectl describe svc postgres-service -n postgres
```

2. **Check pod is running**:
```bash
kubectl get pods -n postgres
```

3. **Test from another pod**:
```bash
kubectl run -it --rm debug --image=postgres:17 --restart=Never -- \
  psql -h postgres-service.postgres.svc.cluster.local -U postgres
```

### Authentication Failed

1. **Verify secrets**:
```bash
kubectl get secret postgres-secret -n postgres -o yaml
```

2. **Check environment variables**:
```bash
kubectl exec deployment/postgres -n postgres -- env | grep POSTGRES
```

### Data Persistence Issues

1. **Check PVC**:
```bash
kubectl get pvc -n postgres
kubectl describe pvc postgres-pvc -n postgres
```

2. **Verify mount**:
```bash
kubectl exec deployment/postgres -n postgres -- ls -la /var/lib/postgresql/data
```

### Performance Issues

1. **Check resource usage**:
```bash
kubectl top pod -n postgres
```

2. **View active queries**:
```bash
kubectl exec deployment/postgres -n postgres -- \
  psql -U postgres -c "SELECT * FROM pg_stat_activity WHERE state = 'active';"
```

3. **Increase resources** in `postgres-deployment.yaml`

## Security Best Practices

1. **Strong Passwords**: Use strong, unique passwords
2. **Secret Management**: Never commit secrets to git
3. **Network Policies**: Restrict network access to authorized pods
4. **Regular Updates**: Keep PostgreSQL version up-to-date
5. **Backups**: Implement regular automated backups
6. **Access Control**: Use least privilege principle for database users
7. **Encryption**: Consider enabling SSL/TLS for connections

## Performance Tuning

### PostgreSQL Configuration

Create a ConfigMap with custom `postgresql.conf`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: postgres-config
  namespace: postgres
data:
  postgresql.conf: |
    max_connections = 100
    shared_buffers = 256MB
    effective_cache_size = 1GB
    work_mem = 4MB
    maintenance_work_mem = 64MB
```

Mount in deployment:

```yaml
volumeMounts:
- name: config
  mountPath: /etc/postgresql/postgresql.conf
  subPath: postgresql.conf
volumes:
- name: config
  configMap:
    name: postgres-config
```

## Related Resources

- [PostgreSQL Documentation](https://www.postgresql.org/docs/)
- [Kubernetes Persistent Volumes](https://kubernetes.io/docs/concepts/storage/persistent-volumes/)
- [OpenEBS Storage]({{< relref "../infrastructure/openebs" >}})
