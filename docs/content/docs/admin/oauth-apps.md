---
title: "OAuth Apps"
weight: 5
bookToc: false
---

# GitHub OAuth applications

JupyterHub authenticates users through GitHub OAuth apps registered on the relevant
organization. Their client IDs and secrets are held in Kubernetes Secrets (see
[Secrets]({{< relref "secrets" >}})), never in this repo.

Manage them at:

`https://github.com/organizations/${ORG}/settings/applications`


- espm-157 org:
  * Jupyterhub, Nautilus, espm-157 namespace.
 
- boettiger-lab
  * JupyterHub, Cirrus server
  * Juypter-thelio, Thelio server
  * Jupyterhub Nautilus, biodiversity namespace

- eco4cast org:
  * Jupyterhub Nautilus, eco4cast namespace 

- schmidtdse
  * Jupyterhub Nautilus, schmidtdse namespace



