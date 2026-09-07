---
title: "Infrastructure"
weight: 1
bookCollapseSection: false
---

# Infrastructure

The supporting layer: everything that has to work before a service can be deployed.
Repo directory: [`platform/`](https://github.com/boettiger-lab/k8s/tree/main/platform)
(plus [`cluster/`](https://github.com/boettiger-lab/k8s/tree/main/cluster) for the
machines themselves).

## Components

- [**K3s**](k3s) — the base cluster, and how a node joins it as an agent
- [**Node placement**](node-placement) — taints, labels, architecture, and where a pod can actually run
- [**NVIDIA GPU support**](nvidia) — device plugin, per-node time-slicing vs exclusive access
- [**OpenEBS**](openebs) — node-local ZFS volumes with enforced per-PVC quotas
- [**Shared home storage**](shared-home-storage) — JuiceFS ReadWriteMany homes
- [**RustFS**](rustfs) — the S3 object store behind JuiceFS
- [**cert-manager**](cert-manager) — automatic Let's Encrypt certificates
- [**External DNS**](external-dns) — DNS records created from Ingress objects

## Setup order

For a new cluster:

1. **K3s** — install the control plane, then join agents
2. **OpenEBS** — node-local storage
3. **cert-manager** — certificates
4. **external-dns** — DNS
5. **NVIDIA device plugin** — GPUs, then label each node's sharing mode
6. **RustFS + JuiceFS** — shared home directories

Once these are up, deploy [services]({{< relref "../services" >}}).
