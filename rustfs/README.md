# RustFS Deployment

Deploy RustFS (S3-compatible object storage) on Kubernetes with OpenEBS ZFS storage.

## Components

*   **Namespace**: `rustfs`
*   **Storage**: 1Ti PVC using `openebs-zfs` storage class so data resides on the ZFS pool.
*   **Access**:
    *   S3 API exposed via Ingress at `s3.nimbus.carlboettiger.info`
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
    *   Edit `init.yaml` to set your desired credentials in the Secret.
    *   `kubectl apply -f init.yaml`
    *   `kubectl apply -f deployment.yaml`
    *   `kubectl apply -f service.yaml`

## Configuration

*   **Environment Variables**: Defined in `deployment.yaml`, referencing `rustfs-secrets`.
*   **Domain**: Default is `s3.nimbus.carlboettiger.info`. Edit `service.yaml` ingress rules and `deployment.yaml` (`RUSTFS_SERVER_DOMAINS`) to change.

## Verification

```bash
kubectl get pods -n rustfs
kubectl get ingress -n rustfs
```

Access the S3 API at `https://s3.nimbus.carlboettiger.info`.
The console is available internally on port 9001 (not exposed by default ingress, you may need to port-forward or add a rule).
