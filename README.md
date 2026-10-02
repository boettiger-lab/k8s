# boettiger-lab/k8s

Kubernetes ([K3s](https://k3s.io/)) configuration for the Boettiger Lab's self-hosted
research cluster. This repo holds the manifests, Helm values, and bootstrap scripts
that run our group's computational environment — JupyterHub notebooks, object storage,
databases, LLM inference, and CI runners — on campus GPU workstations.

📖 **Full documentation:** <https://boettiger-lab.github.io/k8s/>
(built with Hugo from [`docs/`](docs/))

## The cluster

**One K3s cluster** of campus workstations, each with a distinct role. The live
roster is `kubectl get nodes -L kubernetes.io/arch,node-class,gb10-pool`; host
configuration and per-node rationale are under [`cluster/nodes/`](cluster/nodes/).

| Role | Node(s) | Notes |
|------|---------|-------|
| **Control plane, storage, ingress** | cirrus (amd64, 2× Quadro RTX 8000) | Holds the ZFS pool `tank`, Traefik, MinIO and the JuiceFS backends. **Never cordon it.** |
| **GB10 GPU workers** | nimbus, nimbus2, … (arm64, unified memory) | Tainted `dedicated=gb10:NoSchedule` fleet-wide; LLM inference, or jupyter where labelled `gb10-pool=jupyter`. |
| **Jupyter-only GPU worker** | thelio (amd64, RTX 2080) | Tainted `hub.jupyter.org/dedicated=user:NoSchedule`; one exclusive GPU, not time-sliced. |

Nodes differ in ways that matter when scheduling: the GB10s are **arm64**, so an
image must be multi-arch to run there, and their taint must be tolerated explicitly;
only cirrus provides `openebs-zfs` volumes (homes on JuiceFS are RWX and follow a user
to any node); GPU sharing is configured per node (see
[`platform/nvidia/`](platform/nvidia/)).

## Repository layout

The split is by *audience*: `services/` is what the cluster provides to people,
`platform/` is what makes those services possible, `cluster/` is the machines
themselves.

### [`services/`](services/) — what end users get

| Directory | Provides | URL |
|-----------|----------|-----|
| [`jupyterhub/`](services/jupyterhub/) | Multi-user notebooks (CPU + GPU profiles), BinderHub | [jupyterhub.cirrus](https://jupyterhub.cirrus.carlboettiger.info) |
| [`minio/`](services/minio/) | S3-compatible object storage for research data | [minio](https://minio.carlboettiger.info), [data](https://data.carlboettiger.info) |
| [`vllm/`](services/vllm/) | OpenAI-compatible LLM inference (one model per GPU node) plus speech-to-text on cirrus | [vllm-nimbus](https://vllm-nimbus.carlboettiger.info), [vllm-nimbus2](https://vllm-nimbus2.carlboettiger.info), [whisper-cirrus](https://whisper-cirrus.carlboettiger.info) |
| [`titiler/`](services/titiler/) | Dynamic tile server for cloud-optimized rasters | [titiler](https://titiler.carlboettiger.info) |
| [`hash-archive/`](services/hash-archive/) | Content-hash registry for data provenance | [hash-archive](https://hash-archive.carlboettiger.info) |
| [`mcp/`](services/mcp/) | GPU MCP data server (cudf/polars over the STAC catalogue), on nimbus | parked (`replicas: 0`, no ingress) |
| [`postgres/`](services/postgres/) | PostgreSQL for research use (**not currently deployed**) | — |
| [`github-actions/`](services/github-actions/) | Self-hosted CI runners for lab repos | — |
| [`openshell/`](services/openshell/) | Sandboxed AI-agent runtime (**not yet deployed**) | — |
| [`armada/`](services/armada/) | Batch/job scheduler (**not currently deployed**) | — |

Deployed but **not yet captured here**: the `duckdb-mcp` and `gpu-mcp` servers in the
`mcp` namespace (distinct from `services/mcp/`, which is the nimbus GPU data server),
the `llm-proxy` gateway, `high-seas`, and `hxagent`. They run from manifests that live
elsewhere; folding them in is outstanding work.

### [`platform/`](platform/) — what holds them up

| Directory | Purpose |
|-----------|---------|
| [`traefik/`](platform/traefik/) | Ingress controller (K3s built-in), `HelmChartConfig` overrides |
| [`cert-manager/`](platform/cert-manager/) | Automatic Let's Encrypt certificates |
| [`external-dns/`](platform/external-dns/) | DNS records created from Ingress objects (Cloudflare) |
| [`openebs/`](platform/openebs/) | ZFS-LocalPV — node-local volumes with real per-PVC quotas |
| [`juicefs/`](platform/juicefs/) | S3-backed ReadWriteMany home directories, so a session can start on any node |
| [`rustfs/`](platform/rustfs/) | RustFS object store — the JuiceFS data backend |
| [`nvidia/`](platform/nvidia/) | GPU device plugin; per-node sharing (time-slicing vs exclusive) |
| [`monitoring/`](platform/monitoring/) | Prometheus, Grafana, DCGM/SMART/node exporters, carbon API |
| [`users/`](platform/users/) | Namespace-scoped user access (ServiceAccount + RBAC + kubeconfig) |

### [`cluster/`](cluster/) — the machines

K3s install/reset, remote kubeconfig, automated node upgrades, and per-node host
hardening under [`cluster/nodes/`](cluster/nodes/) (kernel tunables, GPU watchdog,
lockup capture). Host-level operational journals live in the private `cluster-ops`
repo, not here.

### Everything else

| Directory | Purpose |
|-----------|---------|
| [`images/`](images/) | Custom container images (Jupyter, GPU, openvscode); built via GitHub Actions |
| [`docs/`](docs/) | Hugo documentation site, published to GitHub Pages |
| [`examples/`](examples/) | Deployment examples (e.g. Shiny apps) |
| [`nrp/`](nrp/) | Kubeconfig for the National Research Platform (an *external* cluster) |
| [`secrets/`](secrets/) | Notes on secret material — **git-ignored**, never committed |

## Getting started

**For users** — you need namespace-scoped credentials. See the
[User Access Management](https://boettiger-lab.github.io/k8s/docs/admin/users/)
guide and [`platform/users/`](platform/users/).

**For administrators** — bootstrap order for a node:

1. **K3s** — install the base cluster (control plane) or join an agent:
   ```bash
   ./cluster/install-reset-K3s.sh    # K3s with Traefik + world-readable kubeconfig
   ```
2. **Storage** — `bash platform/openebs/helm.sh`, then apply the StorageClasses
3. **HTTPS + DNS** — `bash platform/cert-manager/helm.sh`, `bash platform/external-dns/helm.sh`
4. **GPU** — `bash platform/nvidia/nvidia-device-plugin.sh`, then label the node's
   sharing mode (see [`platform/nvidia/`](platform/nvidia/))
5. **Shared homes** — [`platform/juicefs/`](platform/juicefs/)

Then deploy services. Each service directory has a `README.md` and usually an
`up.sh` / `deploy.sh` / `helm.sh`:

```bash
cd services/<service>
./up.sh
# or directly:
kubectl apply -f <manifest>.yaml
helm upgrade -i <release> <chart> -f values.yaml
```

There is no GitOps controller — changes are applied deliberately, by hand. Manifests
here are meant to match the live cluster; if you change one, apply it.

## Secrets

Secrets are **never committed**. `.gitignore` excludes kubeconfigs, `*.key`,
`*secret*`, `*private*`, `*-kubeconfig.yaml`, `values.private*.yaml`, and the
`secrets/` directory. Where a service needs credentials, an interactive setup
script creates the Kubernetes `Secret` objects (e.g.
`services/jupyterhub/setup-secrets.sh`, `platform/rustfs/setup-rustfs.sh`); otherwise
the manifest's header names the Secret and its keys, to be created by hand with
`kubectl create secret generic` (e.g. `services/minio/minio.yaml`).

## Documentation site

[`docs/`](docs/) is a [Hugo](https://gohugo.io/) site using the
[Hugo Book](https://github.com/alex-shpak/hugo-book) theme, auto-deployed to GitHub
Pages via `.github/workflows/hugo.yml` on every push to `main`.

```bash
cd docs
hugo server -D                   # live-reload preview at http://localhost:1313
```

See [`docs/README.md`](docs/README.md) for authoring conventions.

## License

[Apache License 2.0](LICENSE).
