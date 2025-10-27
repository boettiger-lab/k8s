## Jupyterhub setup

Overall [z2jh](https://z2jh.jupyter.org/en/stable/) docs are very good, follow those directions.  

k3s system should be configured first, see k3s

## Network Policy Configuration

JupyterHub is configured with network policies that enable user pods to access external services including MinIO and other cluster services via hairpin connections.

### Hairpin Access to MinIO

The `public-config.yaml` configuration includes network policies that allow JupyterHub user pods to:

- Access `minio.carlboettiger.info` (external domain) via hairpin connections
- Connect to MinIO services in the `minio` namespace
- Access other private IP ranges for cluster services
- Maintain DNS resolution capabilities

This configuration is applied automatically during Helm deployment and replaces the previous manual `enable-external-access.sh` script.

### Configuration Details

The network policy settings in `public-config.yaml` under `singleuser.networkPolicy`:

```yaml
singleuser:
  networkPolicy:
    enabled: true
    egressAllowRules:
      privateIPs: true                    # Access to private IP ranges
      dnsPortsPrivateIPs: true           # DNS resolution to private IPs
      dnsPortsKubeSystemNamespace: true  # DNS via kube-system
      nonPrivateIPs: true                # External internet access (hairpin)
    egress:
      # Specific access to minio.carlboettiger.info external IP
      - to:
          - ipBlock:
              cidr: 128.32.85.8/32
      # Access to MinIO namespace services
      - to:
          - namespaceSelector:
              matchLabels:
                name: minio
```

### Environment Variables

User pods automatically receive environment variables for MinIO access:
- `AWS_S3_ENDPOINT: "minio.carlboettiger.info"`
- `AWS_HTTPS: "true"`
- `AWS_VIRTUAL_HOSTING: "FALSE"`

### Deployment

Deploy with the standard script:

```bash
./cirrus.sh
```

Network policies are applied automatically - no additional manual steps required.

