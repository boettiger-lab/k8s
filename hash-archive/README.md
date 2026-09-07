# hash-archive

[hash-archive](https://github.com/btrask/hash-archive) on the cirrus k3s
cluster, served at **https://hash-archive.carlboettiger.info**.

Manifests: [`cirrus/`](cirrus/).

## Why this exists

hash-archive ran for years as a **plain Docker container** on cirrus — host
networking on port 8000, restart policy `always`, bind-mounting its LevelDB from
`/minio/hash-archive/hash-archive.db`. It was the **last remaining consumer of
`/minio`**, the pre-k3s MinIO-era tree (~1.3 TB of retired user homes) that is
being reclaimed from cirrus's worn root drive. Migrating it here frees that
tree and puts the service under the same GitOps, TLS and DNS machinery as
everything else.

It also **restores a dead endpoint**: before this deployment,
`https://hash-archive.carlboettiger.info` returned Traefik's 404. The DNS record
existed and reached cirrus, but nothing claimed the host — the Docker container
was only ever reachable on `localhost:8000`.

## Two things about this app that will bite you

**1. It compiles at container start.** The image ships the source tree and the
command is:

```sh
sed -i "s/hash-archive.org/$URL/" src/config.h && make install && exec /usr/local/bin/hash-archive
```

So the root filesystem must stay writable (no `readOnlyRootFilesystem`), and
first start takes minutes. A `startupProbe` with `failureThreshold: 30` at a
10 s period allows up to 5 minutes before the pod is declared failed.

**2. It returns HTTP 403 unless the `Host` header matches `$URL`.** A plain
`curl http://127.0.0.1:8000/` gets `403 Forbidden`; with
`-H "Host: hash-archive.carlboettiger.info"` it returns 200. Kubelet probes
address the pod by IP, so **every probe sets the Host header explicitly**.
Without that the pod would never become ready and the deployment would look
broken for no visible reason.

## Storage

The store is **LevelDB** (`000*.ldb`, `CURRENT`, `MANIFEST-*`, `LOCK`) —
~624 KB, with real data through 2025-10.

- It lives on PVC `hash-archive-data`, `openebs-zfs` → cirrus `tank`, so it now
  gets ZFS checksums, snapshots and mirror redundancy the hostPath never had.
- **LevelDB is single-writer.** Hence `replicas: 1` and `strategy: Recreate` —
  a RollingUpdate would briefly run two pods against one PVC and risk
  corrupting the store.

## Security posture — read this before exposing it further

**Upstream's last commit is 2021-10-31.** This is unmaintained C network code
that, by design, fetches arbitrary URLs supplied by anonymous users. Treat it as
hostile-input-facing software with no vendor patching it.

| Concern | Status |
|---|---|
| **Vendored TLS is frozen.** LibreSSL is statically linked into the binary from a 2021 submodule pin. The app makes outbound HTTPS to attacker-chosen hosts, so it parses hostile TLS with a ~5-year-old stack. **Base-image updates cannot fix this** — it is compiled in. | ⚠️ unmitigated |
| **SSRF is the feature.** Anyone can make it fetch any URL. Inside a cluster that means the Kubernetes API, MinIO, RustFS, Postgres, the kubelet and link-local metadata. | ✅ mitigated by [`cirrus/networkpolicy.yaml`](cirrus/networkpolicy.yaml) — egress denied to 10/8, 172.16/12, 192.168/16, 169.254/16, 127/8 |
| **Ran as root** in the old image. | ✅ now uid 10001, `allowPrivilegeEscalation: false`, all capabilities dropped, `seccompProfile: RuntimeDefault` |
| **Full build toolchain shipped** in the runtime image (663 MB). | ✅ multi-stage, 90 MB runtime |
| **Frozen CA bundle** (libressl's vendored `cert.pem` from 2021). | ✅ symlinked to the distro's maintained bundle |
| **`-Werror` stripped to build.** The warnings it was suppressing included `-Wimplicit-fallthrough` in `deps/libasync` — a genuine bug class, in code we do not maintain. | ⚠️ accepted; warnings still print |
| **Custom HTTP parser**, no CVE process, no upstream security contact. | ⚠️ inherent |

`readOnlyRootFilesystem` is deliberately **not** set: `config.h` hardcodes
`CONFIG_IMPORT_SOCKET_PATH "./import.sock"`, so the working directory must stay
writable.

### Decision 2026-09-07: private by default

**The ingress is not applied unless `PUBLIC=1`.** The NetworkPolicy contains
*where* the service can reach; it does nothing about *who can drive it*. Since
the vendored 2021 TLS stack is exercised on every outbound fetch, limiting who
can trigger a fetch is the only available control over that exposure — and it
also closes the inbound custom-HTTP-parser surface.

The cost is nil: the public URL was returning Traefik 404 before this migration
anyway, so there is no user base to disrupt, and the accumulated hash database
is unaffected either way.

**Reach it privately:**

```sh
kubectl -n hash-archive port-forward svc/hash-archive 8000:8000
curl -H 'Host: hash-archive.carlboettiger.info' http://127.0.0.1:8000/
```

The `Host` header is mandatory — without it the app returns 403, so a browser
pointed at `http://localhost:8000/` will *not* work. For browser access either
add `127.0.0.1 hash-archive.carlboettiger.info` to `/etc/hosts` (note the app
may still reject the `:8000` port suffix in the Host header), or re-publish with
a Traefik IP-allowlist middleware in front of `ingress.yaml`.

**To publish again — token-gated:** `PUBLIC=1 ./up.sh`. The public ingress
carries a Traefik BasicAuth middleware
([`cirrus/auth-middleware.yaml`](cirrus/auth-middleware.yaml)), so authenticated
services can reach it while anonymous callers cannot drive its URL fetching.
`up.sh` refuses to publish if the credentials secret is absent, so an open
ingress cannot be created by accident. Setup and rotation:
[`../secrets/hash-archive-credentials.md`](../secrets/hash-archive-credentials.md).

Callers authenticate with `curl -u user:pass` or an `Authorization: Basic …`
header. The header is **not** forwarded upstream (`removeHeader: true`) — the
2021-vintage HTTP parser has no use for it.

## ⚠️ Known fault: periodic SIGABRT — [#51](https://github.com/boettiger-lab/k8s/issues/51)

The pod aborts with **exit 134 (SIGABRT) roughly every ~49 minutes** and is
restarted by kubelet in about a second. It serves correctly between aborts, so
impact is a brief outage per cycle rather than an outage outright — but do not
put anything latency- or availability-critical behind it until this is
understood. Ruled out so far: the migrated store, the storage backend, the
NetworkPolicy, the securityContext, and OOM. Details and next steps in the issue.

**Note for anyone debugging:** the interval is ~49 minutes, so a 60-second
smoke test will look healthy. Observe for hours.

## ⚠️ The historical hash database is NOT loaded

**Status 2026-09-07: the service runs on a FRESH, EMPTY store.** The original
LevelDB — ~624 KB, data through 2025-10 — is archived to S3:

```
nvme/backup-archive/hash-archive/hash-archive-db-20260907.tar.gz
sha256 57dfa607bd18fa00e950524ead28ecddb24ce71a0145db40b08cd48569123cd1
```

Upload was verified by round-trip checksum, so `/minio` is free to delete.

Every attempt to run against the migrated copy ends in `SIGABRT` (exit 134)
seconds after the server logs `Hash Archive running`, with no assertion text.
Both the new image and the 2020 image fail on it (the old one with `SIGSEGV`),
while an empty store runs cleanly for both. So the fault travels with the data,
not the binary and not the storage backend.

What was ruled out, in order: the NetworkPolicy (removed, still aborts); the
securityContext — `cap-drop ALL`, numeric uid 10001, seccomp — (all reproduce
fine under plain Docker); and the storage backend (an empty store runs on the
same ZFS-backed PVC). A partial copy of the store — `*.ldb`, `CURRENT`,
`MANIFEST-*`, `LOG` only — *did* serve correctly under Docker, which suggests
the fault is in one of the files that copy omitted (`LOCK`, the `*.log`
write-ahead file, or `tmp.mdb-lock`) or in copy consistency, but that was not
run to ground.

**To recover the history**, options in rough order of promise:
1. Copy in only `000209.ldb`, `000211.ldb`, `CURRENT` and `MANIFEST-*` —
   omitting `LOCK`, `*.log` and `tmp.mdb-lock` — which is the combination
   observed to work under Docker.
2. Use the repo's own import path (`cli/`, `tools/`,
   `CONFIG_IMPORT_SOCKET_PATH`) to replay the old data into a fresh store.
3. Open the store with a standalone LevelDB tool to check for corruption.

None of this is urgent — the service works, and the store is preserved in S3.
Retrieve it with:

```sh
mc cp nvme/backup-archive/hash-archive/hash-archive-db-20260907.tar.gz .
tar xzf hash-archive-db-20260907.tar.gz
```

## Image provenance — a known weak point

`cboettig/hash-archive:latest` exists **only in cirrus's local Docker daemon**.
It was built roughly six years ago and never pushed anywhere. k3s uses its own
containerd and cannot see Docker's image store, so `cirrus/import-image.sh`
bridges the gap with `docker save | k3s ctr images import -`.

**CI now builds this**: [`.github/workflows/hash-archive-image.yml`](../.github/workflows/hash-archive-image.yml)
publishes multi-arch (amd64 + arm64) to `ghcr.io/boettiger-lab/hash-archive`
on Dockerfile changes, weekly, or on manual dispatch with a chosen upstream ref.
Once that has run, flip `imagePullPolicy` to `Always` and drop the side-load.

The side-load remains a **bridge, not the end state**. The image is
unreproducible: if cirrus's Docker store is ever pruned — and pruning it is on
the ops backlog — the only copy is gone. **Do not run `docker rmi` or
`docker system prune -a` until this is resolved.** The proper fix is a CI build
from [btrask/hash-archive](https://github.com/btrask/hash-archive) pushed to
`ghcr.io/boettiger-lab/hash-archive`, after which the deployment just changes
its `image:` line. Tracked as a follow-up.

## Deploy

Run in order, from
`/home/cboettig/Documents/boettiger-lab/k8s/hash-archive/cirrus`:

```sh
# 1. Make the image visible to k3s (root: talks to Docker and containerd).
#    Skip once CI has published to ghcr and imagePullPolicy is Always.
sudo ./import-image.sh

# 2. Stop the Docker container, copy the LevelDB into the PVC
#    (stops it for a consistent copy; does NOT delete it)
sudo ./migrate-store.sh

# 3. Deploy
./up.sh
```

Verify:

```sh
kubectl -n hash-archive get pods,svc,ingress
kubectl -n hash-archive logs deploy/hash-archive
curl -sI https://hash-archive.carlboettiger.info/     # expect 200, not 404
```

## Rollback

`migrate-store.sh` stops the Docker container but never removes it, and
`down.sh` retains the PVC. To go back:

```sh
./down.sh
docker start hash-archive
```

The original store is archived in S3 (see above); `/minio` no longer needs to
be preserved.

## DNS / TLS

`hash-archive.carlboettiger.info` already exists as a **Cloudflare-proxied**
record. The ingress therefore sets
`external-dns.alpha.kubernetes.io/cloudflare-proxied: "true"` — unlike
`titiler`, which uses `"false"` — so external-dns does not flip the record to
DNS-only and change how the host is exposed. cert-manager's HTTP-01 challenge
works through the Cloudflare proxy, minting into `hash-archive-tls`.
