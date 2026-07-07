# boettiger-lab/k8s

Kubernetes ([K3s](https://k3s.io/)) configuration for the Boettiger Lab's
self-hosted, on-premise compute clusters. This repo holds the manifests, Helm
values, and bootstrap scripts that run our research group's computational
environment — JupyterHub notebooks, object storage, databases, LLM inference,
and CI runners — on campus GPU workstations.

📖 **Full documentation:** <https://boettiger-lab.github.io/k8s/>
(built with Hugo from [`docs/`](docs/))

## Clusters

This repo describes **more than one independent K3s cluster**. Node-specific
config lives in per-node subdirectories (e.g. `openebs/cirrus/`, `vllm/cirrus/`,
`vllm/nimbus/`), while cluster-wide components live at the top level.

| Node | Role |
|------|------|
| **cirrus** | Primary active cluster: control plane + data + GPU compute. Hosts JupyterHub, storage, and inference. **Never cordon it** — it is the control plane, data, and compute all in one. |
| **thelio** | System76 Thelio Mega GPU worker for cirrus. Currently parked/cordoned (expansion-only) pending a ZFS pool repair. |
| **nimbus** | A separate, independent cluster (`*-nimbus` config). Not part of the cirrus+thelio cluster — don't mix them. |

## Architecture

The cluster is built on:

- **K3s** — lightweight Kubernetes distribution
- **Traefik** — ingress controller (K3s built-in)
- **cert-manager** — automatic Let's Encrypt SSL/TLS certificates
- **external-dns** — automatic DNS record management
- **OpenEBS ZFS-LocalPV** — node-local persistent storage with per-PVC disk quotas
- **JuiceFS** — S3-backed ReadWriteMany shared storage for node-mobile home directories
- **NVIDIA device plugin** — GPU scheduling with time-slicing

## Repository layout

### Infrastructure

| Directory | Purpose |
|-----------|---------|
| [`k3s/`](k3s/) | K3s install/reset, remote kubeconfig, and node-upgrade tooling |
| [`nvidia/`](nvidia/) | NVIDIA device plugin + GPU time-slicing config |
| [`openebs/`](openebs/) | OpenEBS ZFS-LocalPV storage classes (per-node: `cirrus/`, `nimbus/`) |
| [`cert-manager/`](cert-manager/) | ClusterIssuer + ingress examples for automatic HTTPS |
| [`external-dns/`](external-dns/) | Automatic DNS provisioning |
| [`traefik/`](traefik/) | Traefik `HelmChartConfig` overrides |
| [`juicefs/`](juicefs/) | JuiceFS CSI storage class, Postgres metadata DB, backups |
| [`rustfs/`](rustfs/) | RustFS S3 object store (JuiceFS data backend) |

### Services

| Directory | Purpose |
|-----------|---------|
| [`jupyterhub/`](jupyterhub/) | JupyterHub + BinderHub (multi-user notebooks, GPU-enabled) |
| [`minio/`](minio/) | MinIO S3-compatible object storage |
| [`postgres/`](postgres/) | PostgreSQL database service |
| [`vllm/`](vllm/) | vLLM high-performance LLM inference (per-node: `cirrus/`, `nimbus/`) |
| [`github-actions/`](github-actions/) | Self-hosted GitHub Actions runners (per-repo values) |
| [`armada/`](armada/) | Armada batch/job scheduler |
| [`codecarbon/`](codecarbon/) | Carbon-tracking utility |

### Supporting

| Directory | Purpose |
|-----------|---------|
| [`images/`](images/) | Custom container images (Jupyter, GPU, openvscode); built via GitHub Actions |
| [`users/`](users/) | Namespace-scoped user access (ServiceAccount + RBAC + kubeconfig generation) |
| [`secrets/`](secrets/) | Local-only secret material notes (**git-ignored**, never committed) |
| [`examples/`](examples/) | Deployment examples (e.g. Shiny apps) |
| [`docs/`](docs/) | Hugo documentation site (published to GitHub Pages) |

## Getting started

**For users** — you need namespace-scoped credentials. See the
[User Access Management](https://boettiger-lab.github.io/k8s/docs/admin/users/)
guide and [`users/`](users/).

**For administrators** — bootstrap a new node in roughly this order:

1. **K3s** — install the base cluster:
   ```bash
   ./install-reset-K3s.sh        # K3s with Traefik + world-readable kubeconfig
   ```
   (`initial-setup.sh` shows the same steps plus GPU enablement.)
2. **OpenEBS** — set up ZFS-LocalPV storage (`openebs/<node>/helm.sh`)
3. **cert-manager** — automatic HTTPS certificates (`cert-manager/helm.sh`)
4. **external-dns** — automatic DNS (`external-dns/helm.sh`)
5. **NVIDIA GPU** — enable device plugin + time-slicing:
   ```bash
   bash nvidia/nvidia-device-plugin.sh
   ```

Then deploy services. Most service directories include a deploy script
(`up.sh` / `cirrus.sh` / `deploy.sh` / `helm.sh`) and a `README.md` with the
specifics. General patterns:

```bash
cd <service-directory>
./up.sh                          # or ./cirrus.sh, ./deploy.sh, etc.
# or directly:
kubectl apply -f <manifest>.yaml
helm upgrade -i <release> <chart> -f values.yaml
```

## Secrets

Secrets are **never committed**. `.gitignore` excludes kubeconfigs, `*.key`,
`*secret*`, `*-kubeconfig.yaml`, `values.private*.yaml`, the `secrets/`
directory, and more. Each service that needs credentials ships an interactive
setup script (e.g. `jupyterhub/setup-secrets.sh`, `minio/set-secrets.sh`,
`postgres/secrets.sh.example`) that creates the required Kubernetes `Secret`
objects. See the
[Secrets Management](https://boettiger-lab.github.io/k8s/docs/admin/secrets/)
docs.

## Documentation site

The `docs/` directory is a [Hugo](https://gohugo.io/) site using the
[Hugo Book](https://github.com/alex-shpak/hugo-book) theme, auto-deployed to
GitHub Pages via `.github/workflows/hugo.yml` on every push to `main`.

Build locally:

```bash
cd docs
hugo server -D                   # live-reload preview at http://localhost:1313
```

See [`docs/README.md`](docs/README.md) for authoring conventions.

## License

[Apache License 2.0](LICENSE).
