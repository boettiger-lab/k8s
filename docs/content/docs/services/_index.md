---
title: "Services"
weight: 2
bookCollapseSection: false
---

# Services

What the cluster provides to the people using it. Repo directory:
[`services/`](https://github.com/boettiger-lab/k8s/tree/main/services).

## Available services

| Service | What it is | Where |
|---|---|---|
| [**JupyterHub**](jupyterhub) | Multi-user notebooks, CPU and GPU profiles | [jupyterhub.cirrus.carlboettiger.info](https://jupyterhub.cirrus.carlboettiger.info) |
| [**MinIO**](minio) | S3-compatible object storage for research data | [minio.carlboettiger.info](https://minio.carlboettiger.info) |
| [**vLLM**](vllm) | OpenAI-compatible LLM inference, one model per GPU node | [vllm-cirrus](https://vllm-cirrus.carlboettiger.info), [vllm-nimbus](https://vllm-nimbus.carlboettiger.info) |
| [**PostgreSQL**](postgres) | Relational database | in-cluster |
| [**GitHub Actions runners**](github-actions) | Self-hosted CI for lab repositories | — |

Also deployed, configured in the repo but without a docs page yet: **titiler** (tile
server for cloud-optimized rasters) and **hash-archive** (content-hash registry for
data provenance).

## Prerequisites

Services assume the [infrastructure]({{< relref "../infrastructure" >}}) is in place:
K3s running, storage class available, certificates and DNS automated, and the GPU
device plugin installed for anything that wants a GPU.

## Deployment pattern

Most service directories carry a deploy script and a README:

```bash
cd services/<service>
./up.sh      # deploy
./down.sh    # remove
```

Or `kubectl` / Helm directly:

```bash
kubectl apply -f <manifest>.yaml
helm upgrade -i <release> <chart> -f values.yaml
```

There is no GitOps controller — changes are applied by hand, and the manifests in the
repo are meant to match the live cluster.
