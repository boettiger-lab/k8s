# JupyterHub Setup

## Overview

The lab's multi-user notebook service: <https://jupyterhub.cirrus.carlboettiger.info>
(short URL: <https://cirrus.carlboettiger.info>). One hub for the whole cluster —
Helm release `juypterhelm` in namespace `jupyter`, configured entirely by
`public-config.yaml`.

User homes are `ReadWriteMany` JuiceFS volumes, so a session can start on any node
that has capacity; see [`../../platform/juicefs/`](../../platform/juicefs/). GPU
profiles schedule onto cirrus or thelio via the NVIDIA device plugin
([`../../platform/nvidia/`](../../platform/nvidia/)); nimbus is tainted for
inference and does not run notebooks.

## Deployment Steps

### 1. Secrets Setup

We use Kubernetes Secrets to manage sensitive information (OAuth credentials, API keys, MinIO credentials, Image Registry tokens). **Do not store secrets in plaintext config files.**

Run the interactive setup script to create the necessary secrets:

```bash
./setup-secrets.sh
```

This will prompt for:
- **GitHub OAuth Client ID & Secret**: For user authentication.
- **NRP API Key**: For AI features via the NRP ellm endpoint (goose, OpenAI-compatible).
- **MinIO Access Key & Secret**: For S3-compatible object storage.
- **GitHub Container Registry (GHCR) Username & Token**: For pulling private/custom images.

It creates the following secrets in the `jupyter` namespace:
- `jupyter-oauth-secret`: Contains `GITHUB_CLIENT_ID` and `GITHUB_CLIENT_SECRET`.
- `jupyter-secrets`: Contains `OPENAI_API_KEY`, `MINIO_KEY`, `MINIO_SECRET`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `GHCR_USERNAME`, and `GHCR_PASSWORD`.
- `ghcr-pull-secret`: Docker registry secret for authenticating with GHCR.

#### Updating a Single Secret Key

To rotate or update one key without recreating all secrets, use the `--update-key` flag:

```bash
./setup-secrets.sh --update-key SECRET_NAME KEY [VALUE]
```

You will be prompted securely if `VALUE` is omitted. Examples:

```bash
# Update just the OpenAI/NRP API key (prompted):
./setup-secrets.sh --update-key jupyter-secrets OPENAI_API_KEY

# Update GitHub OAuth secret (value from env var):
./setup-secrets.sh --update-key jupyter-oauth-secret GITHUB_CLIENT_SECRET "$GITHUB_CLIENT_SECRET"

# Update GHCR token:
./setup-secrets.sh --update-key jupyter-secrets GHCR_PASSWORD
```

### 2. Deployment

To deploy or upgrade JupyterHub:

```bash
./up.sh
```

This updates the Helm repo and applies `public-config.yaml`. Run `setup-secrets.sh`
first — the config carries no credentials, only references to Secrets.

BinderHub is a separate release (`my-binderhub`); see `binderhub.sh` and
`binderhub-service-config.yaml`.

### Short-URL Redirect

JupyterHub is served at `jupyterhub.cirrus.carlboettiger.info`. The short URL
`cirrus.carlboettiger.info` permanently (301) redirects to it via a standalone
Traefik ingress + middleware (not part of the Helm chart, so the OAuth callback
URL stays unchanged). Apply it once after deploying:

```bash
kubectl apply -n jupyter -f cirrus-redirect.yaml
```

## Configuration

### Secrets Management

`public-config.yaml` references K8s secrets instead of carrying them inline:

1.  **Image Pull Secrets**:
    *   **Root level**: `imagePullSecrets` (for singleuser pods and other hooks).
    *   **Hub image**: `hub.image.pullSecrets` (specifically for the hub pod to pull custom images).
2.  **OAuth Credentials**:
    *   Injected via `hub.extraEnv` using `valueFrom.secretKeyRef`.
    *   Read by JupyterHub in `hub.extraConfig` from environment variables.

### Network Policy

JupyterHub is configured with network policies that enable user pods to access external services including MinIO and other cluster services via hairpin connections.

The `singleuser.networkPolicy` in `public-config.yaml` allows:
- Access to `minio.carlboettiger.info` (external domain) via hairpin connections.
- Connect to MinIO services in the `minio` namespace.
- Access other private IP ranges for cluster services.
- Maintain DNS resolution capabilities.

### User Environment

User pods automatically receive environment variables for MinIO access (via `KubeSpawner.environment`):
- `AWS_S3_ENDPOINT: "minio.carlboettiger.info"`
- `AWS_HTTPS: "true"`
- `AWS_VIRTUAL_HOSTING: "FALSE"`

#### CPU thread defaults (BLAS / OpenMP / PyTorch)

User pods set `OMP_NUM_THREADS`, `OPENBLAS_NUM_THREADS`, `MKL_NUM_THREADS`, and
`NUMEXPR_NUM_THREADS` to **`1`**. Numeric libraries otherwise spawn one thread per
*visible host core* (128) **per process** — so launching many workers (a grid
search, RL sweep, `multiprocessing`/`joblib`, or `sklearn` with `n_jobs=-1`) would
oversubscribe the CPU and thrash: high load, low useful throughput, and it degrades
the shared node for everyone. With the default of `1`, **total threads = the number
of processes you launch**, so the common "one worker per core" pattern is automatically
safe and can still fill all 128 cores. There is **no CPU limit** on pods — these
defaults exist only to stop accidental thread-thrashing, not to restrict you.

**To parallelize: launch more processes** (each stays single-threaded) — that's the
efficient path and it scales cleanly to the full node.

**To lean on parallel BLAS instead** — i.e. one big *single-process* linear-algebra /
scikit-learn / PyTorch-CPU job that should use many cores — raise it for that job:

```bash
# shell, before launching python:
export OMP_NUM_THREADS=16 OPENBLAS_NUM_THREADS=16 MKL_NUM_THREADS=16
```
```python
# or inside a notebook (PyTorch), before the heavy work:
import torch; torch.set_num_threads(16)
```

(Don't do both at once — many processes *and* high per-process threads is exactly the
oversubscription this default prevents.)

### Node placement

Notebook pods land on **cirrus** or **thelio** (both amd64). **nimbus** is arm64 and
carries `dedicated=nimbus:NoSchedule`, so nothing spawns there without an explicit
toleration — deliberate, since the profile images (`rocker/ml-verse` and friends)
have no arm64 builds. If arm64 profiles are ever wanted, they need their own images,
their own profile entries, and that toleration.
