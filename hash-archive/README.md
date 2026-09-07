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

## Image provenance — a known weak point

`cboettig/hash-archive:latest` exists **only in cirrus's local Docker daemon**.
It was built roughly six years ago and never pushed anywhere. k3s uses its own
containerd and cannot see Docker's image store, so `cirrus/import-image.sh`
bridges the gap with `docker save | k3s ctr images import -`.

That is deliberately a **bridge, not the end state**. The image is
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
# 1. Make the image visible to k3s (root: talks to Docker and containerd)
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

The original store is still at `/minio/hash-archive/hash-archive.db` — **keep
that path until the k8s deployment is confirmed working**, even while the rest
of `/minio` is reclaimed.

## DNS / TLS

`hash-archive.carlboettiger.info` already exists as a **Cloudflare-proxied**
record. The ingress therefore sets
`external-dns.alpha.kubernetes.io/cloudflare-proxied: "true"` — unlike
`titiler`, which uses `"false"` — so external-dns does not flip the record to
DNS-only and change how the host is exposed. cert-manager's HTTP-01 challenge
works through the Cloudflare proxy, minting into `hash-archive-tls`.
