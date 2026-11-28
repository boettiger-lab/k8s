# glen-runner

The pod the DSE agent uses to run GLEN benchmark flights against the GB10s' vLLM servers, and to
collect and grade them. The procedure is in glen-benchmark's run-benchmark skill, "On the lab
cluster", and the scripts are in glen-benchmark `scripts/dse/`.

- **Runs on thelio,** from `/var/lib/glen-work` on thelio's disk, mounted at `/work`. Node and DuckDB
  work runs here, never on the cirrus host.
- **A bare Pod,** so nothing replaces it while a flight runs under `kubectl exec`. Check
  `pgrep -f run.js` before deleting it.
- **Calls models directly** at `https://vllm-<node>.carlboettiger.info/v1`, without the proxy, and
  bench MCP at its public URL (`https://bench-duckdb-mcp.nrp-nautilus.io/mcp`).

```bash
kubectl apply -f glen-runner.yaml      # the directory must exist on thelio
```

## /work

| Path | What |
|---|---|
| `src/geo-agent`, `src/glen-harness` | SchmidtDSE `glen` and `glen-harness` checkouts at the tags under test |
| `<app>/` | app checkouts (`biodiversity`, `bosl-high-seas`, `ca-30x30`, `global-30x30`, `tpl`, `tpl-ca`, `wetlands` = `wetlands-v2`) at the commits under test |
| `gb<N>/` | glen-benchmark copies: the runner and the grading tree. glen-benchmark is private and the pod has no GitHub credentials, so they're copied in from a worktree (`git ls-files -z \| xargs -0 tar -c \| kubectl exec -i glen-runner -- tar -x -C /work/gb<N>`). |
| `pylib/` | Python packages for collection and grading (`pip install --target /work/pylib duckdb pyyaml pandas`), used with `PYTHONPATH=/work/pylib` |
| `runs/<flight>/` | per-cell transcripts and stderr, and `VERSIONS.json` |
| `rawlogs/<flight>/` | raw logs, published with the run in glen-benchmark-runs |

## Keys

They live only in the pod's `/tmp`, so a restart drops them. Never put them under `/work`.

- `/tmp/proxy_key` is the vLLM key:
  `kubectl -n vllm get secret vllm-api-key -o jsonpath='{.data.api-key}' | base64 -d | kubectl exec -i glen-runner -- sh -c 'cat > /tmp/proxy_key'`
- `/tmp/mcp_token` is bench's `cirrus` key. The DSE agent has it as `MCP_TOKEN_CIRRUS` and writes it the
  same way.
