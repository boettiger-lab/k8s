---
title: "Tips & Tricks"
weight: 3
bookToc: true
---

# Tips & Tricks

Collection of useful Kubernetes commands and solutions to common problems.

## General kubectl Commands

### Quick Resource Checks

```bash
# View all resources in a namespace
kubectl get all -n <namespace>

# View all resources across all namespaces
kubectl get all --all-namespaces

# Wide output with more details
kubectl get pods -o wide

# JSON output
kubectl get pod <pod-name> -o json

# YAML output
kubectl get pod <pod-name> -o yaml

# Custom columns
kubectl get pods -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,IP:.status.podIP
```

### Resource Usage

```bash
# Node resource usage
kubectl top nodes

# Pod resource usage
kubectl top pods -n <namespace>

# All pods across cluster
kubectl top pods --all-namespaces
```

### Describe Resources

```bash
# Detailed information about a resource
kubectl describe pod <pod-name>
kubectl describe node <node-name>
kubectl describe service <service-name>

# Events for troubleshooting
kubectl get events -n <namespace> --sort-by='.lastTimestamp'
```

## Troubleshooting

### Namespace Stuck in Terminating State

If a namespace won't delete:

```bash
NAMESPACE=mynamespace
kubectl get namespace $NAMESPACE -o json | sed 's/"kubernetes"//' | kubectl replace --raw "/api/v1/namespaces/$NAMESPACE/finalize" -f -
```

**Reference**: [Stack Overflow](https://stackoverflow.com/questions/52369247/namespace-stuck-as-terminating-how-i-removed-it)

### Pod Stuck in Pending

```bash
# Check why pod is pending
kubectl describe pod <pod-name> -n <namespace>

# Common reasons:
# - Insufficient resources
# - PVC not bound
# - Node selector not matching
# - Taints/tolerations issues
```

### Pod Stuck in ImagePullBackOff

```bash
# Check image pull errors
kubectl describe pod <pod-name> -n <namespace>

# Common solutions:
# - Verify image name and tag
# - Check image registry is accessible
# - Verify image pull secrets (if using private registry)
```

### PVC Stuck in Pending

```bash
# Check PVC status
kubectl describe pvc <pvc-name> -n <namespace>

# Check StorageClass
kubectl get storageclass

# Check provisioner logs (for OpenEBS)
kubectl logs -n openebs <provisioner-pod>
```

### Container Crashing (CrashLoopBackOff)

```bash
# View current logs
kubectl logs <pod-name> -n <namespace>

# View previous container logs (after crash)
kubectl logs <pod-name> -n <namespace> --previous

# Get into a crashlooping pod (if it stays up long enough)
kubectl exec -it <pod-name> -n <namespace> -- /bin/sh
```

## Container RAM Usage Check

Quickly check RAM usage of active containers using cgroup:

```bash
# Maximum memory limit
cat /sys/fs/cgroup/memory.max | awk '{printf "%.2f GB\n", $1/1024/1024/1024}'

# Current memory usage
cat /sys/fs/cgroup/memory.current | awk '{printf "%.2f GB\n", $1/1024/1024/1024}'
```

This is useful when inside a container to see actual memory constraints and usage.

## Port Forwarding

### Forward Local Port to Pod

```bash
# Forward local port 8080 to pod's port 80
kubectl port-forward pod/<pod-name> 8080:80 -n <namespace>

# Forward to a service
kubectl port-forward service/<service-name> 8080:80 -n <namespace>

# Forward to a deployment
kubectl port-forward deployment/<deployment-name> 8080:80 -n <namespace>

# Make available on all interfaces (not just localhost)
kubectl port-forward --address 0.0.0.0 service/<service-name> 8080:80 -n <namespace>
```

## Scaling

### Scale Deployments

```bash
# Scale to 3 replicas
kubectl scale deployment <deployment-name> --replicas=3 -n <namespace>

# Scale to 0 (stop all pods)
kubectl scale deployment <deployment-name> --replicas=0 -n <namespace>

# Autoscaling
kubectl autoscale deployment <deployment-name> --min=2 --max=10 --cpu-percent=80
```

## Updates and Rollbacks

### Update Image

```bash
# Update deployment image
kubectl set image deployment/<deployment-name> <container-name>=<new-image> -n <namespace>

# Watch rollout status
kubectl rollout status deployment/<deployment-name> -n <namespace>
```

### Rollback

```bash
# View rollout history
kubectl rollout history deployment/<deployment-name> -n <namespace>

# Rollback to previous version
kubectl rollout undo deployment/<deployment-name> -n <namespace>

# Rollback to specific revision
kubectl rollout undo deployment/<deployment-name> --to-revision=2 -n <namespace>
```

### Restart

```bash
# Restart a deployment (recreates all pods)
kubectl rollout restart deployment/<deployment-name> -n <namespace>
```

## Secrets and ConfigMaps

### Create Secrets

```bash
# From literal values
kubectl create secret generic my-secret \
  --from-literal=username=admin \
  --from-literal=password=secret123 \
  -n <namespace>

# From files
kubectl create secret generic my-secret \
  --from-file=ssh-privatekey=~/.ssh/id_rsa \
  --from-file=ssh-publickey=~/.ssh/id_rsa.pub \
  -n <namespace>

# TLS secret
kubectl create secret tls my-tls-secret \
  --cert=path/to/cert.crt \
  --key=path/to/key.key \
  -n <namespace>
```

### View Secrets

```bash
# List secrets
kubectl get secrets -n <namespace>

# View secret details (base64 encoded)
kubectl get secret <secret-name> -n <namespace> -o yaml

# Decode secret value
kubectl get secret <secret-name> -n <namespace> -o jsonpath='{.data.password}' | base64 -d
```

### Create ConfigMaps

```bash
# From literal values
kubectl create configmap my-config \
  --from-literal=api_url=https://api.example.com \
  --from-literal=api_key=12345 \
  -n <namespace>

# From file
kubectl create configmap my-config \
  --from-file=config.json \
  -n <namespace>

# From directory
kubectl create configmap my-config \
  --from-file=config-dir/ \
  -n <namespace>
```

## Labels and Selectors

### Add Labels

```bash
# Add label to a pod
kubectl label pod <pod-name> environment=production -n <namespace>

# Add label to all pods in a namespace
kubectl label pods --all environment=production -n <namespace>

# Update existing label
kubectl label pod <pod-name> environment=staging --overwrite -n <namespace>
```

### Select by Labels

```bash
# Get pods with specific label
kubectl get pods -l environment=production -n <namespace>

# Multiple label selectors
kubectl get pods -l 'environment=production,tier=frontend' -n <namespace>

# Delete pods by label
kubectl delete pods -l environment=staging -n <namespace>
```

## Copying Files

### Copy to/from Pods

```bash
# Copy file from local to pod
kubectl cp /local/path/file.txt <namespace>/<pod-name>:/path/in/pod/

# Copy file from pod to local
kubectl cp <namespace>/<pod-name>:/path/in/pod/file.txt /local/path/

# Copy directory
kubectl cp /local/dir <namespace>/<pod-name>:/path/in/pod/ -c <container-name>
```

## Debugging

### Run Debug Container

```bash
# Run a temporary debug pod
kubectl run -it --rm debug --image=busybox --restart=Never -- sh

# Run with specific image
kubectl run -it --rm debug --image=ubuntu --restart=Never -- bash

# Run in specific namespace
kubectl run -it --rm debug --image=alpine --restart=Never -n <namespace> -- sh
```

### Debug Network Issues

```bash
# Test DNS resolution
kubectl run -it --rm debug --image=busybox --restart=Never -- nslookup kubernetes.default

# Test connectivity
kubectl run -it --rm debug --image=busybox --restart=Never -- wget -O- http://service-name.namespace.svc.cluster.local

# Curl test
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -- curl http://service-name
```

### Ephemeral Debug Container (K8s 1.23+)

```bash
# Attach debug container to running pod
kubectl debug -it <pod-name> --image=busybox --target=<container-name>

# Debug node
kubectl debug node/<node-name> -it --image=ubuntu
```

## Resource Management

### Resource Quotas

```bash
# View resource quotas
kubectl get resourcequota -n <namespace>

# Describe quota details
kubectl describe resourcequota -n <namespace>
```

### Limit Ranges

```bash
# View limit ranges
kubectl get limitrange -n <namespace>

# Describe limits
kubectl describe limitrange -n <namespace>
```

## Viewing Cluster Information

### Cluster Info

```bash
# Basic cluster info
kubectl cluster-info

# Cluster version
kubectl version

# API resources
kubectl api-resources

# API versions
kubectl api-versions
```

### Node Information

```bash
# List nodes
kubectl get nodes

# Node details
kubectl describe node <node-name>

# Node conditions
kubectl get nodes -o custom-columns=NAME:.metadata.name,STATUS:.status.conditions[-1].type

# Taint information
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
```

## Context and Configuration

### Manage Contexts

```bash
# List contexts
kubectl config get-contexts

# View current context
kubectl config current-context

# Switch context
kubectl config use-context <context-name>

# Set default namespace for context
kubectl config set-context --current --namespace=<namespace>
```

### View Configuration

```bash
# View kubeconfig
kubectl config view

# View specific cluster info
kubectl config view --minify

# View raw config (with secrets)
kubectl config view --raw
```

## Helm

### Common Helm Commands

```bash
# List installed releases
helm list -A

# Get release values
helm get values <release-name> -n <namespace>

# Get all info about release
helm get all <release-name> -n <namespace>

# Upgrade release
helm upgrade <release-name> <chart> -n <namespace> -f values.yaml

# Rollback release
helm rollback <release-name> -n <namespace>

# Uninstall release
helm uninstall <release-name> -n <namespace>
```

## Certificate Management

### cert-manager

```bash
# List certificates
kubectl get certificates -A

# Describe certificate
kubectl describe certificate <cert-name> -n <namespace>

# Check certificate request
kubectl get certificaterequest -A

# View challenges (for troubleshooting)
kubectl get challenges -A

# Force certificate renewal
kubectl delete certificaterequest <cert-request-name> -n <namespace>
```

## Storage

### OpenEBS/ZFS

```bash
# List storage classes
kubectl get storageclass

# List PVCs
kubectl get pvc -A

# List PVs
kubectl get pv

# On host: Check ZFS pools
sudo zpool status

# On host: List ZFS datasets
sudo zfs list

# On host: Check ZFS usage
sudo zfs list -o name,used,avail,refer,mountpoint
```

## GPU Management

### NVIDIA GPU

```bash
# Check GPU resources on nodes
kubectl describe nodes | grep nvidia.com/gpu

# Verify device plugin
kubectl get pods -n kube-system | grep nvidia

# Test GPU access
kubectl run gpu-test --rm -it --restart=Never \
  --image=nvidia/cuda:12.0.0-base-ubuntu22.04 \
  --limits=nvidia.com/gpu=1 \
  -- nvidia-smi
```

## Performance

### Watch Resources

```bash
# Watch pods
kubectl get pods -w

# Watch with refresh
watch kubectl get pods

# Watch events
kubectl get events -w
```

### Metrics

```bash
# Resource metrics (requires metrics-server)
kubectl top nodes
kubectl top pods -A
kubectl top pods -n <namespace> --sort-by=memory
kubectl top pods -n <namespace> --sort-by=cpu
```

## Cleanup

### Delete Resources

```bash
# Delete by name
kubectl delete pod <pod-name> -n <namespace>

# Delete all pods in namespace
kubectl delete pods --all -n <namespace>

# Delete by label
kubectl delete pods -l app=myapp -n <namespace>

# Force delete stuck pod
kubectl delete pod <pod-name> -n <namespace> --grace-period=0 --force

# Delete namespace (and all resources in it)
kubectl delete namespace <namespace>
```

### Cleanup Completed Jobs

```bash
# Delete completed jobs
kubectl delete jobs --field-selector status.successful=1 -n <namespace>

# Delete failed jobs
kubectl delete jobs --field-selector status.failed=1 -n <namespace>
```

## Quick Reference

### Abbreviations

```bash
# Common abbreviations
po = pods
svc = services
deploy = deployments
rs = replicasets
ns = namespaces
cm = configmaps
pv = persistentvolumes
pvc = persistentvolumeclaims
ing = ingresses

# Example usage
kubectl get po
kubectl describe svc
kubectl delete deploy
```

### Output Formats

```bash
-o json          # JSON format
-o yaml          # YAML format
-o wide          # Additional columns
-o name          # Only resource names
-o jsonpath      # Custom output with JSONPath
-o custom-columns  # Custom columns
```

## Best Practices

1. **Use Labels**: Label everything for easy management
2. **Use Namespaces**: Organize resources by namespace
3. **Resource Limits**: Always set resource requests and limits
4. **Health Checks**: Configure liveness and readiness probes
5. **Version Control**: Store manifests in git
6. **Backup**: Regularly backup important data and configurations
7. **Monitor**: Set up monitoring and alerting
8. **Documentation**: Document custom configurations

## Related Resources

- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [kubectl Cheat Sheet](https://kubernetes.io/docs/reference/kubectl/cheatsheet/)
- [K3s Documentation](https://docs.k3s.io/)
- [NRP Documentation](https://nrp.ai/documentation/)
