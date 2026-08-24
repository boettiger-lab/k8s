---
title: "Custom Images"
weight: 50
bookToc: true
---

# Custom Docker Images for JupyterHub

This page describes how to build and use custom Docker images for JupyterHub single-user servers in this cluster.

## Build Locations

Source Dockerfiles live in the repository under `images/`:

- `images/Dockerfile` – Base CPU image for general use
- `images/Dockerfile.gpu` – GPU-enabled image with CUDA and NVIDIA tooling

You can extend these or create additional images as needed.

## Build and Push

Build and push from the repo root (replace `your-registry` and tags accordingly):

```bash
# CPU image
docker build -f images/Dockerfile -t your-registry/custom-notebook:latest .
docker push your-registry/custom-notebook:latest

# GPU image
docker build -f images/Dockerfile.gpu -t your-registry/custom-notebook:gpu .
docker push your-registry/custom-notebook:gpu
```

If you use GitHub Container Registry (GHCR), authenticate first and use `ghcr.io/<org-or-user>/<image>:<tag>` names.

## Use in JupyterHub

Reference your image in Helm values (see `jupyterhub/public-config.yaml` or your chosen values file):

```yaml
singleuser:
  image:
    name: ghcr.io/boettiger-lab/custom-notebook
    tag: latest
    pullPolicy: Always
```

## Tips

- Keep images slim and reproducible—prefer pinned versions.
- Pre-install common Python/R packages to reduce startup time.
- For GPU images, ensure compatibility with the host NVIDIA driver and CUDA libraries.

## Related

- See the `jupyterhub/` directory for deployment scripts and value files.
- For CI builds, see `github-actions/` examples for runner configuration.
