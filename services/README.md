# services — what the cluster provides

The user-facing half of the repo. What holds these up is
[`../platform/`](../platform/); the machines are [`../cluster/`](../cluster/).

| Directory | Provides | URL |
|---|---|---|
| [`jupyterhub/`](jupyterhub/) | Multi-user notebooks (CPU + GPU profiles), BinderHub | [jupyterhub.cirrus](https://jupyterhub.cirrus.carlboettiger.info) |
| [`minio/`](minio/) | S3-compatible object storage for research data | [minio](https://minio.carlboettiger.info), [data](https://data.carlboettiger.info) |
| [`vllm/`](vllm/) | OpenAI-compatible LLM inference, one model per GPU node | [vllm-cirrus](https://vllm-cirrus.carlboettiger.info), [vllm-nimbus](https://vllm-nimbus.carlboettiger.info) |
| [`titiler/`](titiler/) | Dynamic tile server for cloud-optimized rasters | [titiler](https://titiler.carlboettiger.info) |
| [`hash-archive/`](hash-archive/) | Content-hash registry for data provenance | [hash-archive](https://hash-archive.carlboettiger.info) |
| [`postgres/`](postgres/) | PostgreSQL for research use — **not currently deployed** | — |
| [`github-actions/`](github-actions/) | Self-hosted CI runners for lab repositories | — |
| [`openshell/`](openshell/) | Sandboxed AI-agent runtime — **not yet deployed** | — |
| [`armada/`](armada/) | Batch/job scheduler — **not currently deployed** | — |

Each directory has its own README and, usually, an `up.sh` / `down.sh`. There is no
GitOps controller: changes are applied by hand, and the manifests here are meant to match
the live cluster.

Before deploying anything that needs a GPU, an arm64 image, or node-local storage, read
[node placement](https://boettiger-lab.github.io/k8s/docs/infrastructure/node-placement/) —
the three nodes are not interchangeable.
