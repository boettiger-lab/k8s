---
title: "Data services"
weight: 6
---

# Data services

| Service | URL | What it does | Auth |
|---|---|---|---|
| TiTiler | `https://titiler.carlboettiger.info` | Map tiles from cloud-optimized GeoTIFFs (`/cog/...`) | none |
| DuckDB MCP | `https://duckdb-mcp.carlboettiger.info` | MCP server that gives LLM agents SQL over DuckDB | none |
| Hash archive | `https://hash-archive.carlboettiger.info` | Content-hash registry for data provenance | basic auth |
| Carbon dashboard | `https://carbon.carlboettiger.info` | Energy and CO₂ per token for the served LLMs; see [Monitoring]({{< relref "/docs/architecture/monitoring" >}}) | none |
| Grafana | `https://grafana-cirrus.carlboettiger.info` | Node, GPU and disk-health dashboards | login |
