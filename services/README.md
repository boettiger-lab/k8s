# services — what the cluster provides

The user-facing half of the repo. What holds these up is
[`../platform/`](../platform/); the machines are [`../cluster/`](../cluster/).

| Directory | Provides | URL |
|---|---|---|
| [`jupyterhub/`](jupyterhub/) | Multi-user notebooks (CPU + GPU profiles), BinderHub | [jupyterhub.cirrus](https://jupyterhub.cirrus.carlboettiger.info) |
| [`minio/`](minio/) | S3-compatible object storage for research data | [minio](https://minio.carlboettiger.info), [data](https://data.carlboettiger.info) |
| [`vllm/`](vllm/) | OpenAI-compatible LLM inference (one model per GPU node) plus speech-to-text on cirrus | [vllm-nimbus](https://vllm-nimbus.carlboettiger.info), [vllm-nimbus2](https://vllm-nimbus2.carlboettiger.info), [whisper-cirrus](https://whisper-cirrus.carlboettiger.info) |
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
[compute architecture](https://boettiger-lab.github.io/k8s/docs/architecture/compute/) —
the nodes are not interchangeable.

## Node placement

| Nodes | Run | Why |
|---|---|---|
| **cirrus** (control plane) | Core infrastructure: dex, llm-auth, the Armada control plane (server, scheduler, ingesters, lookout, executor, operator, Postgres, Redis, Pulsar) | It holds the API server and the node-local ZFS volumes these depend on. A worker reboot or drain must not take logins, LLM auth or the job queue with it. |
| **thelio** | Compute and light helpers: notebooks, Armada jobs, ARC listeners (preferred, falling back to cirrus) | A general worker. ARC *runner* pods stay on cirrus, because their `_work` volumes are node-local there. |
| **GB10s** (nimbus, nimbus2–4) | LLMs first, then notebooks and Armada jobs | The `dedicated` taint keeps everything else off. |

Core services are pinned with `nodeSelector: kubernetes.io/hostname: cirrus` in their own manifests or values. A new core service should do the same.
