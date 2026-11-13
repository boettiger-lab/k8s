---
title: "Object storage"
weight: 3
---

# Object storage

The cluster runs an S3-compatible object store ([RustFS](https://rustfs.com/)).

| | |
|---|---|
| S3 endpoint | `https://s3.carlboettiger.info` |
| Older endpoint | `https://minio.carlboettiger.info` still works: same store, same keys |
| Public read access | `https://s3.carlboettiger.info/<bucket>/<key>` for buckets that allow anonymous read |
| Web console | `https://data.carlboettiger.info` (log in with your S3 credentials) |
| Addressing | path-style (`endpoint/bucket/key`), not virtual-host style |
| Credentials | from a cluster admin |

Existing scripts and published links that use `minio.carlboettiger.info` keep
working. Use `s3.carlboettiger.info` in anything new.

## Clients

**AWS CLI / boto3**

```bash
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
aws s3 ls --endpoint-url https://s3.carlboettiger.info s3://my-bucket/
```

```python
import boto3
s3 = boto3.client("s3", endpoint_url="https://s3.carlboettiger.info")
```

**MinIO client (`mc`)** works unchanged:

```bash
mc alias set lab https://s3.carlboettiger.info "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY"
mc ls lab/my-bucket
```

**DuckDB**

```sql
CREATE SECRET lab (TYPE s3, KEY_ID '...', SECRET '...',
                   ENDPOINT 's3.carlboettiger.info', URL_STYLE 'path');
SELECT * FROM read_parquet('s3://my-bucket/file.parquet');
```

**R (arrow)**

```r
bucket <- arrow::s3_bucket("my-bucket", endpoint_override = "https://s3.carlboettiger.info")
```

Your JupyterHub home directory is separate from this store; see
[JupyterHub]({{< relref "jupyterhub" >}}).
