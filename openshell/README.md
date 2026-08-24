# OpenShell (planned — not yet deployed)

[OpenShell](https://github.com/NVIDIA/OpenShell) is NVIDIA's sandboxed runtime for
autonomous AI agents: each agent runs in a container whose egress is forced through a
policy-enforcing CONNECT proxy, with Landlock filesystem confinement and seccomp on top.
It is the mechanism by which we can give students an AI coding agent on lab hardware
without giving them a shell account or unrestricted network access.

**Status: plan only.** Nothing in this directory has been applied to any cluster.
Deploy after `thelio` (or another worker) rejoins the cirrus cluster — see
[Why we wait for a second node](#why-we-wait-for-a-second-node).

Today's usage is the single-user path: `carl` ssh's into cirrus and runs the native
gateway binary against the Docker driver (`install.sh` from the OpenShell repo,
`openshell sandbox create -- claude`). That path shares **no** components with this
plan and needs no cluster changes.

## How the enforcement works (and what Kubernetes does/doesn't add)

Worth stating up front, because it is easy to assume Kubernetes is doing the confining:

Egress control lives entirely in the **supervisor process inside the sandbox container**.
It creates a dedicated network namespace with a veth pair, routes all traffic to a
CONNECT proxy, and evaluates every connection and request against an OPA policy
(host, port, HTTP method/path, GraphQL operation, MCP method, *and* the calling binary),
deny-by-default. Then it applies seccomp, Landlock, and drops privileges before exec'ing
the agent. This is identical under the Docker driver and the Kubernetes driver.

Kubernetes adds nothing to egress policy — `NetworkPolicy` cannot express hostnames,
HTTP paths, or binary identity. What Kubernetes adds is everything *around* the sandbox:

| Kubernetes gives us | Why we want it |
|---|---|
| Per-workspace namespaces (`workspaceMode: managed`) | Real multi-tenant isolation between students |
| ResourceQuota / LimitRange | One student's agent cannot eat 128 cores |
| Scheduling + node selectors | Sandboxes land on a worker, never on the control plane |
| User namespaces (`hostUsers: false`) | Container UID 0 maps to an unprivileged host UID |
| RuntimeClass hook | Optional kata/gVisor VM-level isolation |
| NetworkPolicy | An outer egress fence *we* own and students cannot widen |
| GPU scheduling | Fair-share access to the RTX 8000s |

## Why we wait for a second node

In the default `combined` supervisor topology the sandbox container is granted
`SYS_ADMIN`, `NET_ADMIN`, `SYS_PTRACE`, and `SYSLOG`. Running that on cirrus means an
untrusted student agent with those capabilities sits on the same kernel as the control
plane, minio/rustfs/juicefs credentials, the GitHub Actions runner tokens in
`arc-runners`, the API keys in `llm-proxy`, and the cert-manager CA. A container escape
is a full-cluster and full-data compromise.

The mitigation is a **dedicated worker**: sandbox pods are pinned to a tainted node that
holds no secrets, no control plane, and no storage credentials. The gateway pod itself is
low-privilege (non-root, all capabilities dropped) and can stay on cirrus.

Also note the OpenShell Helm chart is explicitly labelled **Experimental — "Do not use it
in production."** That is survivable for a course environment on a disposable worker; it
is not survivable on cirrus.

## Prerequisites

Verified against cirrus on 2026-08-20 (k3s v1.36.3):

| Prerequisite | Status |
|---|---|
| Kubernetes ≥1.29, RBAC, Helm 3 | present (v1.36.3) |
| User namespaces GA (needs ≥1.36) | present |
| ImageVolume GA (supervisor sideload) | present — chart auto-selects `image-volume` |
| cert-manager + `letsencrypt-production` ClusterIssuer | present |
| external-dns for `*.carlboettiger.info` | present |
| Gateway API CRDs | present, **v1.5.1 standard**, owned by the `traefik-crd` Helm release |
| NetworkPolicy enforcement | present (k3s netpol controller) |
| NVIDIA device plugin + `nvidia` RuntimeClass | present (time-slicing, `replicas: 8`) |
| OpenShell images multi-arch (amd64 + arm64) | verified 2026-08-20 — matters for GB10/Spark workers |
| `openebs-zfs` StorageClass (enforces PVC size) | present |
| **Agent Sandbox controller + CRDs** | **missing — phase 1** |
| **OIDC issuer** | **missing — phase 2** |
| **Gateway API implementation (GatewayClass)** | **missing — phase 4** |
| Hardened RuntimeClass (kata/gVisor) | missing — optional, phase 6 |
| Dedicated sandbox worker node | **missing — blocks everything** |

## Phase 1 — Agent Sandbox controller and CRDs

Straightforward: a single manifest. OpenShell provisions sandboxes as
`sandboxes.agents.x-k8s.io` custom resources handled by the
[k8s-sigs Agent Sandbox](https://agent-sandbox.sigs.k8s.io) controller.

```bash
# Pin the version. Do NOT use .../releases/latest/download/ — see below.
kubectl apply -f https://github.com/kubernetes-sigs/agent-sandbox/releases/download/v0.5.6/manifest.yaml
kubectl -n agent-sandbox-system get pods
```

Creates the `agent-sandbox-system` namespace, the `sandboxes.agents.x-k8s.io` CRD, and a
controller Deployment. Cluster-scoped but narrow, and it does nothing until an OpenShell
sandbox resource appears.

Two things to remember:

- **Pin the release.** The upstream docs say `releases/latest/download/manifest.yaml`.
  This is an early-stage SIG project (v0.5.6 as of 2026-08-20); an unpinned apply means an
  unreviewed CRD change lands whenever we re-run it. Vendor the manifest into this
  directory when we deploy.
- **Restart the OpenShell gateway after upgrading agent-sandbox.** The gateway detects the
  served Sandbox API version once and caches it for the process lifetime. Running
  sandboxes survive the restart.

## Phase 2 — OIDC issuer (Dex)

This is the real prerequisite for multi-user, and there is a subtlety: **mTLS is not user
authentication on the Kubernetes path.** The chart's certificates are transport security
and sandbox-supervisor identity only. Without OIDC the gateway treats every authenticated
caller as a **Platform Admin**, which bypasses all workspace membership checks. So OIDC is
not a nice-to-have; it is the boundary between students.

**Use Dex, not Keycloak.** Students already authenticate to JupyterHub through GitHub org
membership (`GitHubOAuthenticator` + `allowed_organizations`, see `../jupyterhub/`).
GitHub is not an OIDC issuer, but Dex's GitHub connector federates exactly that identity
model into a real OIDC issuer with discovery, JWKS, the device grant, and a `groups` claim
derived from GitHub orgs and teams. We already have working prior art in
[`../armada/dex.yaml`](../armada/dex.yaml) — including a public static client with a
`/device/callback` redirect URI, which is the shape the OpenShell CLI needs for headless
login.

Work involved:

1. Promote Dex out of the `armada` namespace into its own top-level component (`../dex/`),
   since it becomes shared infrastructure. Move storage off `type: memory` (a restart
   currently invalidates all sessions).
2. GitHub OAuth app for `dex.carlboettiger.info` (see `../oauth-apps.md`). Add the course
   orgs (`espm-157`, `boettiger-lab`, …) as connector `orgs` with `teamNameField: slug`.
3. Ingress + cert for `dex.carlboettiger.info` — external-dns and
   `letsencrypt-production` handle both automatically.
4. Static clients: `openshell-cli` as a public client with `/device/callback` and
   `http://localhost:*/callback` redirect URIs.

Mapping into OpenShell:

```yaml
server:
  oidc:
    issuer: https://dex.carlboettiger.info
    audience: openshell-cli
    rolesClaim: groups          # Dex emits "org:team" strings
    adminRole: boettiger-lab:admins
    userRole: espm-157:students
```

`adminRole` and `userRole` must **both** be set or **both** be empty — setting one is
rejected. Roles gate platform access; per-course isolation comes from OpenShell
*workspaces*, which are separate membership records the gateway stores (`openshell
workspace create --name espm-157`, then add each student's `openshell whoami` subject).

## Phase 3 — Namespaces, quotas, and the egress fence

`cirrus/guardrails.yaml`. The chart creates **no** ResourceQuota or LimitRange, and its
only NetworkPolicy restricts SSH (2222) *ingress* to sandbox pods. Everything that bounds
a student's blast radius at the cluster level is ours to write:

- Sandbox namespace separate from the gateway namespace.
- ResourceQuota + LimitRange (CPU, memory, GPU count, PVC count and total size, pod count).
- An **egress NetworkPolicy** denying the pod CIDR (`10.42.0.0/16`), service CIDR
  (`10.43.0.0/16`), link-local, the campus LAN (`128.32.85.0/24`), and the docker bridges,
  while allowing DNS and the gateway. This is the layer students cannot widen: OpenShell
  per-sandbox policy is theirs to edit, this is not.
- `workspaceStorageClass: openebs-zfs` — ZFS enforces the PVC size. The default
  `local-path` does **not**, and cirrus's root filesystem is already 70% full.

### Pinning sandboxes to the worker — gap to close

The chart's `nodeSelector`/`tolerations` values apply to the **gateway pod only**. Sandbox
pod placement is exposed only per-create:

```bash
openshell sandbox create --driver-config-json '{"kubernetes":{"pod":{"node_selector":{"role":"sandbox"}}}}'
```

That is student-controlled, so it is not an admin guarantee. To *force* every sandbox onto
the tainted worker, enable the `PodNodeSelector` admission plugin and annotate the sandbox
namespace:

```bash
# k3s server flag
--kube-apiserver-arg=enable-admission-plugins=PodNodeSelector
```
```yaml
metadata:
  annotations:
    scheduler.alpha.kubernetes.io/node-selector: "role=sandbox"
```

Alternative if we would rather not touch apiserver flags: a Kyverno mutating policy. Pick
one before deploying — without it, sandboxes can schedule onto cirrus.

## Phase 4 — Ingress for students

Yes, we need it: students will not `kubectl port-forward`, and they have no kubeconfig.
The gateway becomes their single network entry point, and the sandbox SSH session is
relayed over that same gRPC endpoint — one hostname, one port, no sshd exposure and no
Unix accounts on any node.

The complication: the chart only emits a Gateway API **GRPCRoute** (or an OpenShift
Route). There is no plain Ingress option, so Traefik is not a drop-in, and there is
currently **no GatewayClass** on the cluster — the Gateway API CRDs are installed but
nothing serves them.

Two options, in order of preference:

**Option A — enable Traefik's Gateway API provider.** Traefik 3.7.8 is already running,
already owns `:443`, already integrates with cert-manager and external-dns, and supports
GRPCRoute. Enabling the `kubernetesGateway` provider creates a `traefik` GatewayClass we
can point `grpcRoute.gateway.className` at. Fewest moving parts and no port conflict.
Risk: it changes configuration on our production ingress controller, and the OpenShell
chart is only *tested* against Envoy Gateway. Validate on a throwaway GRPCRoute first.

**Option B — Envoy Gateway in its own namespace.** What the chart is tested with. Two
gotchas:

- The Gateway API CRDs are owned by the `traefik-crd` Helm release
  (`meta.helm.sh/release-name: traefik-crd`, `resource-policy: keep`). Installing Envoy
  Gateway's chart normally will fail with an ownership conflict — install with
  `--skip-crds` and confirm Envoy Gateway supports Gateway API v1.5.1.
- Traefik already binds host ports 80/443 through k3s ServiceLB, so a second
  LoadBalancer wanting 443 collides. Pin Envoy's LoadBalancer to the sandbox worker with
  the ServiceLB node-pool labels (`svccontroller.k3s.cattle.io/enablelb` plus matching
  `svccontroller.k3s.cattle.io/lbpool` on node and Service), so it takes 443 on a node
  where Traefik's LB is not running. Failing that, expose a high port such as 8443.

Either way the terminating proxy sees the TLS, so:

```yaml
grpcRoute:
  enabled: true
  hostnames: [openshell.cirrus.carlboettiger.info]
server:
  disableTls: true      # the proxy terminates TLS; gateway speaks plaintext h2c behind it
```

Because TLS terminates at the proxy the gateway never sees a client certificate, so
**client identity must come from the OIDC bearer token** — which is why phase 2 comes
first. Do not put an OIDC `SecurityPolicy` on the proxy itself: that flow is
browser-redirect based and cannot work with a CLI or a headless agent. The proxy forwards
the `authorization` metadata untouched and the gateway validates it.

Student onboarding then reduces to:

```bash
# on the student's own laptop
curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh | sh
openshell gateway add https://openshell.cirrus.carlboettiger.info --name cirrus \
  --oidc-issuer https://dex.carlboettiger.info --oidc-client-id openshell-cli
openshell sandbox create -- claude
```

Note this is a CLI/TUI, not a web portal — a real UX change from JupyterHub, and it will
land better with the terminal-comfortable subset of a class. Treat it as an addition to
JupyterHub, not a replacement.

## Phase 5 — Install the gateway

```bash
kubectl create namespace openshell
kubectl apply -f cirrus/guardrails.yaml
helm upgrade --install openshell oci://ghcr.io/nvidia/openshell/helm-chart \
  --version 0.0.109 -n openshell -f cirrus/values.yaml
kubectl -n openshell rollout status statefulset/openshell
```

Pin the chart version (releases are `0.0.x`; `0.0.109` as of 2026-08-20) and keep the
**CLI and gateway versions in lockstep** — they are released together.

## Phase 6 — Hardened RuntimeClass

**Students do not get GPUs inside their sandboxes.** That decision removes the awkward
part of this plan: the reason a hardened runtime was previously "optional with caveats" was
that passing a GPU into a kata VM needs VFIO passthrough of the whole device, and gVisor's
GPU support is shaky. With no GPU in the sandbox, there is one hardened tier and no
tiering to reason about:

- `enableUserNamespaces: true` unconditionally. Container UID 0 maps to an unprivileged
  host UID and capabilities become namespaced. This was previously in tension with the
  NVIDIA device plugin, whose user-namespace compatibility NVIDIA documents as
  **unverified**; with no device plugin in the sandbox, the tension is gone.
- **kata-containers** becomes straightforwardly worth doing (`server.defaultRuntimeClassName:
  kata-containers`). Each sandbox gets its own guest kernel, so an escape lands in a VM
  rather than on the node.

Remaining unknowns for kata, both worth a spike before committing:

- On k3s, runtime handlers are registered through a
  `/var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.tmpl` template rather than
  `kata-deploy`'s stock containerd patching.
- kata needs KVM. Present on cirrus and on any x86 worker; **unverified on GB10/Spark**
  (arm64, DGX OS). If the sandbox node is a Spark, confirm `/dev/kvm` and arm64 kata
  support first — or keep sandboxes on an x86 worker and reserve the Sparks for GPU jobs,
  which is the allocation recommended below.

## Phase 7 — Letting agents submit GPU jobs

The interesting requirement: students' agents should be able to **submit Kubernetes Jobs**
— usually to the larger NRP/Nautilus cluster, potentially to local GPU nodes — without the
sandbox itself ever holding a GPU or a real credential.

OpenShell is unusually well suited to this, because the proxy that enforces egress is also
where credentials are injected. Two mechanisms combine:

**1. Credential injection with opaque placeholders.** The agent's environment gets a
*placeholder*, never the real token. The proxy substitutes the real value immediately
before forwarding, and only for requests whose host, port, and path match the credential
binding. Anything else fails closed with `credential_endpoint_mismatch` (HTTP 403) — and
unknown, malformed, or expired placeholders also fail closed rather than being forwarded.
So a student's agent can `kubectl apply` a Job against NRP while the NRP service-account
token stays in the gateway. Exfiltrating the sandbox environment yields a useless string.

There is no built-in provider type for a Kubernetes API server, so this means importing a
**custom provider profile** declaring the credential env var and its endpoints (the
`generic` type is documented as legacy). The `Authorization: Bearer <placeholder>` header
form is directly supported.

**2. L7 policy on the API server.** OpenShell policy matches HTTP method and path globs,
so the apiserver endpoint can be narrowed far below what a kubeconfig would allow:

```yaml
network_policies:
  - name: nrp-jobs
    endpoints:
      - host: <nrp-api-host>
        port: 443
        allow:
          - POST:/apis/batch/v1/namespaces/<ns>/jobs
          - GET:/apis/batch/v1/namespaces/<ns>/jobs/**
          - GET:/api/v1/namespaces/<ns>/pods/**
          - DELETE:/apis/batch/v1/namespaces/<ns>/jobs/**
        deny:
          - '*:/api/v1/namespaces/*/secrets/**'
```

This is defense in depth over — not instead of — Kubernetes RBAC on the token itself.
Scope the service account properly; the proxy policy is the second lock.

**Gotcha in our own guardrails:** `guardrails.yaml`'s egress fence blocks the service CIDR
`10.43.0.0/16` and the campus LAN `128.32.85.0/24`, which is exactly where a *local*
apiserver lives (`10.43.0.1:443`, `128.32.85.8:6443`). Submitting jobs to the **remote**
NRP cluster works unchanged, since that is ordinary internet egress. Submitting to the
**local** cluster requires deliberately punching a hole for the apiserver — which is worth
thinking hard about, because it hands an escaped sandbox a direct path to the control
plane. Prefer remote NRP submission; if local submission is needed, allow only the
apiserver endpoint and lean on a tightly-scoped ServiceAccount.

Longer term, `../armada/` (batch scheduler, Dex-authenticated) would be a better
submission target than the apiserver: a narrow job-submission API instead of cluster
credentials. Neither Armada nor Dex is currently deployed or verified, so treat this as a
possible direction rather than a dependency — everything above works without it.

## Where each machine fits

| Machine | Role under this plan |
|---|---|
| **cirrus** (x86, RTX 8000 ×2) | Control plane. Runs the OpenShell **gateway pod** (non-root, all capabilities dropped, low risk), the ingress, and eventually Dex. Runs **no sandbox pods** — tainted against them. |
| **thelio** (x86) | The natural **sandbox node**: `role=sandbox` label + `NoSchedule` taint, no control plane, no juicefs/minio credentials, no storage secrets mounted. Sandboxes are cheap CPU workloads, x86 kata support is the known quantity, and it keeps GPU hardware free for actual jobs. |
| **Spark nodes** (arm64, GB10) | GPU job runners for agent-submitted work. Not sandbox hosts — though OpenShell images *are* multi-arch (verified amd64 + arm64), so this is an allocation choice, not a constraint. |
| **nimbus** | Separate independent cluster. A gateway serves exactly one cluster, so OpenShell there would be a second gateway with its own hostname and Helm release. Out of scope. |

### GPU sharing on the new nodes

Since no sandbox requests a GPU, time-slicing now only affects agent-submitted jobs.
For training jobs, exclusive whole-GPU allocation is more predictable than 8-way
time-slicing, and it removes cross-tenant GPU memory exhaustion as a failure mode.

This does not require touching cirrus: `nvdp-nvidia-device-plugin-configs` already carries
both a `no-sharing` and a time-slicing config, so the Sparks can select `no-sharing`
per-node via the `nvidia.com/device-plugin.config` node label while cirrus keeps
`replicas: 8`. Note GB10 has no MIG, so the choice really is whole-GPU or time-sliced.

## Open questions

- Which ingress option (Traefik Gateway provider vs Envoy Gateway)? Needs a spike.
- `PodNodeSelector` admission plugin vs Kyverno for forcing sandbox placement?
- `combined` vs `sidecar` supervisor topology. `sidecar` gives a non-root agent container
  with no added capabilities but drops filesystem and process controls, keeping network
  policy as the only in-sandbox control. On a dedicated node, `combined` is probably right.
- Global policy floor: do we set a cluster-wide `openshell policy set --global` (which
  **rejects all per-sandbox policy updates** while active), or a per-workspace floor and
  let students iterate on their own sandbox policies? A course probably wants a workspace
  floor plus student iteration, since hitting a denial and widening policy is the
  pedagogically interesting part.
- Do we inject LLM credentials via OpenShell providers pointing at our own `llm-proxy` /
  `vllm` endpoints, so students never hold API keys? This looks like the right answer and
  reuses infrastructure we already run.
- Job submission target: remote NRP apiserver (works with the egress fence as written),
  local apiserver (needs a deliberate hole in the fence), or a narrow submission API such
  as Armada (not currently deployed or verified)?
- Does kata work on arm64/GB10 with KVM, or do sandboxes stay on x86 workers?

## References

- [OpenShell Helm chart README](https://github.com/NVIDIA/OpenShell/blob/main/deploy/helm/openshell/README.md)
- [Kubernetes setup](https://docs.nvidia.com/openshell/latest/kubernetes/setup) ·
  [Ingress](https://docs.nvidia.com/openshell/latest/kubernetes/ingress) ·
  [Access control](https://docs.nvidia.com/openshell/latest/kubernetes/access-control) ·
  [Topology](https://docs.nvidia.com/openshell/latest/kubernetes/topology)
- [Security best practices](https://docs.nvidia.com/openshell/latest/security/best-practices)
- [Agent Sandbox (k8s-sigs)](https://agent-sandbox.sigs.k8s.io)
- [k3s ServiceLB node pools](https://docs.k3s.io/networking/networking-services)
