---
title: "K3s Installation & Configuration"
weight: 1
bookToc: true
---

# K3s Installation & Configuration

[K3s](https://docs.k3s.io/installation) is a lightweight, certified Kubernetes distribution designed for resource-constrained environments and edge computing. It's the best way to provide a self-hosted Kubernetes environment for a single node or small cluster.

## Overview

K3s is a fully compliant Kubernetes distribution with the following features:
- Lightweight (single binary < 100MB)
- Batteries-included (includes Traefik ingress, CoreDNS, etc.)
- Easy to install and maintain
- Perfect for on-premise GPU workstations

## Installation

### Install K3s

The default installation uses K3s's built-in Traefik ingress controller and works with cert-manager for HTTPS:

```bash
# Install K3s (inspect the script before running!)
curl -sfL https://get.k3s.io | sh
```

This command will:
- Download and install K3s
- Set up K3s as a systemd service
- Configure the kubeconfig at `/etc/rancher/k3s/k3s.yaml`
- Start the K3s server

### Configure kubectl Access

Set up the default config in a location you can write to and that will be recognized by helm:

```bash
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $USER:$USER ~/.kube/config
```

### Verify Installation

```bash
# Check K3s service status
sudo systemctl status k3s

# Verify nodes are ready
kubectl get nodes

# Check system pods
kubectl get pods -A
```

### Enable GPU Support (Optional)

If you have NVIDIA GPUs and want to enable GPU support with time-slicing:

```bash
# From the repository root
bash nvidia/nvidia-device-plugin.sh
```

See the [NVIDIA GPU Support]({{< relref "nvidia" >}}) documentation for more details.

### Helm

Helm is already included with K3s, so no separate installation is needed.

```bash
# Verify helm is available
helm version
```

## Remote kubectl Access

To access the K3s cluster from a remote machine using kubectl:

### Quick Setup

```bash
# On the k3s server, run:
./configure-remote-access.sh

# Or specify the server IP/hostname explicitly:
./configure-remote-access.sh your-server.example.com
```

This generates `k3s-remote-kubeconfig.yaml` with the correct server address.

### Transfer to Remote Machine

```bash
# Copy the kubeconfig to your remote machine
scp k3s-remote-kubeconfig.yaml user@remote-machine:~/.kube/config

# Or copy to a specific location and use with KUBECONFIG env var
scp k3s-remote-kubeconfig.yaml user@remote-machine:~/k3s-config
export KUBECONFIG=~/k3s-config
```

### Firewall Configuration

Ensure port `6443` is accessible on the K3s server:

```bash
# For UFW (Ubuntu/Debian)
sudo ufw allow 6443/tcp

# For firewalld (RHEL/CentOS)
sudo firewall-cmd --permanent --add-port=6443/tcp
sudo firewall-cmd --reload

# Verify the port is listening
sudo ss -tlnp | grep 6443
```

### DNS and Proxy Considerations

- Your kubeconfig's server must resolve directly to your node's IP address
- If you're using a CDN/proxy (e.g., Cloudflare orange-cloud), port 6443 will not be reachable and kubectl will time out
- Verify resolution points to your node:

```bash
getent hosts nimbus.carlboettiger.info
# The output should show your server's IP(s), not Cloudflare ranges
```

**Solution**: If using Cloudflare, set the DNS record for the API hostname to "DNS only" (grey cloud) so it points directly to your node. Alternatively, use the node's IP in the kubeconfig.

## Security Considerations

### API Server Access

The K3s API server (port 6443) should be protected:
- Use firewall rules to restrict access to trusted IPs
- Consider using a VPN for remote access
- Rotate ServiceAccount tokens regularly

### Kubeconfig Files

- Store kubeconfig files securely
- Set appropriate file permissions (e.g., `chmod 600 ~/.kube/config`)
- Don't commit kubeconfig files to version control
- Use short-lived tokens when possible

## Configuration Files

K3s configuration files are located at:
- `/etc/rancher/k3s/k3s.yaml` - Admin kubeconfig
- `/etc/rancher/k3s/config.yaml` - K3s server configuration (optional)
- `/var/lib/rancher/k3s/` - K3s data directory

## Common Operations

### Restart K3s

```bash
sudo systemctl restart k3s
```

### Stop K3s

```bash
sudo systemctl stop k3s
```

### View K3s Logs

```bash
sudo journalctl -u k3s -f
```

### Uninstall K3s

```bash
# Be careful! This removes everything
/usr/local/bin/k3s-uninstall.sh
```

## Next Steps

After installing K3s, you'll want to set up:

1. [NVIDIA GPU Support]({{< relref "nvidia" >}}) - If using GPUs
2. [OpenEBS Storage]({{< relref "openebs" >}}) - For persistent storage with quotas
3. [Cert-Manager]({{< relref "cert-manager" >}}) - For automatic SSL/TLS certificates
4. [External DNS]({{< relref "external-dns" >}}) - For automatic DNS management

## Related Documentation

- [Official K3s Documentation](https://docs.k3s.io/)
- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [Helm Documentation](https://helm.sh/docs/)
