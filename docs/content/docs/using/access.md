---
title: "Getting access"
weight: 1
---

# Getting access

## JupyterHub

Log in at **<https://jupyterhub.cirrus.carlboettiger.info>** with your GitHub
account. Access goes by GitHub organization membership. If you are a lab member
or collaborator and can't log in, ask a cluster admin to add you to the right
organization or team.

## API keys and storage credentials

**LLM and speech APIs:** your key is a JupyterHub API token. Inside a
JupyterHub server it is already set as `JUPYTERHUB_API_TOKEN`; elsewhere, make
one on the hub's token page. See [LLM and speech APIs]({{< relref "llm-api" >}}).

**Object storage:** S3 credentials are not issued automatically yet. Ask a
cluster admin.

## kubectl

Lab members who need to run their own workloads can get a personal namespace
and a kubeconfig scoped to it. In that namespace you can create pods, jobs,
deployments, services, ingresses, PVCs, configmaps and secrets. Outside it you
can read node status and cluster events. Ask a cluster admin.
[Users and access]({{< relref "/docs/admin/users" >}}) describes how it's set up.
