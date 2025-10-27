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
- [K3s Installation & Configuration]({{< relref "docs/infrastructure/k3s" >}})
- [NVIDIA GPU Support]({{< relref "docs/infrastructure/nvidia" >}})
- [Storage with OpenEBS]({{< relref "docs/infrastructure/openebs" >}})
- [Certificate Manager]({{< relref "docs/infrastructure/cert-manager" >}})
- [External DNS]({{< relref "docs/infrastructure/external-dns" >}})

### Services
- [JupyterHub]({{< relref "docs/services/jupyterhub" >}})
- [PostgreSQL]({{< relref "docs/services/postgres" >}})
- [MinIO]({{< relref "docs/services/minio" >}})
- [GitHub Actions Runners]({{< relref "docs/services/github-actions" >}})
- [vLLM]({{< relref "docs/services/vllm" >}})

### Administration
- [User Access Management]({{< relref "docs/admin/users" >}})
- [Secrets Management]({{< relref "docs/admin/secrets" >}})
- [Tips & Tricks]({{< relref "docs/admin/tips-tricks" >}})

## Getting Started

If you're new to this cluster:

1. **For Users**: Start with the [User Access Management]({{< relref "docs/admin/users" >}}) guide to get your credentials
2. **For Administrators**: Begin with [K3s Installation]({{< relref "docs/infrastructure/k3s" >}}) to understand the base setup
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
