---
title: "RustFS"
weight: 6
bookToc: true
---

# RustFS

S3-compatible object storage on **cirrus**, backed by the `tank` ZFS pool
through OpenEBS ZFS-LocalPV.

## Overview

[RustFS](https://rustfs.com/) is a high-performance, S3-compatible object store
written in Rust. Its job here is to be the durable object backend for
[JuiceFS](../../infrastructure/shared-home-storage/) — the `juicefs-homes`
bucket, which holds user home directories — and a general S3 target for large
datasets.

> **There is no longer a nimbus deployment.** RustFS ran on
> `s3.nimbus.carlboettiger.info` while nimbus was its own cluster; that was
> retired when nimbus joined cirrus as a compute-only worker
> ([`k3s/nimbus-join/`](https://github.com/boettiger-lab/k8s/tree/main/k3s/nimbus-join)).
> Its PVC held 276 KiB and nothing was migrated. Everything below is cirrus.

## Deployment

One manifest, `rustfs/cirrus.yaml`, holding the Namespace, PVC, Deployment,
Service and console Ingress. The interactive script prompts for credentials,
creates the `rustfs-secrets` Secret and applies it:

```bash
cd rustfs
./setup-rustfs.sh
```

Or, with the Secret already in place:

```bash
kubectl apply -f rustfs/cirrus.yaml
```

## Configuration

*   **Storage**: 4Ti PVC (`rustfs-data`) on `openebs-zfs`, i.e. cirrus's `tank`.
    The class is thin/sparse, so 4Ti is a ceiling, not a reservation.
*   **Placement**: pinned to cirrus with a `kubernetes.io/hostname` nodeSelector —
    a ZFS-LocalPV volume is node-local, so the pod cannot move anyway.
*   **User**: container runs as UID `10001`.

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `RUSTFS_ACCESS_KEY` | S3 access key | From `rustfs-secrets` |
| `RUSTFS_SECRET_KEY` | S3 secret key | From `rustfs-secrets` |
| `RUSTFS_CONSOLE_ENABLE` | Enable web UI | `true` |

`RUSTFS_SERVER_DOMAINS` is **deliberately unset**. Setting it makes RustFS parse
the bucket out of the `Host` header (virtual-hosted style), which breaks
path-style access — and both JuiceFS and `mc` use path-style, so in-cluster
requests start failing with `InvalidBucketName`.

## Access

### S3 API — in-cluster only

The API is **not** exposed through an Ingress. Clients reach it inside the
cluster at `http://rustfs.rustfs.svc:9000`, which keeps the JuiceFS data path
off Traefik and off TLS entirely.

```python
import boto3
from botocore.client import Config

s3 = boto3.client('s3',
    endpoint_url='http://rustfs.rustfs.svc:9000',
    aws_access_key_id='your-access-key',
    aws_secret_access_key='your-secret-key',
    config=Config(signature_version='s3v4'),
)
```

```r
Sys.setenv(
    "AWS_S3_ENDPOINT" = "rustfs.rustfs.svc:9000",
    "AWS_ACCESS_KEY_ID" = "your-access-key",
    "AWS_SECRET_ACCESS_KEY" = "your-secret-key",
    "AWS_HTTPS" = "FALSE"
)
library(aws.s3)
bucketlist()
```

From outside the cluster, port-forward instead:

```bash
kubectl port-forward -n rustfs service/rustfs 9000:9000
```

### Web console

Exposed at `https://rustfs.cirrus.carlboettiger.info` (port 9001). That Ingress
is optional and exists only for browsing — the JuiceFS data path does not use
it. It can be removed without affecting storage.

## Verification

```bash
kubectl get pods -n rustfs
kubectl get pvc -n rustfs
kubectl get ingress -n rustfs
```
