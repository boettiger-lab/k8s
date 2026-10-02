---
title: "Boettiger Lab Cluster"
type: docs
---

# Boettiger Lab research cluster

A self-hosted Kubernetes ([K3s](https://k3s.io/)) cluster run by the
[Boettiger Lab](https://boettiger-lab.github.io/) at UC Berkeley. It runs on
a handful of lab-owned machines on campus. Lab members use it for interactive
computing with GPUs, object storage, and LLM and speech-to-text APIs. Course
repositories use it for CI runners. All configuration is public in
[boettiger-lab/k8s](https://github.com/boettiger-lab/k8s).

## What it offers

| | |
|---|---|
| [JupyterHub]({{< relref "/docs/using/jupyterhub" >}}) | JupyterLab, VS Code or RStudio in the browser, with optional GPUs and a home directory that follows you between servers |
| [Object storage]({{< relref "/docs/using/object-storage" >}}) | An S3-compatible endpoint for datasets and outputs |
| [LLM and speech APIs]({{< relref "/docs/using/llm-api" >}}) | OpenAI-compatible endpoints for chat/completions and audio transcription |
| [GitHub Actions runners]({{< relref "/docs/using/github-actions" >}}) | Self-hosted runners for a few course and research organizations |
| [Data services]({{< relref "/docs/using/data-services" >}}) | Map tiles from cloud-optimized GeoTIFFs, a DuckDB MCP server, a content-hash archive |

## Where to start

- **Lab members:** [Getting access]({{< relref "/docs/using/access" >}}), then
  [JupyterHub]({{< relref "/docs/using/jupyterhub" >}}).
- **Curious how it's built:** [How it's built]({{< relref "/docs/architecture" >}}).
- **Running it:** [Administration]({{< relref "/docs/admin" >}}).

These pages describe what the cluster is and how to use it. They don't track
live state, such as which machine is up or which model is being served.
[Checking current state]({{< relref "/docs/using/current-state" >}}) explains
how to get that from the cluster itself.
