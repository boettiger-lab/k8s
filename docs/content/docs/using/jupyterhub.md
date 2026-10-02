---
title: "JupyterHub"
weight: 2
---

# JupyterHub

**<https://jupyterhub.cirrus.carlboettiger.info>**. Log in with GitHub; see
[Getting access]({{< relref "access" >}}).

## Starting a server

The launcher asks four questions.

**Environment**

| Option | Image | GPU |
|---|---|---|
| Default CPU environment | `ghcr.io/boettiger-lab/k8s` (Python, R, geospatial stack) | none |
| RL GPU | `ghcr.io/boettiger-lab/k8s-gpu` (CUDA, PyTorch, RL tooling) | 1 |
| GPU Spatial | `ghcr.io/rocker-org/ml-spatial` | 1 |
| Custom image | any public `image:tag` | none |
| Build from a repository | built on the fly by BinderHub | none |

**GPU.** For the GPU environments, choose where the GPU comes from:
- **Environment default:** a shared slice of one of the large workstation GPUs
  (Quadro RTX 8000, 48 GB). Other users can be on the same card.
- **Both workstation GPUs:** two RTX 8000s, for multi-GPU work.
- **GB10:** an NVIDIA Grace Blackwell machine. It is **arm64**, so a custom
  image must be multi-arch. GPU memory is the machine's unified memory, shared
  with the CPU.

**Interface:** JupyterLab, VS Code or RStudio.

**Memory:** 8, 16 or 32 GB. There is also a 64 GB option that can be preempted,
and a larger "special use" size. There is no CPU limit. Numeric libraries
default to one thread (`OMP_NUM_THREADS=1` and similar); raise this
deliberately when you want parallel BLAS.

## Your home directory

`/home/jovyan` is a persistent volume, 30 GB by default. It lives on shared
network storage, so it is the same no matter which machine your server lands
on. You can run several **named servers** (File → Hub Control Panel), and each
named server gets its own home.

Servers are not shut down for being idle. Stop yours from the Hub Control Panel
when you are done, especially GPU servers.

## Images

The lab images are rebuilt weekly from
[`images/`](https://github.com/boettiger-lab/k8s/tree/main/images) and pushed
to GHCR, so `latest` moves. Install extra packages into your home directory, or
build your own image; see [Custom images]({{< relref "/docs/admin/custom-images" >}}).
