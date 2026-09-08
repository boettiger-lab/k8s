---
title: "Access Model & User Accounts"
weight: 1
bookToc: true
---

# Access Model & User Accounts

Who can reach what on this cluster, and how the (rarely used) namespace-scoped
kubectl accounts are created.

## Who has access to what

**Lab members are service users, not cluster users.** They do not have SSH access to
the nodes and they do not have `kubectl` access. They use the hosted services through
their web endpoints, authenticating with GitHub.

| | Lab members | Administrator (`carl`) |
|---|---|---|
| [JupyterHub]({{< relref "../services/jupyterhub" >}}) — notebooks, CPU/GPU profiles | ✅ primary entry point | ✅ |
| [MinIO]({{< relref "../services/minio" >}}) — S3-compatible buckets | ✅ per-user credentials | ✅ |
| [vLLM]({{< relref "../services/vllm" >}}) — OpenAI-compatible LLM endpoints | ✅ inference only | ✅ deploy/change models |
| SSH to cirrus (or any node) | ❌ | ✅ |
| `kubectl` / cluster API | ❌ | ✅ (cluster-admin) |

There is **no plan to hand out general Kubernetes access** to lab members. Everything
a user needs is meant to be reachable from a notebook, an S3 client, or an HTTP
endpoint. Anything requiring cluster credentials — new deployments, ingresses, GPU
scheduling, storage classes — is an administrator task, and the rest of this section
documents it for that audience.

### What each service gives a user

- **JupyterHub** — the main one. Login is GitHub OAuth, restricted to an allowed list;
  profiles pick CPU vs GPU and the image. Homes are shared RWX
  ([JuiceFS]({{< relref "../infrastructure/shared-home-storage" >}})), so a user's files
  follow them across profiles.
- **MinIO** — S3 buckets for research data, reachable both from inside notebooks and
  from any S3 client off-cluster. Users get object-storage credentials, not cluster
  credentials.
- **vLLM** — users *call* the OpenAI-compatible endpoint. They cannot change which model
  is served, restart the server, or touch GPU scheduling; that is done by editing the
  vLLM deployment in this repo.

### Planned, not live

Two things are staged in this repo but **not deployed**, and neither is available to
users today:

- [**Armada**](https://github.com/boettiger-lab/k8s/tree/main/services/armada) — batch
  scheduler, intended to be how users submit *headless* jobs (fair-share queueing,
  a Lookout web UI) without ever touching `kubectl`. Torn down 2026-07-11; the recipe is
  kept for a clean redeploy.
- [**OpenShell**](https://github.com/boettiger-lab/k8s/tree/main/services/openshell) —
  NVIDIA's sandboxed runtime for autonomous AI agents. This is the likely future path to
  giving *agents* a narrow, RBAC-regulated slice of the cluster on a user's behalf, still
  without giving the user a shell account. Plan only; currently used single-user via the
  Docker driver on cirrus.

## Namespace-scoped kubectl accounts

The `platform/users/` directory can mint a namespace-scoped ServiceAccount plus a
kubeconfig. **No lab member currently holds one** — it exists as admin tooling (for
example, to give a collaborator a walled-off namespace, or to hand a future agent a
limited identity) and as the mechanism the administrator's own remote kubeconfig follows.

### Permissions granted

Full CRUD **within the user's own namespace only**: pods, services, configmaps, secrets,
persistentvolumeclaims, deployments, jobs, ingresses.

Read-only cluster-wide: nodes, plus pods and events (so `kubectl describe node` works).

The account **cannot** touch other namespaces, create cluster-wide resources, or modify
RBAC.

### Creating one

```bash
cd platform/users

# 1. RBAC: namespace, ServiceAccount, Role/RoleBinding, node-read ClusterRole/Binding
./setup.sh [USERID]

# 2. Kubeconfig (1-year token)
./generate-kubeconfig.sh [USERID]
# ...or, for access from off-box:
./generate-kubeconfig.sh [USERID] --server <server-ip-or-dns-only-host>
```

**Output**: `${USERID}-kubeconfig.yaml` — treat it as a credential (`chmod 600`, never
commit it).

> The API server is on **cirrus**, port 6443. Do not point this at a
> Cloudflare-proxied hostname — proxied records do not carry 6443 and kubectl will
> simply time out. Use the node's IP, or a DNS-only (grey-cloud) record.

### Doing it by hand

```bash
export USERID=myuser

kubectl create namespace $USERID
kubectl apply -f serviceaccount.yaml
kubectl apply -f role.yaml
kubectl apply -f rolebinding.yaml
kubectl apply -f clusterrole.yaml
kubectl apply -f clusterrolebinding.yaml

TOKEN=$(kubectl create token "$USERID" -n "$USERID" --duration=8760h)

CLUSTER_NAME=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')
CLUSTER_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CLUSTER_CA=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

KCFG="${USERID}-kubeconfig.yaml"

kubectl config set-cluster ${CLUSTER_NAME} \
  --server=${CLUSTER_SERVER} \
  --certificate-authority-data=${CLUSTER_CA} \
  --kubeconfig=${KCFG} \
  --embed-certs=true

kubectl config set-credentials ${USERID} --token=${TOKEN} --kubeconfig=${KCFG}

kubectl config set-context ${USERID}-context \
  --cluster=${CLUSTER_NAME} --user=${USERID} --namespace=${USERID} --kubeconfig=${KCFG}

kubectl config use-context ${USERID}-context --kubeconfig=${KCFG}
```

### Using the kubeconfig

```bash
export KUBECONFIG=~/myuser-kubeconfig.yaml
kubectl get pods
kubectl auth can-i --list          # what this identity may do
kubectl auth whoami                # who the token says you are
```

Or per-command: `kubectl --kubeconfig=myuser-kubeconfig.yaml get pods`.

## Managing these accounts

```bash
# What exists
kubectl get namespaces
kubectl get serviceaccounts --all-namespaces

# Revoke access but keep the resources
kubectl delete serviceaccount <username> -n <username>

# Revoke everything (deletes all their resources!)
kubectl delete namespace <username>

# Adjust permissions
kubectl edit role <username> -n <username>

# Re-issue a token (e.g. 2 years) into an existing kubeconfig
TOKEN=$(kubectl create token <username> -n <username> --duration=17520h)
kubectl config set-credentials <username> \
  --token=${TOKEN} --kubeconfig=<username>-kubeconfig.yaml

# Watch what they're using
kubectl get all -n <username>
kubectl top pods -n <username>
kubectl get events -n <username>
```

### Resource quotas

Nothing is quota'd by default. If an account should be bounded, apply a ResourceQuota to
its namespace:

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: user-quota
  namespace: <username>
spec:
  hard:
    requests.cpu: "10"
    requests.memory: "20Gi"
    requests.storage: "100Gi"
    persistentvolumeclaims: "10"
    pods: "20"
```

Note that PVCs land on [node-local ZFS]({{< relref "../infrastructure/openebs" >}}) and
pin the pod to that node — see
[Node placement]({{< relref "../infrastructure/node-placement" >}}) before handing out
storage.

## Troubleshooting

**Connection refused / timeout**

```bash
kubectl config view --minify     # is the server address right?
nc -vz <server-address> 6443     # is 6443 reachable at all?
```

Most often this is the Cloudflare-proxy trap above, not a broken token.

**Forbidden**

```bash
kubectl auth whoami
kubectl auth can-i create deployments
kubectl get serviceaccount <username> -n <username>
```

**Resources appear missing** — usually the wrong namespace:

```bash
kubectl config get-contexts
kubectl get pods -n <username>
kubectl describe resourcequota -n <username>
```

## Related

- [Secrets management]({{< relref "secrets" >}}) — how credentials reach workloads
- [JupyterHub]({{< relref "../services/jupyterhub" >}}) — where lab members actually work
- [Kubernetes RBAC](https://kubernetes.io/docs/reference/access-authn-authz/rbac/)
- [K3s]({{< relref "../infrastructure/k3s" >}}) — the admin kubeconfig and remote access
