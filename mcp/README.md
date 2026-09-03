# MCP servers

Model Context Protocol servers exposed to agents and notebooks.

| Directory | Service | Host |
|---|---|---|
| [`nimbus/`](nimbus/) | `mcp-data-server`, GPU query engine (cudf/polars) over the public STAC catalogue | <https://gpu-mcp-nimbus.carlboettiger.info> |

## nimbus

Runs on the nimbus GB10 as one of its sanctioned workloads — it carries the
`dedicated=nimbus` toleration and a `kubernetes.io/hostname: nimbus`
nodeSelector, and its image tag (`gpu-arm64`) is arm64-only. See
[`k3s/nimbus-join/`](../k3s/nimbus-join/) for why nimbus is tainted.

```bash
kubectl apply -f mcp/nimbus/
kubectl -n default rollout status deploy/mcp-gpu-nimbus
curl -s https://gpu-mcp-nimbus.carlboettiger.info/healthz
```

It claims **1** of nimbus's 8 `nvidia.com/gpu` time-slices; vLLM claims 6. A
slice is a co-tenancy slot, not a memory cap — on the GB10's unified memory
nothing here bounds actual GPU memory use. See
[`vllm/nimbus/dgx-spark-memory.md`](../vllm/nimbus/dgx-spark-memory.md).

Set `ALLOW_CPU_FALLBACK=true` and `STAC_ALLOW_DEGRADED_START=true` so a MinIO
blip degrades the server rather than turning into a CrashLoopBackOff.
