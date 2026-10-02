---
title: "Custom images"
weight: 2
---

# Custom images

## Lab images

| Image | Built from | Base |
|---|---|---|
| `ghcr.io/boettiger-lab/k8s` | `images/Dockerfile` | `rocker/ml-spatial` |
| `ghcr.io/boettiger-lab/k8s-gpu` | `images/Dockerfile.gpu` | `rocker/cuda` |
| `ghcr.io/boettiger-lab/k8s:openvscode` | `images/Dockerfile.openvscode` | |

GitHub Actions builds them on every push to `images/` and weekly, natively on
amd64 and arm64 runners. Each tag is a multi-arch manifest, so the same image
runs on the GB10s.

## Your own image

In the JupyterHub launcher, choose **Custom image** and enter any public
`image:tag`. For the JupyterHub interfaces to work, the image needs
`jupyterhub-singleuser` (the [Jupyter Docker Stacks](https://jupyter-docker-stacks.readthedocs.io/)
and [Rocker](https://rocker-project.org/) images include it). To use it on a
GB10, it must also have an arm64 build.

Alternatively, choose **Build from a repository**: BinderHub builds an image
from a Git repository's environment files (`environment.yml`,
`requirements.txt`, `install.R`, a `Dockerfile`) and launches it.
