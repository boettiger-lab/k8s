---
title: "K8s Cluster Documentation"
type: docs
---

# K8s Cluster Documentation

Welcome to the documentation for our Kubernetes (K3s) cluster setup. This documentation covers both the infrastructure setup and the services running on our clusters.

## Overview

This repository contains all the configuration files for deploying our research team's computational environment across our campus-based workstations. We use a Kubernetes-based approach (specifically K3s) that provides containerized software abstractions along with hardware orchestration and resource management capabilities.

## Quick Links

### Infrastructure Setup
- [K3s Installation & Configuration]({{< relref "infrastructure/k3s" >}})
- [NVIDIA GPU Support]({{< relref "infrastructure/nvidia" >}})
- [Storage with OpenEBS]({{< relref "infrastructure/openebs" >}})
- [Certificate Manager]({{< relref "infrastructure/cert-manager" >}})
- [External DNS]({{< relref "infrastructure/external-dns" >}})

### Services
- [JupyterHub]({{< relref "services/jupyterhub" >}})
- [PostgreSQL]({{< relref "services/postgres" >}})
- [MinIO]({{< relref "services/minio" >}})
- [GitHub Actions Runners]({{< relref "services/github-actions" >}})
- [vLLM]({{< relref "services/vllm" >}})

### Administration
- [User Access Management]({{< relref "admin/users" >}})
- [Secrets Management]({{< relref "admin/secrets" >}})
- [Tips & Tricks]({{< relref "admin/tips-tricks" >}})

## Getting Started

If you're new to this cluster:

1. **For Users**: Start with the [User Access Management]({{< relref "admin/users" >}}) guide to get your credentials
2. **For Administrators**: Begin with [K3s Installation]({{< relref "infrastructure/k3s" >}}) to understand the base setup
3. **For Service Deployment**: Check the specific service documentation in the Services section

## Architecture

Our cluster is built on:
- **K3s**: Lightweight Kubernetes distribution
- **Traefik**: Built-in ingress controller
- **Cert-Manager**: Automatic SSL/TLS certificate management
- **External-DNS**: Automatic DNS record management
- **OpenEBS ZFS**: Persistent storage with disk quotas
- **NVIDIA Device Plugin**: GPU resource management with time-slicing

## Support

For issues or questions:
- Check the [Tips & Tricks]({{< relref "admin/tips-tricks" >}}) section
- Review the relevant service documentation
- Consult the [GitHub repository](https://github.com/boettiger-lab/k8s)
