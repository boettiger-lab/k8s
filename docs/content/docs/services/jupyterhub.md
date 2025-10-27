---
title: "JupyterHub"
weight: 1
bookToc: true
---

# JupyterHub

Deploy JupyterHub on Kubernetes for multi-user notebook environments with GPU support.

## Overview

JupyterHub allows multiple users to access Jupyter notebooks through a single deployment. Our configuration includes:
- GPU support with time-slicing
- Persistent storage with disk quotas (OpenEBS ZFS)
- HTTPS via cert-manager
- Network policies for external service access
- Multiple deployment profiles (basic, public, GPU-enabled)

## Prerequisites

Before deploying JupyterHub, ensure the following are configured:

1. [K3s installed and running]({{< relref "../infrastructure/k3s" >}})
2. [NVIDIA GPU support]({{< relref "../infrastructure/nvidia" >}}) (if using GPUs)
3. [OpenEBS ZFS storage]({{< relref "../infrastructure/openebs" >}}) (for disk quotas)
4. [cert-manager]({{< relref "../infrastructure/cert-manager" >}}) (for HTTPS)
5. [ExternalDNS]({{< relref "../infrastructure/external-dns" >}}) (optional, for automatic DNS)

## Installation

### Add JupyterHub Helm Repository

```bash
helm repo add jupyterhub https://hub.jupyter.org/helm-chart/
helm repo update
```

### Create Configuration File

JupyterHub is configured via Helm values. Several example configurations are provided:

- `basic-config.yaml` - Minimal configuration
- `public-config.yaml` - Production configuration with network policies
- `thelio-config.yaml` - GPU workstation configuration
- `jupyterai-config.yaml` - Configuration with Jupyter AI extensions

### Deploy JupyterHub

Use the provided deployment script:

```bash
# Deploy to default namespace with public config
./jupyterhub/cirrus.sh
```

Or manually with Helm:

```bash
helm upgrade --install jupyterhub jupyterhub/jupyterhub \
  --namespace jupyterhub \
  --create-namespace \
  --values jupyterhub/public-config.yaml \
  --version 3.3.7
```

### Verify Deployment

```bash
# Check pods are running
kubectl get pods -n jupyterhub

# Check services
kubectl get svc -n jupyterhub

# Check ingress
kubectl get ingress -n jupyterhub
```

## Configuration

### Basic Configuration

The minimal configuration includes:

```yaml
hub:
  config:
    JupyterHub:
      authenticator_class: dummy
    DummyAuthenticator:
      password: "your-password-here"

singleuser:
  image:
    name: jupyter/minimal-notebook
    tag: latest
  storage:
    type: none  # or configure persistent storage
```

### Storage Configuration

Configure persistent storage with disk quotas using OpenEBS ZFS:

```yaml
singleuser:
  storage:
    type: dynamic
    capacity: 60Gi
    homeMountPath: /home/jovyan
    dynamic:
      storageClass: openebs-zfs
      pvcNameTemplate: claim-{escaped_user_server}
      volumeNameTemplate: volume-{escaped_user_server}
      storageAccessModes: [ReadWriteOnce]
```

This gives each user a 60Gi quota for their home directory.

### GPU Configuration

Enable GPU access for user notebooks:

```yaml
singleuser:
  profileList:
    - display_name: "CPU Only"
      description: "Standard notebook without GPU"
      default: true
    
    - display_name: "GPU Instance"
      description: "Notebook with GPU access"
      kubespawner_override:
        extra_resource_limits:
          nvidia.com/gpu: "1"
        extra_resource_guarantees:
          nvidia.com/gpu: "1"
```

### Network Policy Configuration

Allow user pods to access external services (like MinIO) via hairpin connections:

```yaml
singleuser:
  networkPolicy:
    enabled: true
    egressAllowRules:
      privateIPs: true                    # Access to private IP ranges
      dnsPortsPrivateIPs: true           # DNS resolution to private IPs
      dnsPortsKubeSystemNamespace: true  # DNS via kube-system
      nonPrivateIPs: true                # External internet access (hairpin)
    egress:
      # Specific access to minio.carlboettiger.info external IP
      - to:
          - ipBlock:
              cidr: 128.32.85.8/32
      # Access to MinIO namespace services
      - to:
          - namespaceSelector:
              matchLabels:
                name: minio
```

### HTTPS Configuration

Enable HTTPS with cert-manager:

```yaml
ingress:
  enabled: true
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
  hosts:
    - hub.carlboettiger.info
  tls:
    - hosts:
        - hub.carlboettiger.info
      secretName: jupyterhub-tls
```

### Custom Docker Images

Use custom images with pre-installed packages:

```yaml
singleuser:
  image:
    name: your-registry/custom-notebook
    tag: latest
    pullPolicy: Always
```

Build custom images in the `images/` directory.

### Environment Variables

Set environment variables for all users:

```yaml
singleuser:
  extraEnv:
    AWS_S3_ENDPOINT: "minio.carlboettiger.info"
    AWS_HTTPS: "true"
    AWS_VIRTUAL_HOSTING: "FALSE"
```

### Authentication

Configure authentication providers:

#### Dummy Authenticator (for testing)

```yaml
hub:
  config:
    JupyterHub:
      authenticator_class: dummy
    DummyAuthenticator:
      password: "test-password"
```

#### GitHub OAuth

```yaml
hub:
  config:
    JupyterHub:
      authenticator_class: github
    GitHubOAuthenticator:
      client_id: "your-client-id"
      client_secret: "your-client-secret"
      oauth_callback_url: "https://hub.example.com/hub/oauth_callback"
```

See `oauth-apps.md` for OAuth setup instructions.

#### Allow List

Restrict access to specific users:

```yaml
hub:
  config:
    Authenticator:
      allowed_users:
        - user1
        - user2
      admin_users:
        - admin1
```

## Usage

### Access JupyterHub

Navigate to your JupyterHub URL (e.g., `https://hub.carlboettiger.info`).

### User Workflow

1. Log in with configured authentication
2. Select a profile (CPU/GPU)
3. Wait for notebook server to start
4. Work in Jupyter Lab/Notebook
5. Stop server when done (saves resources)

### Verify GPU Access

In a notebook:

```python
import subprocess
result = subprocess.run(['nvidia-smi'], capture_output=True, text=True)
print(result.stdout)
```

### Access External Services

MinIO S3-compatible storage is pre-configured:

```python
import boto3

s3 = boto3.client('s3',
    endpoint_url='https://minio.carlboettiger.info',
    aws_access_key_id='your-key',
    aws_secret_access_key='your-secret'
)

# List buckets
s3.list_buckets()
```

## Management

### Update Configuration

Edit your config file and upgrade:

```bash
helm upgrade jupyterhub jupyterhub/jupyterhub \
  -n jupyterhub \
  -f jupyterhub/public-config.yaml
```

### Restart Hub

```bash
kubectl rollout restart deployment/hub -n jupyterhub
```

### View Logs

```bash
# Hub logs
kubectl logs -n jupyterhub deployment/hub

# User server logs
kubectl logs -n jupyterhub <user-pod-name>
```

### List Active Users

```bash
kubectl get pods -n jupyterhub | grep jupyter
```

### Force Stop User Server

```bash
kubectl delete pod <user-pod-name> -n jupyterhub
```

## Advanced Configuration

### Resource Limits

Set default resource limits:

```yaml
singleuser:
  cpu:
    limit: 4
    guarantee: 1
  memory:
    limit: 8G
    guarantee: 2G
```

### Culling Idle Servers

Automatically stop idle servers:

```yaml
cull:
  enabled: true
  timeout: 3600  # 1 hour
  every: 600     # Check every 10 minutes
```

### Shared Data Volumes

Mount shared read-only data:

```yaml
singleuser:
  storage:
    extraVolumes:
      - name: shared-data
        hostPath:
          path: /data/shared
    extraVolumeMounts:
      - name: shared-data
        mountPath: /home/jovyan/shared
        readOnly: true
```

### JupyterLab Extensions

Pre-install extensions in your image or install dynamically:

```yaml
singleuser:
  lifecycleHooks:
    postStart:
      exec:
        command:
          - "bash"
          - "-c"
          - |
            jupyter labextension install @jupyter-widgets/jupyterlab-manager
```

### BinderHub Integration

Deploy BinderHub for repo2docker functionality:

```bash
./jupyterhub/binderhub.sh
```

See `jupyterhub/binderhub-service-config.yaml` for configuration.

## Troubleshooting

### Pods Not Starting

1. **Check pod status**:
```bash
kubectl get pods -n jupyterhub
kubectl describe pod <pod-name> -n jupyterhub
```

2. **Common issues**:
   - Insufficient resources (CPU/memory/GPU)
   - Storage provisioning failures
   - Image pull errors
   - Network policy blocking

### Storage Issues

1. **Check PVCs**:
```bash
kubectl get pvc -n jupyterhub
kubectl describe pvc <pvc-name> -n jupyterhub
```

2. **Verify StorageClass**:
```bash
kubectl get storageclass
```

3. **Check OpenEBS**:
```bash
kubectl get pods -n openebs
sudo zfs list
```

### Network Issues

1. **Test external connectivity**:
```bash
kubectl exec -n jupyterhub <pod-name> -- curl https://www.google.com
```

2. **Check network policies**:
```bash
kubectl get networkpolicies -n jupyterhub
```

3. **Verify DNS**:
```bash
kubectl exec -n jupyterhub <pod-name> -- nslookup minio.carlboettiger.info
```

### Certificate Issues

1. **Check certificate status**:
```bash
kubectl get certificates -n jupyterhub
kubectl describe certificate jupyterhub-tls -n jupyterhub
```

2. **Check cert-manager logs**:
```bash
kubectl logs -n cert-manager deployment/cert-manager
```

### GPU Not Available

1. **Verify GPU resources**:
```bash
kubectl describe nodes | grep nvidia.com/gpu
```

2. **Check NVIDIA device plugin**:
```bash
kubectl get pods -n kube-system | grep nvidia
```

3. **Test GPU in pod**:
```bash
kubectl exec -n jupyterhub <pod-name> -- nvidia-smi
```

## Monitoring

### Hub Metrics

```bash
# Resource usage
kubectl top pods -n jupyterhub

# Active users
kubectl get pods -n jupyterhub | grep jupyter- | wc -l
```

### Storage Usage

```bash
# Check disk usage per user
sudo zfs list | grep jupyter
```

### GPU Utilization

```bash
# On the host
watch -n 1 nvidia-smi
```

## Backup and Recovery

### Backup User Data

User data is stored in ZFS volumes:

```bash
# Create snapshots
sudo zfs snapshot openebs-zpool/pvc-xxxxx@backup-$(date +%Y%m%d)

# List snapshots
sudo zfs list -t snapshot
```

### Backup Configuration

```bash
# Export Helm values
helm get values jupyterhub -n jupyterhub > backup-values.yaml

# Backup secrets
kubectl get secrets -n jupyterhub -o yaml > backup-secrets.yaml
```

### Restore

```bash
# Restore from snapshot
sudo zfs rollback openebs-zpool/pvc-xxxxx@backup-20231027

# Redeploy with backed-up config
helm upgrade jupyterhub jupyterhub/jupyterhub \
  -n jupyterhub \
  -f backup-values.yaml
```

## Related Resources

- [Zero to JupyterHub Documentation](https://z2jh.jupyter.org/)
- [JupyterHub Documentation](https://jupyterhub.readthedocs.io/)
- [Kubernetes Spawner Documentation](https://jupyterhub-kubespawner.readthedocs.io/)
- [Custom Images Guide]({{< relref "../admin/custom-images" >}})
