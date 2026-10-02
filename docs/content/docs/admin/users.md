---
title: "Users and access"
weight: 1
---

# Users and access

## JupyterHub login

JupyterHub authenticates with GitHub OAuth. Anyone in an allowed GitHub
organization or team can log in. The list is
`GitHubOAuthenticator.allowed_organizations` in
[`services/jupyterhub/public-config.yaml`](https://github.com/boettiger-lab/k8s/blob/main/services/jupyterhub/public-config.yaml).
To add a person, add them to one of those organizations. Removing them from it
revokes access at their next login.

The OAuth app's client ID and secret are stored in a Kubernetes Secret created
by `services/jupyterhub/setup-secrets.sh`; `--update-key` rotates a single
value. The callback URL is
`https://jupyterhub.cirrus.carlboettiger.info/hub/oauth_callback`.

## Personal namespaces and kubeconfigs

For lab members who need `kubectl`:

```bash
cd platform/users
./setup.sh <userid>                                        # namespace, ServiceAccount, Role, RoleBinding
./generate-kubeconfig.sh <userid> --server <api-host-or-ip> # token kubeconfig, valid one year
```

The user gets full control of the common resource types inside their
namespace, plus read-only access to nodes, cluster events and pods, so that
`kubectl describe node` works. The API server listens on port 6443. Use a
DNS-only hostname or the LAN address; Cloudflare-proxied hostnames don't carry
that port. See
[`platform/users/`](https://github.com/boettiger-lab/k8s/tree/main/platform/users).

To revoke access, delete the user's namespace, or just their ServiceAccount
token Secret.
