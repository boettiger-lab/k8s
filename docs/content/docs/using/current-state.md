---
title: "Checking current state"
weight: 7
---

# Checking current state

These docs describe what the cluster is, not its live state. Get that from the
cluster itself:

| Question | Where to look |
|---|---|
| Which model is behind an endpoint? | `GET /v1/models` on that endpoint ([LLM and speech APIs]({{< relref "llm-api" >}})) |
| Are the machines healthy? | [Grafana](https://grafana-cirrus.carlboettiger.info) node and GPU dashboards |
| What's running, and where? | with a kubeconfig: `kubectl get nodes -L gb10-pool,nvidia.com/gpu.product` and `kubectl get pods -A -o wide` |
| How much power is each model using? | [Carbon dashboard](https://carbon.carlboettiger.info) |
| Is something broken or planned? | [GitHub issues](https://github.com/boettiger-lab/k8s/issues) |
