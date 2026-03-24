# Armada Batch Scheduler

[Armada](https://armadaproject.io/) is a CNCF sandbox project for high-throughput batch job scheduling across Kubernetes clusters. It provides fair-share queuing, gang scheduling, and a web UI (Lookout) for job monitoring.

## Architecture

```
armada namespace
├── armada-server            — gRPC API server (job submission)
├── armada-scheduler         — Batch job scheduler (owns scheduler DB schema)
├── armada-scheduleringester — Ingests Pulsar events → Scheduler DB
├── armada-eventingester     — Ingests Pulsar events → Redis streams (required for armadactl watch)
├── armada-executor          — Watches this k3s cluster; submits jobs as pods
├── armada-lookout           — Web UI dashboard (https://armada.carlboettiger.info)
├── armada-postgresql        — Job state storage: databases scheduler, lookout (server uses lookout DB)
├── armada-redis             — Queue caching
└── armada-pulsar            — Message broker / event streaming (Apache chart)

armada-jobs namespace        — where batch jobs run as pods
```

## Prerequisites

All already present on this cluster:
- cert-manager (`letsencrypt-production` ClusterIssuer)
- Traefik ingress controller
- `local-path` storage class

## Install

```bash
cd armada/
bash install.sh
```

The script installs dependencies in order, then applies all component CRs.

## Endpoints

| Service | URL |
|---------|-----|
| Lookout UI | https://armada.carlboettiger.info |
| gRPC API | `armada-api.carlboettiger.info:443` |

## Submitting Jobs

Install `armadactl`:
```bash
# Download from https://github.com/armadaproject/armada/releases
go install github.com/armadaproject/armada/cmd/armadactl@latest
```

Configure `~/.armadactl.yaml` (OIDC via GitHub — boettiger-lab org membership required):
```yaml
currentContext: cirrus
contexts:
  cirrus:
    armadaUrl: armada-api.carlboettiger.info:443
    openIdDeviceAuth:
      providerUrl: https://dex.carlboettiger.info
      clientId: armadactl
      scopes: [openid, profile, email, groups, offline_access]
    cacheRefreshToken: true
```

On first use, armadactl will prompt you to authenticate via GitHub in a browser.
Token is cached in the OS keyring for subsequent calls (requires CGO-enabled binary;
build with `CGO_ENABLED=1 go install github.com/armadaproject/armada/cmd/armadactl@latest`).

## Cirrus Cluster Notes

Key constraints discovered through testing:

- **Namespace:** `armada-jobs` (jobs must specify this explicitly)
- **Queue:** `test` (already exists; create new queues with `armadactl create queue <name> --priority-factor 1`)
- **Minimum resources:** `cpu: 1, memory: 1Gi` — smaller requests (e.g. cpu: 100m) are not scheduled
- **No opportunistic priority class** — only `armada-default`, `armada-preemptible`, `armada-resilient`
- **No pool annotation needed** — the default pool works without explicit annotation
- **`armadactl watch` requires `eventsApiRedis` configured** — the base config defaults to `redis:6379` (wrong hostname); fixed in `armada-server.yaml` and the patched secret

## Submitting Jobs

Create a queue (one-time):
```bash
armadactl create queue test --priority-factor 1
```

Submit a job:
```bash
cat > job.yaml <<EOF
queue: test
jobSetId: my-first-jobs
jobs:
  - priority: 1
    namespace: armada-jobs
    podSpec:
      containers:
        - name: hello
          image: alpine:3
          command: ["echo", "hello from Armada"]
          resources:
            requests: { cpu: "1", memory: "1Gi" }
            limits:   { cpu: "1", memory: "1Gi" }
EOF
armadactl submit job.yaml
```

Watch job events (streams until job completes):
```bash
armadactl watch test my-first-jobs
```

Or check job status with:
```bash
armadactl get job-report -q test --jobset my-first-jobs
```

Or open the Lookout UI at https://armada.carlboettiger.info.

## Component Image Tags

All components use the `latest` tag from `gresearch/` on Docker Hub (Armada does
not publish semver-tagged images; SHA tags are available for pinning).

## Known Workarounds

### Executor: operator v0.7.0 port bug

The armada-operator v0.7.0 generates an invalid Executor Deployment (missing
`containerPort` on the profiling port). The Deployment is therefore managed
manually via `armada-executor-deployment.yaml` instead of by the operator.

If the executor pod disappears, re-apply:
```bash
kubectl apply -f armada-executor-deployment.yaml
```

### Lookout: `apiPort` vs `lookoutapiPort` key rename

The `latest` Lookout image renamed the config key `lookoutapiPort` → `apiPort`,
but the operator still writes `lookoutapiPort` to the secret. This causes the
Lookout to start on port 10000 (gRPC) while the liveness probe checks port 8080.

Fix: patch the operator-generated secret to use `apiPort`:
```bash
# Re-run whenever the operator reconciles and reverts the secret
PGPASS=$(kubectl get secret armada-postgres-secret -n armada \
  -o jsonpath='{.data.password}' | base64 -d)
kubectl patch secret armada-lookout -n armada --type='json' -p="[{
  \"op\":\"replace\",
  \"path\":\"/data/armada-lookout-config.yaml\",
  \"value\":\"$(cat <<EOF | base64 -w0
apiPort: 8080
postgres:
  connection:
    dbname: lookout
    host: armada-postgresql.armada.svc.cluster.local
    password: ${PGPASS}
    port: 5432
    sslmode: disable
    user: armada
uiConfig:
  armadaApiBaseUrl: http://armada-server.armada.svc.cluster.local:8080
EOF
)\"
}]"
kubectl rollout restart deployment/armada-lookout -n armada
```

### Server postgres DB: use `lookout` not `armada`

The armada-server's queue repository (`internal/server/queue`) is part of the
lookout DB schema (migrated by armada-lookout on startup). The server must
point its postgres connection at `dbname: lookout`, not a separate `armada` DB.
This is already set correctly in `armada-server.yaml`.

### Scheduler gRPC port conflict

The armada-operator v0.7.0 creates a `armada-scheduler` Service with port 50051
labeled as `grpc`. However, the scheduler binary defaults to binding its executor
API (the gRPC endpoint the executor uses) on port **50052** while its internal
API binds on 50051. To avoid needing to patch the service, we override
`grpc.port: 50051` in the scheduler config so it binds all gRPC on 50051 (matching
the service). The executor's `executorApiConnection.armadaUrl` points to port 50051.

### pulsarInit Job gets stuck (operator v0.7.0 bug)

When `pulsarInit: true` is set in the ArmadaServer CR, the operator creates a
`wait-for-pulsar` Job with empty `PULSARHOST` and `PULSARPORT=0` (operator fails
to parse the Pulsar URL). This Job loops forever and blocks the operator reconcile
loop (2-minute timeout per cycle).

Fix: use `pulsarInit: false` (already set in `armada-server.yaml`). Pulsar topics
are initialized on the server's first connection regardless.

If you see the operator reconcile timing out:
```bash
kubectl delete job wait-for-pulsar -n armada
```

### PriorityClasses required

Armada's default config requires three Kubernetes PriorityClasses:
`armada-default`, `armada-preemptible`, and `armada-resilient`. These are created
by `install.sh` but must exist before job submission. If jobs fail with
`forbidden: no PriorityClass with name armada-default was found`:
```bash
kubectl apply -f priority-classes.yaml  # created inline in install.sh
```

### Watch events: `eventsApiRedis` key (not `redis`)

`armadactl watch` relies on the server's `GetJobSetEvents` streaming RPC, which
reads from Redis. The base config (`/app/config/server/config.yaml`) defaults to
`eventsApiRedis.addrs: [redis:6379]` — the wrong hostname. Override with:

```yaml
eventsApiRedis:
  addrs:
    - armada-redis-master.armada.svc.cluster.local:6379
  password: ""
  db: 1
```

Already set in `armada-server.yaml` and the `armada-server` secret.

### Auth permissions (`permissionGroupMapping`)

Anonymous users (when `auth.anonymousAuth: true`) are automatically members of
the `"everyone"` group. Queue/job operations require explicit grants in
`auth.permissionGroupMapping` — NOT the `permissions` array format. This must
be set on both `armada-server` and `armada-scheduler` CRs.

### Duplicate Pulsar release

A failed first install attempt left a second Pulsar release (`pulsar`). The
active release is `armada-pulsar`. The duplicate can be cleaned up:
```bash
helm delete pulsar -n armada
kubectl delete pvc -n armada -l app.kubernetes.io/instance=pulsar
```

## Traefik + gRPC Notes

The Armada gRPC API requires HTTP/2. Traefik needs the `h2c` backend scheme
annotation — set in `armada-server.yaml`:

```yaml
traefik.ingress.kubernetes.io/service.serverScheme: h2c
```

## Tear Down

```bash
kubectl delete -f armada-server.yaml -f armada-scheduler.yaml \
  -f armada-scheduleringester.yaml -f armada-eventingester.yaml \
  -f armada-lookout.yaml -f armada-executor.yaml \
  -f armada-executor-deployment.yaml
helm uninstall armada-operator armada-pulsar armada-redis armada-postgresql -n armada
kubectl delete namespace armada armada-jobs
kubectl delete priorityclass armada-default armada-preemptible armada-resilient
```
