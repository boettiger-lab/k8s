---
title: "Object storage"
weight: 3
---

# Object storage

The cluster runs an S3-compatible object store.

| | |
|---|---|
| S3 endpoint | `https://minio.carlboettiger.info` |
| Public read access | `https://data.carlboettiger.info/<bucket>/<key>` for buckets that allow anonymous read |
| Addressing | path-style (`endpoint/bucket/key`), not virtual-host style |
| Credentials | from a cluster admin |

## Clients

**AWS CLI / boto3**

```bash
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
aws s3 ls --endpoint-url https://minio.carlboettiger.info s3://my-bucket/
```

```python
import boto3
s3 = boto3.client("s3", endpoint_url="https://minio.carlboettiger.info")
```

**MinIO client**

```bash
mc alias set lab https://minio.carlboettiger.info "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY"
mc ls lab/my-bucket
```

**DuckDB**

```sql
CREATE SECRET lab (TYPE s3, KEY_ID '...', SECRET '...',
                   ENDPOINT 'minio.carlboettiger.info', URL_STYLE 'path');
SELECT * FROM read_parquet('s3://my-bucket/file.parquet');
```

**R (arrow)**

```r
bucket <- arrow::s3_bucket("my-bucket", endpoint_override = "https://minio.carlboettiger.info")
```

Your JupyterHub home directory is separate from this store; see
[JupyterHub]({{< relref "jupyterhub" >}}).
