#!/bin/bash

# Enable external service access for JupyterHub singleuser pods
# This patch allows Jupyter pods to access external services via hairpin mode
# and connect to services in other namespaces (like MinIO and Traefik)

echo "Patching JupyterHub network policy to enable external service access..."

kubectl patch networkpolicy singleuser -n jupyter --type='merge' -p='{
  "spec": {
    "egress": [
      {
        "ports": [{"port": 8081, "protocol": "TCP"}],
        "to": [{"podSelector": {"matchLabels": {"app": "jupyterhub", "component": "hub", "release": "juypterhelm"}}}]
      },
      {
        "ports": [{"port": 8000, "protocol": "TCP"}],
        "to": [{"podSelector": {"matchLabels": {"app": "jupyterhub", "component": "proxy", "release": "juypterhelm"}}}]
      },
      {
        "ports": [{"port": 8080, "protocol": "TCP"}, {"port": 8443, "protocol": "TCP"}],
        "to": [{"podSelector": {"matchLabels": {"app": "jupyterhub", "component": "autohttps", "release": "juypterhelm"}}}]
      },
      {
        "ports": [{"port": 53, "protocol": "UDP"}, {"port": 53, "protocol": "TCP"}],
        "to": [
          {"ipBlock": {"cidr": "169.254.169.254/32"}},
          {"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "kube-system"}}},
          {"ipBlock": {"cidr": "10.0.0.0/8"}},
          {"ipBlock": {"cidr": "172.16.0.0/12"}},
          {"ipBlock": {"cidr": "192.168.0.0/16"}}
        ]
      },
      {
        "to": [{"ipBlock": {"cidr": "0.0.0.0/0", "except": ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.169.254/32"]}}]
      },
      {
        "to": [{"ipBlock": {"cidr": "128.32.85.8/32"}}]
      },
      {
        "to": [{"namespaceSelector": {"matchLabels": {"name": "minio"}}}]
      },
      {
        "to": [{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "kube-system"}}}]
      }
    ]
  }
}'

if [ $? -eq 0 ]; then
    echo "✅ Network policy successfully updated!"
    echo "Jupyter pods can now access:"
    echo "  - External services via hairpin mode (e.g., minio.carlboettiger.info)"
    echo "  - MinIO namespace services"
    echo "  - Traefik and other kube-system services"
    echo "  - Internet destinations (excluding private ranges)"
else
    echo "❌ Failed to update network policy"
    exit 1
fi
