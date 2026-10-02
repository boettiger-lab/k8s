---
title: "Repository and deployment"
weight: 6
---

# Repository and deployment

[boettiger-lab/k8s](https://github.com/boettiger-lab/k8s):

| Directory | Contents |
|---|---|
| `cluster/` | node bootstrap: K3s server and agent configuration, per-node-class setup, OS update policy |
| `platform/` | shared infrastructure: GPU plugin, storage, ingress, certificates, DNS, monitoring, user namespaces |
| `services/` | user-facing services, one directory each |
| `images/` | the lab's notebook images, built by GitHub Actions |
| `docs/` | this site |

Each service directory holds its manifests or Helm values, a README, and
usually an `up.sh`. Comments in the manifests explain why things are
configured the way they are; that is the reference for design detail.

**There is no GitOps controller.** Changes are applied by hand with
`kubectl apply` or `helm upgrade -i` after merging to `main`, so a manifest in
`main` describes intended state. Secrets are created by per-service setup
scripts and are never committed.
