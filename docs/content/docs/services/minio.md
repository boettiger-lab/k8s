---
title: "MinIO"
weight: 5
bookToc: true
---

# MinIO

Deploy MinIO for S3-compatible object storage on Kubernetes.

## Overview

[MinIO](https://min.io/) is a high-performance, S3-compatible object storage system. Use cases include:
- Data lake storage
- Backup and archival
- Machine learning dataset storage
- Application data storage
- Alternative to AWS S3 for on-premise workloads

## Features

- **S3 Compatible**: Drop-in replacement for Amazon S3
- **High Performance**: Optimized for modern hardware
- **Erasure Coding**: Data protection and redundancy
- **Encryption**: Server-side and client-side encryption
- **Access Control**: IAM-compatible policies
- **Event Notifications**: Webhook, NATS, Kafka integrations

## Quick Start

### Development Deployment

For testing and development:

```bash
kubectl apply -f minio/minio-dev.yaml
```

This creates a single-node MinIO instance with:
- 10Gi ephemeral storage
- Default credentials (change in production!)
- No persistence (data lost on pod restart)

### Production Deployment

For production use with persistent storage:

```bash
kubectl apply -f minio/minio.yaml
```

This creates:
- StatefulSet with persistent volumes
- Service for cluster access
- Optional ingress for external access
- Configurable storage backend

## Configuration

### Production Deployment Example

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: minio
  labels:
    name: minio
---
apiVersion: v1
kind: Secret
metadata:
  name: minio-secret
  namespace: minio
type: Opaque
stringData:
  rootUser: minioadmin
  rootPassword: changeme123  # Change this!
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: minio-pvc
  namespace: minio
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: openebs-zfs
  resources:
    requests:
      storage: 100Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  namespace: minio
spec:
  replicas: 1
  selector:
    matchLabels:
      app: minio
  template:
    metadata:
      labels:
        app: minio
    spec:
      containers:
      - name: minio
        image: minio/minio:latest
        args:
          - server
          - /data
          - --console-address
          - ":9001"
        env:
        - name: MINIO_ROOT_USER
          valueFrom:
            secretKeyRef:
              name: minio-secret
              key: rootUser
        - name: MINIO_ROOT_PASSWORD
          valueFrom:
            secretKeyRef:
              name: minio-secret
              key: rootPassword
        ports:
        - containerPort: 9000
          name: api
        - containerPort: 9001
          name: console
        volumeMounts:
        - name: storage
          mountPath: /data
      volumes:
      - name: storage
        persistentVolumeClaim:
          claimName: minio-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: minio-service
  namespace: minio
spec:
  type: ClusterIP
  ports:
  - port: 9000
    targetPort: 9000
    name: api
  - port: 9001
    targetPort: 9001
    name: console
  selector:
    app: minio
```

### Create Secrets

```bash
# Create namespace
kubectl create namespace minio

# Create secrets
kubectl create secret generic minio-secret \
  --from-literal=rootUser=minioadmin \
  --from-literal=rootPassword=YourSecurePassword123 \
  -n minio
```

## Access MinIO

### Web Console

Forward port for web console:

```bash
kubectl port-forward -n minio service/minio-service 9001:9001
```

Then open http://localhost:9001 in your browser.

### API Access

Forward API port:

```bash
kubectl port-forward -n minio service/minio-service 9000:9000
```

### Via Ingress

Create an ingress for external access:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: minio-ingress
  namespace: minio
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
spec:
  rules:
  - host: minio.carlboettiger.info
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: minio-service
            port:
              number: 9000
  tls:
  - hosts:
    - minio.carlboettiger.info
    secretName: minio-tls
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: minio-console-ingress
  namespace: minio
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
spec:
  rules:
  - host: minio-console.carlboettiger.info
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: minio-service
            port:
              number: 9001
  tls:
  - hosts:
    - minio-console.carlboettiger.info
    secretName: minio-console-tls
```

## Usage

### Using MinIO Client (mc)

Install MinIO client:

```bash
# Linux
wget https://dl.min.io/client/mc/release/linux-amd64/mc
chmod +x mc
sudo mv mc /usr/local/bin/

# macOS
brew install minio/stable/mc
```

Configure client:

```bash
# For local port-forward
mc alias set myminio http://localhost:9000 minioadmin YourPassword

# For external access
mc alias set myminio https://minio.carlboettiger.info minioadmin YourPassword
```

Basic operations:

```bash
# Create bucket
mc mb myminio/mybucket

# List buckets
mc ls myminio

# Upload file
mc cp file.txt myminio/mybucket/

# Download file
mc cp myminio/mybucket/file.txt .

# Sync directory
mc mirror local-dir/ myminio/mybucket/
```

### Using Python (boto3)

```python
import boto3
from botocore.client import Config

# Configure S3 client
s3 = boto3.client('s3',
    endpoint_url='https://minio.carlboettiger.info',
    aws_access_key_id='minioadmin',
    aws_secret_access_key='YourPassword',
    config=Config(signature_version='s3v4'),
    region_name='us-east-1'
)

# Create bucket
s3.create_bucket(Bucket='mybucket')

# Upload file
s3.upload_file('local-file.txt', 'mybucket', 'remote-file.txt')

# Download file
s3.download_file('mybucket', 'remote-file.txt', 'downloaded-file.txt')

# List objects
response = s3.list_objects_v2(Bucket='mybucket')
for obj in response.get('Contents', []):
    print(obj['Key'])
```

### Using R (aws.s3)

```r
library(aws.s3)

# Configure
Sys.setenv(
  "AWS_S3_ENDPOINT" = "minio.carlboettiger.info",
  "AWS_ACCESS_KEY_ID" = "minioadmin",
  "AWS_SECRET_ACCESS_KEY" = "YourPassword",
  "AWS_DEFAULT_REGION" = "us-east-1"
)

# List buckets
bucketlist()

# Upload file
put_object("local-file.csv", object = "remote-file.csv", bucket = "mybucket")

# Download file
save_object("remote-file.csv", bucket = "mybucket", file = "downloaded.csv")
```

## Management

### Create Users

Via console or mc:

```bash
# Create user
mc admin user add myminio newuser newpassword

# Create policy
cat > readonly.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:GetObject"],
    "Resource": ["arn:aws:s3:::mybucket/*"]
  }]
}
EOF

mc admin policy add myminio readonly readonly.json

# Assign policy to user
mc admin policy set myminio readonly user=newuser
```

### Bucket Policies

Set public read access:

```bash
mc anonymous set download myminio/mybucket
```

Custom policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"AWS": ["*"]},
      "Action": ["s3:GetObject"],
      "Resource": ["arn:aws:s3:::mybucket/public/*"]
    }
  ]
}
```

### Lifecycle Policies

Auto-delete old objects:

```xml
<LifecycleConfiguration>
  <Rule>
    <ID>DeleteOld</ID>
    <Status>Enabled</Status>
    <Filter>
      <Prefix>logs/</Prefix>
    </Filter>
    <Expiration>
      <Days>30</Days>
    </Expiration>
  </Rule>
</LifecycleConfiguration>
```

## Integration with JupyterHub

Configure JupyterHub to provide MinIO credentials:

```yaml
singleuser:
  extraEnv:
    AWS_S3_ENDPOINT: "minio.carlboettiger.info"
    AWS_HTTPS: "true"
    AWS_VIRTUAL_HOSTING: "FALSE"
```

Users can then access MinIO from notebooks:

```python
import boto3
import os

s3 = boto3.client('s3',
    endpoint_url=f"https://{os.environ['AWS_S3_ENDPOINT']}",
    aws_access_key_id='your-key',
    aws_secret_access_key='your-secret'
)
```

## Monitoring

### Check Status

```bash
# Pod status
kubectl get pods -n minio

# Service status
kubectl get svc -n minio

# Storage usage
kubectl exec -n minio deployment/minio -- df -h /data
```

### Logs

```bash
kubectl logs -n minio deployment/minio -f
```

### Metrics

MinIO exports Prometheus metrics at `/minio/v2/metrics/cluster`.

## Backup and Recovery

### Backup Data

```bash
# Using mc mirror
mc mirror myminio/mybucket /backup/mybucket

# Incremental backup
mc mirror --newer-than 1d myminio/mybucket /backup/mybucket
```

### Restore Data

```bash
# Restore from backup
mc mirror /backup/mybucket myminio/mybucket
```

### Export/Import Configuration

```bash
# Export config
mc admin config export myminio > minio-config.json

# Import config
mc admin config import myminio < minio-config.json
```

## Troubleshooting

### Connection Refused

1. Check service is running:
```bash
kubectl get svc -n minio
```

2. Test internal connectivity:
```bash
kubectl run -it --rm test --image=curlimages/curl --restart=Never -- \
  curl http://minio-service.minio.svc.cluster.local:9000/minio/health/live
```

### Authentication Failed

1. Verify credentials:
```bash
kubectl get secret minio-secret -n minio -o yaml
```

2. Check environment variables:
```bash
kubectl exec -n minio deployment/minio -- env | grep MINIO
```

### Storage Issues

1. Check PVC:
```bash
kubectl get pvc -n minio
kubectl describe pvc minio-pvc -n minio
```

2. Check disk space:
```bash
kubectl exec -n minio deployment/minio -- df -h
```

## Best Practices

1. **Use Strong Credentials**: Change default passwords
2. **Enable Encryption**: Use TLS for all connections
3. **Backup Regularly**: Implement automated backups
4. **Access Control**: Use IAM policies for fine-grained control
5. **Monitoring**: Set up alerts for storage usage
6. **Versioning**: Enable bucket versioning for important data
7. **Lifecycle Policies**: Auto-delete old or temporary data

## Related Resources

- [MinIO Documentation](https://min.io/docs/)
- [MinIO Client Guide](https://min.io/docs/minio/linux/reference/minio-mc.html)
- [S3 API Reference](https://docs.aws.amazon.com/AmazonS3/latest/API/Welcome.html)
- [JupyterHub Integration]({{< relref "jupyterhub#access-external-services" >}})
