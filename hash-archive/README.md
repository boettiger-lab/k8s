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

## ⚠️ The historical hash database is NOT loaded — [#52](https://github.com/boettiger-lab/k8s/issues/52)

**Status 2026-09-07: the service runs on a FRESH, EMPTY store.** The original
LevelDB — ~624 KB, data through 2025-10 — is archived to S3:

```
nvme/hash-archive/hash-archive-db-20260907.tar.gz
sha256 57dfa607bd18fa00e950524ead28ecddb24ce71a0145db40b08cd48569123cd1
```

⚠️ It must **not** live in `backup-archive` — that bucket carries an enabled
**90-day expiry lifecycle rule** (no prefix filter) and exists only as scratch
for the NRP sync backup system, where sync deletions are expected. Anything
placed there is deleted silently. This object needs a bucket with no lifecycle
policy; `nvme/hash-archive` has none.

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
mc cp nvme/hash-archive/hash-archive-db-20260907.tar.gz .
tar xzf hash-archive-db-20260907.tar.gz
```

## Local patches

Upstream is unmaintained (last commit 2021-10-31), so fixes are carried as
patches in [`patches/`](patches/), applied in order during the build. Each
carries its rationale in the header.

- **`0001-url-parse-accept-collapsed-scheme-separator.patch`** — hash-archive
  puts the target URL *inside* the request path
  (`/history/https://example.com/x`). Traefik sanitizes request paths by
  default (`entryPoint http.sanitizePath`), collapsing `//` → `/`, so the app
  received `https:/example.com/x`, failed to parse it, and returned **HTTP 400**
  for every lookup — breaking the web form, the `/history/` route and scripted
  clients such as the R package [`contentid`](https://github.com/cboettig/contentid).
  The patch makes `url_parse()` retry with a single slash **only when the
  two-slash form already failed**, so no URL that parses today changes meaning.

  Percent-encoding is not an alternative: `url_parse()` does no percent
  decoding, so `https:%2F%2Fexample.com` fails identically. Disabling
  `sanitizePath` was rejected because it is an **entryPoint-wide** setting that
  would remove path hardening from every service on 443.

## Image

Built and published by
[`.github/workflows/hash-archive-image.yml`](../.github/workflows/hash-archive-image.yml):
multi-arch (amd64 + arm64) to `ghcr.io/boettiger-lab/hash-archive`, on changes
to `Dockerfile` or `patches/`, weekly, or on manual dispatch with a chosen
upstream ref. **The package is public**, so k3s pulls it with no
`imagePullSecret`.

This replaced a 2020-era image (Ubuntu 16.04, 663 MB) that existed only in
cirrus's local Docker daemon and had never been pushed anywhere — a single
`docker system prune -a` would have destroyed the only copy. That image and its
container have since been removed; this one is reproducible from source.

## Deploy

Run in order, from
`/home/cboettig/Documents/boettiger-lab/k8s/hash-archive/cirrus`:

The ghcr package is **public** and `imagePullPolicy: Always`, so k3s pulls the
CI-built image directly — no side-loading and no imagePullSecret.

```sh
./up.sh                 # private (no ingress)
PUBLIC=1 ./up.sh        # token-gated public ingress
```

To pick up a new CI build: `kubectl -n hash-archive rollout restart deploy/hash-archive`.

To test a local build before pushing, side-load it:
`docker save <image> | sudo k3s ctr images import -`

Verify:

```sh
kubectl -n hash-archive get pods,svc,ingress
kubectl -n hash-archive logs deploy/hash-archive
curl -sI https://hash-archive.carlboettiger.info/     # expect 200, not 404
```

## Rollback

`down.sh` retains the PVC, so the store survives a teardown. The pre-migration
Docker container and its 2020 image have been removed — the modern image is
reproducible from this directory and the historical store is archived in S3
(see above), so neither was worth keeping.

## DNS / TLS

`hash-archive.carlboettiger.info` already exists as a **Cloudflare-proxied**
record. The ingress therefore sets
`external-dns.alpha.kubernetes.io/cloudflare-proxied: "true"` — unlike
`titiler`, which uses `"false"` — so external-dns does not flip the record to
DNS-only and change how the host is exposed. cert-manager's HTTP-01 challenge
works through the Cloudflare proxy, minting into `hash-archive-tls`.
