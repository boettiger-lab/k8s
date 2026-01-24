# JupyterHub Setup

## Overview

This directory contains the Helm chart configuration for deploying JupyterHub on the Nimbus cluster.

## Deployment Steps

### 1. Secrets Setup

We use Kubernetes Secrets to manage sensitive information (OAuth credentials, Image Registry tokens). **Do not store secrets in plaintext config files.**

Run the interactive setup script to create the necessary secrets:

```bash
./setup-secrets.sh
```

This will prompt for:
- **GitHub OAuth Client ID & Secret**: For user authentication.
- **GitHub Container Registry (GHCR) Token**: For pulling private/custom images (e.g. `fancy-profiles`).

It creates the following secrets in the `jupyter` namespace:
- `jupyter-oauth-secret`: Contains `GITHUB_CLIENT_ID` and `GITHUB_CLIENT_SECRET`.
- `ghcr-pull-secret`: Docker registry secret for authenticating with GHCR.

### 2. Deployment

To deploy or upgrade JupyterHub on Nimbus:

```bash
./nimbus.sh
```

This script:
1. Checks that required secrets exist.
2. Updates Helm repositories.
3. Deploys using `nimbus-config.yaml`.

## Configuration

### Secrets Management

The configuration (`nimbus-config.yaml`) references K8s secrets instead of having them inline:

1.  **Image Pull Secrets**:
    *   **Root level**: `imagePullSecrets` (for singleuser pods and other hooks).
    *   **Hub image**: `hub.image.pullSecrets` (specifically for the hub pod to pull custom images).
2.  **OAuth Credentials**:
    *   Injected via `hub.extraEnv` using `valueFrom.secretKeyRef`.
    *   Read by JupyterHub in `hub.extraConfig` from environment variables.

### Network Policy

JupyterHub is configured with network policies that enable user pods to access external services including MinIO and other cluster services via hairpin connections.

The `singleuser.networkPolicy` in `nimbus-config.yaml` allows:
- Access to `minio.carlboettiger.info` (external domain) via hairpin connections.
- Connect to MinIO services in the `minio` namespace.
- Access other private IP ranges for cluster services.
- Maintain DNS resolution capabilities.

### User Environment

User pods automatically receive environment variables for MinIO access (via `KubeSpawner.environment`):
- `AWS_S3_ENDPOINT: "minio.carlboettiger.info"`
- `AWS_HTTPS: "true"`
- `AWS_VIRTUAL_HOSTING: "FALSE"`

### ARM64 Compatibility

Nimbus is an ARM64 server.
- **Profile Images**: The image pre-puller hook is **disabled** (`prePuller.hook.enabled: false`) to avoid failures when profile images (like `rocker/ml-verse`) do not have ARM64 builds.
- **Hub Image**: Uses a custom ARM64 build (`ghcr.io/cboettig/jupyterhub-fancy-profiles`).
