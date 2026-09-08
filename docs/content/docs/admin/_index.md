---
title: "Administration"
weight: 3
bookCollapseSection: false
---

# Administration

Documentation for cluster administration and management tasks.

This section covers administrative tasks and tools for managing the Kubernetes cluster:

## Administration Guides

- [**Access Model & User Accounts**](users) - Who can reach what, and namespace-scoped RBAC tooling
- [**Secrets Management**](secrets) - Manage sensitive configuration data
- [**Custom Images**](custom-images) - The notebook, GPU and openvscode images
- [**OAuth Apps**](oauth-apps) - GitHub OAuth applications behind JupyterHub login
- [**Tips & Tricks**](tips-tricks) - Useful commands and solutions to common problems

## Common Administrative Tasks

### User Management

Lab members use the hosted services (JupyterHub, MinIO, vLLM) and have neither SSH nor
`kubectl` access; the administrator is the only cluster user. Namespace-scoped
ServiceAccount + kubeconfig tooling exists in `platform/users/` for the occasional
walled-off collaborator, but is not issued to lab members.

### Resource Monitoring

Monitoring resource usage across nodes and pods:

```bash
kubectl top nodes
kubectl top pods --all-namespaces
```

### Troubleshooting

Common troubleshooting commands and solutions for cluster issues.

### Backup and Recovery

Strategies for backing up cluster state and user data.

## Best Practices

1. **Security**: Implement least-privilege access control
2. **Monitoring**: Set up regular monitoring and alerting
3. **Backup**: Maintain regular backups of critical data
4. **Documentation**: Keep configuration changes documented
5. **Updates**: Plan and test cluster upgrades
6. **Resource Management**: Set appropriate resource quotas and limits

## Quick Links

- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [K3s Documentation](https://docs.k3s.io/)
- [kubectl Cheat Sheet](https://kubernetes.io/docs/reference/kubectl/cheatsheet/)
