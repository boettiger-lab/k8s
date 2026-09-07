# TiTiler

Dynamic tile server for Cloud-Optimized GeoTIFFs. Clients pass a COG URL as a
query parameter and TiTiler renders XYZ tiles from it on the fly with ranged
GETs — no pre-rendering, no state.

| | NRP Nautilus | cirrus (here) |
|---|---|---|
| Manifests | [boettiger-lab/nautilus/titiler](https://github.com/boettiger-lab/nautilus/tree/main/titiler) | `cirrus/` |
| URL | https://titiler.nrp-nautilus.io | https://titiler.carlboettiger.info |
| Namespace | `espm-157` | `titiler` |
| Replicas | 3 | 2 |
| Requests | 6 CPU / 24Gi | 500m / 1Gi |
| Limits | 12 CPU / 40Gi | 4 CPU / 8Gi |
| Workers | 4 | 2 |
| Ingress | HAProxy annotations | Traefik CRDs + cert-manager + external-dns |

The cirrus copy is deliberately small in its **requests**: memory requests on the
cirrus node are already ~84% committed (shared with vllm, duckdb-mcp, gpu-mcp and
JupyterHub), so a 24Gi request simply would not schedule. Burst headroom lives in
the limits instead. `GDAL_CACHEMAX` drops to 512 MB/worker to match.

## Deploy

```bash
cd cirrus && ./up.sh
```

## Usage

```bash
# Metadata for a COG
curl 'https://titiler.carlboettiger.info/cog/info?url=<COG_URL>'

# XYZ tile template
curl 'https://titiler.carlboettiger.info/cog/WebMercatorQuad/tilejson.json?url=<COG_URL>'
```

Note that TiTiler fetches the COG from whatever URL the *client* supplies, so a
COG on the in-cluster MinIO is still fetched over its public
`minio.carlboettiger.info` address (hairpinning out through Traefik and back).

## Consumers

- [`bosl-high-seas`](https://github.com/boettiger-lab/bosl-high-seas) —
  `layers-input.cirrus.json` sets `titiler_url` to the cirrus instance.
