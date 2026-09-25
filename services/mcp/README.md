# MCP servers

Model Context Protocol servers exposed to agents and notebooks.

| Directory | Service | Host |
|---|---|---|
| this directory | `mcp-data-server`, GPU query engine (cudf/polars) over the public STAC catalogue, on **nimbus** | parked: `replicas: 0`, public ingress removed 2026-09-25 |

## nimbus

Runs on the nimbus GB10 as one of its sanctioned workloads — it carries the
`dedicated=gb10` toleration and a `kubernetes.io/hostname: nimbus`
nodeSelector, and its image tag (`gpu-arm64`) is arm64-only. See
[`../../cluster/nodes/nimbus/`](../../cluster/nodes/nimbus/) for why nimbus is tainted.

```bash
kubectl apply -f services/mcp/
kubectl -n default rollout status deploy/mcp-gpu-nimbus
kubectl -n default port-forward svc/mcp-gpu-nimbus 8080:80 &
curl -s localhost:8080/healthz
```

It claims **1** of nimbus's 8 `nvidia.com/gpu` time-slices; vLLM claims 6. A
slice is a co-tenancy slot, not a memory cap — on the GB10's unified memory
nothing here bounds actual GPU memory use. See
[`../vllm/dgx-spark-memory.md`](../vllm/dgx-spark-memory.md).

Set `ALLOW_CPU_FALLBACK=true` and `STAC_ALLOW_DEGRADED_START=true` so a MinIO
blip degrades the server rather than turning into a CrashLoopBackOff.
