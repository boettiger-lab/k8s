---
title: "NVIDIA GPU Support"
weight: 2
bookToc: true
---

# NVIDIA GPU Support

Enable GPU access in your K3s cluster with the NVIDIA device plugin, including support for GPU time-slicing to allow multiple pods to share a single GPU.

## Overview

The NVIDIA device plugin for Kubernetes enables:
- GPU discovery and advertisement to the cluster
- GPU resource scheduling
- GPU time-slicing for improved utilization
- Multiple users/pods accessing GPUs simultaneously

## Prerequisites

### Host System Requirements

1. **NVIDIA Drivers**: Install NVIDIA drivers on the host system

```bash
# Check if drivers are installed
nvidia-smi
```

2. **NVIDIA Container Toolkit**: Required for container GPU access

```bash
# Install NVIDIA Container Toolkit
# See: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html

distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
curl -s -L https://nvidia.github.io/nvidia-docker/gpgkey | sudo apt-key add -
curl -s -L https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.list | \
  sudo tee /etc/apt/sources.list.d/nvidia-docker.list

sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit

# Configure the Docker daemon to use the NVIDIA runtime
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

## Installation

### Deploy NVIDIA Device Plugin

Run the installation script from the repository:

```bash
# From the repository root
bash nvidia/nvidia-device-plugin.sh
```

This script:
- Deploys the NVIDIA device plugin as a DaemonSet
- Configures GPU time-slicing (8 slices per GPU by default)
- Sets up the necessary ConfigMaps

### Verify Installation

```bash
# Check that the device plugin pods are running
kubectl get pods -n kube-system | grep nvidia

# Verify GPU resources are advertised
kubectl describe nodes | grep nvidia.com/gpu
```

You should see output like:
```
nvidia.com/gpu: 8
```

The number represents the total number of GPU slices available (not physical GPUs).

## Configuration

### GPU Time-Slicing

GPU time-slicing allows multiple pods to share a single GPU, improving utilization. Our default configuration sets up 8 time slices per GPU.

The configuration is defined in `nvidia-device-plugin-config.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: nvidia-device-plugin-config
  namespace: kube-system
data:
  config: |
    version: v1
    sharing:
      timeSlicing:
        replicas: 8
```

**Adjusting Time Slices**: To change the number of replicas, edit the `replicas` value and reapply:

```bash
kubectl apply -f nvidia/nvidia-device-plugin-config.yaml
kubectl rollout restart daemonset nvidia-device-plugin-daemonset -n kube-system
```

### Resource Limits in Pods

To request GPU resources in your pods:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: gpu-pod
spec:
  containers:
  - name: cuda-container
    image: nvidia/cuda:12.0.0-base-ubuntu22.04
    command: ["nvidia-smi"]
    resources:
      limits:
        nvidia.com/gpu: 1  # Request 1 GPU slice
```

## Usage in JupyterHub

GPU access can be configured in JupyterHub's `config.yaml`:

```yaml
singleuser:
  profileList:
    - display_name: "GPU Instance"
      description: "Notebook with GPU access"
      kubespawner_override:
        extra_resource_limits:
          nvidia.com/gpu: "1"
        extra_resource_guarantees:
          nvidia.com/gpu: "1"
```

Users can verify GPU access within their notebooks:

```python
import subprocess
result = subprocess.run(['nvidia-smi'], capture_output=True, text=True)
print(result.stdout)
```

## Testing GPU Access

### Test Job

Deploy a test job to verify GPU functionality:

```bash
kubectl apply -f nvidia/test-nvidia-smi-job.yaml
```

Check the job output:

```bash
# Get the pod name
kubectl get pods | grep test-nvidia-smi

# View logs
kubectl logs test-nvidia-smi-xxxxx
```

You should see the nvidia-smi output showing your GPU.

### Manual Test Pod

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: gpu-test
spec:
  restartPolicy: Never
  containers:
  - name: cuda
    image: nvidia/cuda:12.0.0-base-ubuntu22.04
    command: ["nvidia-smi"]
    resources:
      limits:
        nvidia.com/gpu: 1
```

```bash
kubectl apply -f gpu-test.yaml
kubectl logs gpu-test
kubectl delete pod gpu-test
```

## Troubleshooting

### GPUs Not Visible

1. **Check device plugin pods**:
```bash
kubectl get pods -n kube-system | grep nvidia
kubectl logs -n kube-system <nvidia-device-plugin-pod>
```

2. **Verify NVIDIA runtime**:
```bash
# On the host
nvidia-smi
docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi
```

3. **Check node labels**:
```bash
kubectl get nodes -o json | jq '.items[].status.allocatable'
```

### Pods Can't Access GPU

1. **Check resource requests**:
```bash
kubectl describe pod <pod-name>
```

2. **Verify container runtime configuration**:
```bash
sudo systemctl status containerd
```

3. **Check K3s containerd config** at `/var/lib/rancher/k3s/agent/etc/containerd/config.toml`

### Time-Slicing Not Working

1. **Verify ConfigMap**:
```bash
kubectl get configmap nvidia-device-plugin-config -n kube-system -o yaml
```

2. **Check device plugin version**: Ensure you're using a recent version that supports time-slicing

3. **Restart device plugin**:
```bash
kubectl rollout restart daemonset nvidia-device-plugin-daemonset -n kube-system
```

## Resource Management

### Monitoring GPU Usage

Monitor GPU utilization on the host:

```bash
# Continuous monitoring
watch -n 1 nvidia-smi

# One-time check
nvidia-smi
```

From within the cluster:

```bash
kubectl exec -it <pod-name> -- nvidia-smi
```

### GPU Resource Quotas

To limit GPU usage per namespace:

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: gpu-quota
  namespace: my-namespace
spec:
  hard:
    requests.nvidia.com/gpu: "4"
    limits.nvidia.com/gpu: "4"
```

## Best Practices

1. **Time-Slicing**: Use time-slicing for workloads that don't fully utilize the GPU
2. **Resource Limits**: Always set GPU resource limits to prevent pods from requesting more than needed
3. **Monitoring**: Regularly monitor GPU utilization to optimize time-slice configuration
4. **MIG (Multi-Instance GPU)**: For supported GPUs (A100, H100), consider MIG for better isolation instead of time-slicing

## Related Resources

- [NVIDIA Device Plugin Documentation](https://github.com/NVIDIA/k8s-device-plugin)
- [NVIDIA Blog: Improving GPU Utilization in Kubernetes](https://developer.nvidia.com/blog/improving-gpu-utilization-in-kubernetes/)
- [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)
- [JupyterHub GPU Configuration]({{< relref "../services/jupyterhub" >}})
