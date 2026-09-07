# platform — the supporting layer

Everything a service needs but no user asks for by name. If you are looking for what the
cluster *provides*, that is [`../services/`](../services/); the machines themselves are
[`../cluster/`](../cluster/).

| Directory | Purpose |
|---|---|
| [`traefik/`](traefik/) | Ingress controller (bundled with K3s); `HelmChartConfig` overrides, pinned to cirrus |
| [`cert-manager/`](cert-manager/) | Let's Encrypt certificates, issued automatically per Ingress |
| [`external-dns/`](external-dns/) | Cloudflare DNS records created from Ingress objects |
| [`openebs/`](openebs/) | ZFS-LocalPV — node-local volumes with enforced per-PVC quotas |
| [`juicefs/`](juicefs/) | ReadWriteMany home directories over S3, so a session can start on any node |
| [`rustfs/`](rustfs/) | RustFS object store — the S3 backend JuiceFS writes to |
| [`nvidia/`](nvidia/) | GPU device plugin; per-node sharing (time-slicing vs exclusive) |
| [`monitoring/`](monitoring/) | Prometheus, Grafana, DCGM / SMART / node exporters, carbon API |
| [`users/`](users/) | Namespace-scoped user access: ServiceAccount, RBAC, kubeconfig generation |

Rough dependency order when building a cluster from nothing: storage (`openebs`) →
certificates and DNS (`cert-manager`, `external-dns`) → GPUs (`nvidia`) → shared homes
(`rustfs`, then `juicefs`) → `monitoring` and `users` whenever convenient. Traefik comes
with K3s.
