---
title: "RustFS"
weight: 6
bookToc: true
---

# RustFS

Deploy RustFS for lightweight S3-compatible object storage on Kubernetes, backed by OpenEBS ZFS.

## Overview

[RustFS](https://rustfs.com/) is a high-performance, S3-compatible object storage system written in Rust. On the Nimbus cluster, it acts as an S3 gateway to a large (1TB) OpenEBS ZFS volume, providing a unified object storage interface for large datasets.

## Features

*   **S3 Compatible**: Works with standard S3 clients (boto3, minio-mc, aws-cli).
*   **High Performance**: Backed by ZFS LocalPV (Local NVMe/SSD speed).
*   **Lightweight**: Minimal resource footprint compared to distributed storage systems.
*   **Console**: built-in web-based management UI.

## Deployment

The RustFS deployment is contained in the `transport/rustfs` directory (moved to `k8s/rustfs`).

### Quick Start

We provide an interactive setup script to configure credentials and deploy:

```bash
cd rustfs
./setup-rustfs.sh
```

This script will:
1.  Ask for an Access Key (default: admin)
2.  Ask for a Secret Key (default: password)
3.  Create the `rustfs` namespace and secrets
4.  Deploy the persistent volume (1TB), deployment, and service/ingress.

### Manual Configuration

If you prefer applying manifests directly:

**1. Create Secret:**

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: rustfs-secrets
  namespace: rustfs
stringData:
  access-key: "your-access-key"
  secret-key: "your-secure-password"
```

**2. Apply Manifests:**

```bash
kubectl apply -f init.yaml      # PVC and Namespace
kubectl apply -f deployment.yaml # Application
kubectl apply -f service.yaml    # Ingress/Service
```

## Configuration

*   **Storage**: 1Ti persistent volume claim (`rustfs-data`) using `openebs-zfs`.
*   **User**: Container runs as UID `10001`.
*   **Domain**: Configured for `s3.nimbus.carlboettiger.info`.

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `RUSTFS_ACCESS_KEY` | S3 Access Key | From Secret |
| `RUSTFS_SECRET_KEY` | S3 Secret Key | From Secret |
| `RUSTFS_SERVER_DOMAINS` | API Domain | `s3.nimbus.carlboettiger.info` |
| `RUSTFS_CONSOLE_ENABLE` | Enable Web UI | `true` |

## Access

### S3 API

*   **Endpoint**: `https://s3.nimbus.carlboettiger.info`
*   **Region**: `us-east-1` (default)
*   **Signature Version**: S3v4

### Web Console

The web console runs on port `9001`. It is accessible internally within the cluster or via port-forwarding:

```bash
kubectl port-forward -n rustfs service/rustfs 9001:9001
```

Open `http://localhost:9001` in your browser.

## Integrations

### JupyterHub

To use RustFS from JupyterHub notebooks, configure your S3 client:

**Python (boto3):**

```python
import boto3
from botocore.client import Config

s3 = boto3.client('s3',
    endpoint_url='https://s3.nimbus.carlboettiger.info',
    aws_access_key_id='your-access-key',
    aws_secret_access_key='your-secret-key',
    config=Config(signature_version='s3v4')
)
```

**R (aws.s3):**

```r
Sys.setenv(
    "AWS_S3_ENDPOINT" = "s3.nimbus.carlboettiger.info",
    "AWS_ACCESS_KEY_ID" = "your-access-key",
    "AWS_SECRET_ACCESS_KEY" = "your-secret-key",
    "AWS_HTTPS" = "TRUE"
)
library(aws.s3)
bucketlist()
```
