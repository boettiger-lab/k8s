# RustFS Deployment

Deploy RustFS (S3-compatible object storage) on Kubernetes with OpenEBS ZFS storage.

> Everything here targets **cirrus** (`cirrus.yaml`, pool `tank`). The old nimbus
> deployment at `s3.nimbus.carlboettiger.info` was retired when nimbus joined the
> cirrus cluster as a compute-only worker — see [`../../cluster/nodes/nimbus/join/`](../../cluster/nodes/nimbus/join/).
> Its 1 Ti PVC held 276 KiB; nothing was migrated.

## Components

*   **Namespace**: `rustfs`
*   **Purpose**: the object backend for JuiceFS homes (bucket `juicefs-homes`); see
    [`../juicefs/`](../juicefs/). Infrastructure, not a user-facing S3 service.
*   **Storage**: 4Ti PVC on `openebs-zfs` (cirrus `tank`). The class is thin, so the
    size is a ceiling, not a reservation. ZFS is the redundancy layer; RustFS runs
    single-node without erasure coding.
*   **Access**:
    *   S3 API: **in-cluster only**, `http://rustfs.rustfs.svc:9000`, path-style. No
        Ingress, so the JuiceFS data path never touches Traefik or TLS.
    *   Console: `https://rustfs.cirrus.carlboettiger.info` (port 9001), for browsing
        only; removing that Ingress does not affect storage.
*   **Security**: Runs as non-root user `10001` (fsGroup handled by storage class/deployment).

## Deployment

1.  Run the setup script:
    ```bash
    chmod +x setup-rustfs.sh
    ./setup-rustfs.sh
    ```
    This will prompt you to set the S3 Access Key and Secret Key.

2.  Or apply manually:
    *   Create the `rustfs-secrets` Secret (see `../juicefs/credentials.example.yaml`).
    *   `kubectl apply -f cirrus.yaml`

## Configuration

*   **Environment Variables**: Defined in `cirrus.yaml`, referencing `rustfs-secrets`.
*   **`RUSTFS_SERVER_DOMAINS` must stay unset.** It switches RustFS to
    virtual-hosted-style bucket parsing from the `Host` header, which breaks the
    path-style access JuiceFS and `mc` use (`InvalidBucketName`).

## Verification

```bash
kubectl get pods -n rustfs
kubectl get ingress -n rustfs
```

From outside the cluster, reach the S3 API with
`kubectl port-forward -n rustfs service/rustfs 9000:9000`.
