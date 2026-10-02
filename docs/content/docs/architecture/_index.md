---
title: "How it's built"
weight: 2
bookCollapseSection: false
---

# How it's built

A single [K3s](https://k3s.io/) cluster on lab-owned machines in one room on
campus, all on the same LAN. It has both amd64 and arm64 nodes. Everything is
open source and configured from
[boettiger-lab/k8s](https://github.com/boettiger-lab/k8s).

- [Compute and GPUs]({{< relref "compute" >}}): the node roles and how
  workloads are steered to them
- [Storage]({{< relref "storage" >}}): the storage layers and what each is for
- [Networking]({{< relref "networking" >}}): ingress, TLS and DNS
- [Model serving]({{< relref "model-serving" >}}): how LLM and speech
  endpoints are built
- [Monitoring]({{< relref "monitoring" >}}): metrics, dashboards and carbon
  accounting
- [Repository and deployment]({{< relref "repository" >}}): how the repo is
  laid out and how changes are applied
