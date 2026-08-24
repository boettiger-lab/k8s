---
title: "GitHub Actions Runners"
weight: 3
bookToc: true
---

# GitHub Actions Runners

Deploy self-hosted GitHub Actions runners on Kubernetes using Actions Runner Controller (ARC).

## Overview

The Actions Runner Controller (ARC) enables autoscaling of self-hosted GitHub Actions runners on Kubernetes. This allows you to run GitHub Actions workflows on your own infrastructure with access to:
- GPUs for ML/AI workloads
- Large memory instances
- Custom network access
- Local data and resources

## Features

- **Autoscaling**: Automatically scale runners based on workflow demand
- **Resource Management**: Control CPU, memory, and GPU allocation
- **Custom Environments**: Use custom container images with pre-installed tools
- **Cost Effective**: Utilize existing infrastructure instead of cloud runners

## Prerequisites

1. [K3s installed]({{< relref "../infrastructure/k3s" >}})
2. [NVIDIA GPU support]({{< relref "../infrastructure/nvidia" >}}) (optional, for GPU workflows)
3. GitHub repository or organization with admin access
4. GitHub Personal Access Token (PAT) or GitHub App

## Installation

### Create GitHub PAT

Create a Personal Access Token with the following scopes:
- `repo` (for repository-level runners)
- `admin:org` (for organization-level runners)

### Install Actions Runner Controller

Follow the [official documentation](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/autoscaling-with-self-hosted-runners) for setup.

Basic installation:

```bash
# Install cert-manager (if not already installed)
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml

# Install ARC
helm repo add actions-runner-controller https://actions-runner-controller.github.io/actions-runner-controller
helm repo update

helm install arc \
  --namespace actions-runner-system \
  --create-namespace \
  actions-runner-controller/actions-runner-controller
```

### Configure Runner

Create a RunnerDeployment for your repository:

```yaml
apiVersion: actions.summerwind.dev/v1alpha1
kind: RunnerDeployment
metadata:
  name: my-runner
  namespace: actions-runner-system
spec:
  replicas: 1
  template:
    spec:
      repository: owner/repo
      labels:
        - self-hosted
        - linux
        - x64
      resources:
        limits:
          cpu: "4"
          memory: "8Gi"
        requests:
          cpu: "2"
          memory: "4Gi"
```

## Configuration Examples

### Basic CPU Runner

```yaml
apiVersion: actions.summerwind.dev/v1alpha1
kind: RunnerDeployment
metadata:
  name: cpu-runner
  namespace: actions-runner-system
spec:
  replicas: 2
  template:
    spec:
      repository: owner/repo
      labels:
        - self-hosted
        - linux
        - cpu-only
      resources:
        limits:
          cpu: "4"
          memory: "8Gi"
```

### GPU-Enabled Runner (EFI Configuration)

See `cirrus-efi-values.yaml`:

```yaml
apiVersion: actions.summerwind.dev/v1alpha1
kind: RunnerDeployment
metadata:
  name: efi-cirrus
  namespace: actions-runner-system
spec:
  replicas: 1
  template:
    spec:
      repository: owner/repo
      labels:
        - efi-cirrus
        - gpu
      resources:
        limits:
          nvidia.com/gpu: "1"
          memory: "45Gi"
          cpu: "8"
        requests:
          nvidia.com/gpu: "1"
          memory: "32Gi"
          cpu: "4"
```

## Usage in Workflows

### Basic Usage

In your `.github/workflows/main.yml`:

```yaml
name: CI
on: [push]

jobs:
  build:
    runs-on: self-hosted  # Use your self-hosted runner
    steps:
      - uses: actions/checkout@v3
      - name: Run tests
        run: make test
```

### With Custom Labels

```yaml
jobs:
  gpu-job:
    runs-on: efi-cirrus  # Use specific runner with GPU
    steps:
      - uses: actions/checkout@v3
      - name: Run GPU workload
        run: python train.py
```

### With Container and Resource Limits

**Important**: ARC doesn't automatically handle resource limits when users specify containers. Actions can always opt into a container, so set limits in the workflow:

```yaml
jobs:
  forecasting:
    runs-on: efi-cirrus
    container: 
      image: eco4cast/rocker-neon4cast:latest
      options: --memory="15g"  # IMPORTANT: Set memory limit
    steps:
      - uses: actions/checkout@v3
      - name: Run forecast
        run: Rscript forecast.R
```

**Note**: Always set a memory limit less than or equal to the node's capacity (e.g., ≤ 45GB for EFI configuration).

## Configuration Files

Repository includes example configurations:

- `cirrus-efi-values.yaml` - EFI forecasting workstation (GPU, 45GB RAM)
- `cirrus-espm157-values.yaml` - ESPM 157 class workloads
- `cirrus-espm288-values.yaml` - ESPM 288 class workloads

Deploy with:

```bash
bash github-actions/helm.sh
```

## Resource Management

### Setting Resource Limits

Individual workflows should specify resource limits:

```yaml
runs-on: efi-cirrus
container: 
  image: your-image:latest
  options: --memory="15g" --cpus="4"
```

### Monitoring Resource Usage

```bash
# View runner pods
kubectl get pods -n actions-runner-system

# Check resource usage
kubectl top pods -n actions-runner-system

# View pod details
kubectl describe pod <runner-pod> -n actions-runner-system
```

## Troubleshooting

### Runner Not Picking Up Jobs

1. **Check runner registration**:
```bash
kubectl logs -n actions-runner-system <runner-pod>
```

2. **Verify labels match**: Ensure workflow `runs-on` matches runner labels

3. **Check GitHub connection**:
   - Verify PAT is valid
   - Check runner appears in GitHub settings

### Insufficient Resources

If jobs fail due to resources:

1. **Check available resources**:
```bash
kubectl describe nodes
```

2. **Adjust workflow limits**: Reduce memory/CPU in container options

3. **Scale runners**: Increase runner replicas if multiple jobs queue

### GPU Not Available

1. **Verify GPU allocation**:
```bash
kubectl describe node | grep nvidia.com/gpu
```

2. **Check device plugin**:
```bash
kubectl get pods -n kube-system | grep nvidia
```

3. **Test GPU in runner**:
```bash
kubectl exec -it <runner-pod> -n actions-runner-system -- nvidia-smi
```

### Container Pull Errors

1. **Check image exists**: Verify image name and tag
2. **Verify registry access**: Add image pull secrets if using private registry
3. **Check logs**:
```bash
kubectl describe pod <runner-pod> -n actions-runner-system
```

## Best Practices

1. **Resource Limits**: Always set memory limits in workflow containers
2. **Label Strategy**: Use descriptive labels to target specific runners
3. **Monitoring**: Regularly check runner logs and resource usage
4. **Security**: 
   - Use least-privilege PATs
   - Isolate runners by namespace
   - Review workflow code before running
5. **Cleanup**: Configure job cleanup to remove completed workflows
6. **Scaling**: Set appropriate min/max replicas based on demand

## Security Considerations

### Runner Isolation

- Runners have access to cluster resources in their namespace
- Consider running untrusted workflows in isolated namespaces
- Use network policies to restrict runner network access

### Secrets Management

- Store GitHub tokens in Kubernetes secrets
- Use GitHub encrypted secrets for workflow variables
- Avoid hardcoding sensitive data in workflows

### Image Security

- Use trusted base images
- Regularly update images for security patches
- Scan images for vulnerabilities

## Monitoring and Maintenance

### View Runner Status

```bash
# List runners
kubectl get runners -n actions-runner-system

# List runner deployments
kubectl get runnerdeployments -n actions-runner-system

# Check autoscaler status
kubectl get horizontalrunnerautoscaler -n actions-runner-system
```

### Update Runners

```bash
# Update runner image
kubectl set image deployment/<runner-name> runner=<new-image> -n actions-runner-system

# Or edit directly
kubectl edit runnerdeployment <runner-name> -n actions-runner-system
```

### Logs

```bash
# View runner logs
kubectl logs -n actions-runner-system <runner-pod>

# View controller logs
kubectl logs -n actions-runner-system deployment/arc-actions-runner-controller
```

## Advanced Configuration

### Autoscaling

Configure Horizontal Runner Autoscaler:

```yaml
apiVersion: actions.summerwind.dev/v1alpha1
kind: HorizontalRunnerAutoscaler
metadata:
  name: my-runner-autoscaler
  namespace: actions-runner-system
spec:
  scaleTargetRef:
    name: my-runner
  minReplicas: 1
  maxReplicas: 10
  metrics:
  - type: TotalNumberOfQueuedAndInProgressWorkflowRuns
    repositoryNames:
    - owner/repo
```

### Persistent Volumes

Add persistent storage for caching:

```yaml
spec:
  template:
    spec:
      volumeMounts:
      - name: work
        mountPath: /runner/_work
      volumes:
      - name: work
        ephemeral:
          volumeClaimTemplate:
            spec:
              accessModes: [ "ReadWriteOnce" ]
              resources:
                requests:
                  storage: 10Gi
```

## Related Resources

- [ARC Official Documentation](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/autoscaling-with-self-hosted-runners)
- [GitHub Actions Documentation](https://docs.github.com/en/actions)
- [NVIDIA GPU Support]({{< relref "../infrastructure/nvidia" >}})
- [K3s Setup]({{< relref "../infrastructure/k3s" >}})
