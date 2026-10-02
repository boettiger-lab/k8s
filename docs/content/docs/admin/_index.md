---
title: "Administration"
weight: 3
bookCollapseSection: false
---

# Administration

- [Users and access]({{< relref "users" >}}): hub login, personal
  namespaces, kubeconfigs, OAuth apps
- [Custom images]({{< relref "custom-images" >}}): the lab images and how to
  build your own
- [Deploying a service]({{< relref "deploying-a-service" >}}): the pattern
  every service follows

## Where things are written down

Each kind of information has one home:

| Kind | Home |
|---|---|
| What the cluster offers and how to use it | this site |
| How a component is configured, and why | the manifests and READMEs in [boettiger-lab/k8s](https://github.com/boettiger-lab/k8s) |
| What is running right now | the cluster itself ([Checking current state]({{< relref "/docs/using/current-state" >}})) |
| Open work and known problems | [GitHub issues](https://github.com/boettiger-lab/k8s/issues) |
| Hardware records, maintenance logs, operational notes | the lab's private operations repository |

When something changes, update its one home rather than adding a note
somewhere else.
