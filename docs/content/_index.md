---
title: "Research Cluster Documentation"
type: docs
---

# Boettiger Lab research cluster

Documentation for the lab's self-hosted Kubernetes ([K3s](https://k3s.io/)) cluster —
the computational environment our group runs on campus workstations. Configuration
lives in [boettiger-lab/k8s](https://github.com/boettiger-lab/k8s).

## The cluster

**One cluster, three nodes.** cirrus is the control plane; thelio and nimbus are workers.

| Node | Role | Hardware |
|------|------|----------|
| **cirrus** | control plane, storage, most services | Threadripper 3990X (128 core), 2× Quadro RTX 8000 48 GB, ZFS pool `tank` |
| **thelio** | amd64 GPU worker | Ryzen 9 3900X, RTX 2080 8 GB, exposed as one exclusive GPU |
| **nimbus** | arm64 GPU worker (DGX Spark) | GB10 Grace Blackwell, 128 GB unified memory; tainted for LLM inference only |

The nodes are not interchangeable — see
[Node placement]({{< relref "docs/infrastructure/node-placement" >}}) before pinning a
workload to one.

## Services — what the cluster provides

- [**JupyterHub**]({{< relref "docs/services/jupyterhub" >}}) — multi-user notebooks, CPU and GPU profiles
- [**MinIO**]({{< relref "docs/services/minio" >}}) — S3-compatible object storage for research data
- [**vLLM**]({{< relref "docs/services/vllm" >}}) — OpenAI-compatible LLM inference on both GPU nodes
- [**PostgreSQL**]({{< relref "docs/services/postgres" >}}) — relational database
- [**GitHub Actions runners**]({{< relref "docs/services/github-actions" >}}) — self-hosted CI

## Infrastructure — what holds them up

- [**K3s**]({{< relref "docs/infrastructure/k3s" >}}) — the cluster itself, and how nodes join it
- [**NVIDIA GPUs**]({{< relref "docs/infrastructure/nvidia" >}}) — device plugin and per-node sharing
- [**OpenEBS**]({{< relref "docs/infrastructure/openebs" >}}) — node-local ZFS volumes with quotas
- [**Shared home storage**]({{< relref "docs/infrastructure/shared-home-storage" >}}) — JuiceFS RWX homes
- [**RustFS**]({{< relref "docs/infrastructure/rustfs" >}}) — the S3 backend beneath JuiceFS
- [**cert-manager**]({{< relref "docs/infrastructure/cert-manager" >}}) — automatic HTTPS
- [**external-dns**]({{< relref "docs/infrastructure/external-dns" >}}) — DNS from Ingress objects
- [**Node placement**]({{< relref "docs/infrastructure/node-placement" >}}) — taints, labels, architecture

## Administration

- [**Access model & user accounts**]({{< relref "docs/admin/users" >}}) — who can reach what, and the namespace-scoped RBAC tooling
- [**Secrets**]({{< relref "docs/admin/secrets" >}}) — how credentials reach workloads
- [**Custom images**]({{< relref "docs/admin/custom-images" >}}) — the notebook and GPU images
- [**Tips & tricks**]({{< relref "docs/admin/tips-tricks" >}}) — day-to-day operations

## Getting started

1. **New user?** You want [JupyterHub]({{< relref "docs/services/jupyterhub" >}}) —
   lab members work through the hosted services (notebooks, S3 buckets, LLM endpoints),
   not through `kubectl` or SSH. See [Access model]({{< relref "docs/admin/users" >}}).
2. **Running work?** Read [Node placement]({{< relref "docs/infrastructure/node-placement" >}}) —
   arm64, GPU sharing, and node-local storage all constrain where a pod can land.
3. **Administering?** Start from [K3s]({{< relref "docs/infrastructure/k3s" >}}).

## Support

Open an issue on the [GitHub repository](https://github.com/boettiger-lab/k8s), or check
[Tips & tricks]({{< relref "docs/admin/tips-tricks" >}}) first.
