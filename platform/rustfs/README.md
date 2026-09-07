# RustFS Deployment

Deploy RustFS (S3-compatible object storage) on Kubernetes with OpenEBS ZFS storage.

> Everything here targets **cirrus** (`cirrus.yaml`, pool `tank`). The old nimbus
> deployment at `s3.nimbus.carlboettiger.info` was retired when nimbus joined the
> cirrus cluster as a compute-only worker — see [`../../cluster/nodes/nimbus/join/`](../../cluster/nodes/nimbus/join/).
> Its 1 Ti PVC held 276 KiB; nothing was migrated.

## Components

*   **Namespace**: `rustfs`
*   **Storage**: 1Ti PVC using `openebs-zfs` storage class so data resides on the ZFS pool.
*   **Access**:
    *   S3 API exposed via Ingress (see `cirrus.yaml`)
    *   Service: `rustfs` (port 9000 API, 9001 Console)
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
*   **Domain**: Edit the Ingress rules and `RUSTFS_SERVER_DOMAINS` in `cirrus.yaml` to change.

## Verification

```bash
kubectl get pods -n rustfs
kubectl get ingress -n rustfs
```

Access the S3 API at the hostname configured in `cirrus.yaml`.
The console is available internally on port 9001 (not exposed by default ingress, you may need to port-forward or add a rule).
