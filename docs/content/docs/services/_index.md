---
title: "Services"
weight: 2
bookCollapseSection: false
---

# Services

Documentation for services deployed on the Kubernetes cluster.

This section covers the various applications and services running on the cluster:

## Available Services

- [**JupyterHub**](jupyterhub) - Multi-user Jupyter notebook environment with GPU support
- [**PostgreSQL**](postgres) - Relational database service
- [**MinIO**](minio) - S3-compatible object storage
- [**GitHub Actions Runners**](github-actions) - Self-hosted CI/CD runners
- [**vLLM**](vllm) - High-performance LLM inference

## Prerequisites

Before deploying services, ensure the [infrastructure]({{< relref "../infrastructure" >}}) is properly configured:

- K3s is installed and running
- Storage backend is configured (if needed)
- SSL certificates are set up (for external access)
- DNS is configured (for external access)
- GPU support is enabled (if using GPU services)

## Service Deployment

Most services include deployment scripts in their respective directories. General pattern:

```bash
cd <service-directory>
./up.sh      # Deploy
./down.sh    # Remove
```

Or use `kubectl` and Helm directly:

```bash
kubectl apply -f <service>.yaml
helm install <service> <chart> -f values.yaml
```
