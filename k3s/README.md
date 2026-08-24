# k3s Setup

[k3s](https://docs.k3s.io/installation) is easily the best way to provide a self-hosted k8s environment (for a single node or small cluster).  Lightweight, batteries-included.

Default deployment works well.  A few additional steps to configure nvidia, etc.

## Installation

### Install K3s

The default installation uses K3s's built-in Traefik ingress controller and works with cert-manager for HTTPS:

```bash
# Install K3s (inspect the script before running!)
curl -sfL https://get.k3s.io | sh
```


### Configure kubectl Access

Set up the default config in a location you can write to and that will be recognized by helm:

```bash
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $USER:$USER ~/.kube/config
```

### Enable GPU Support (Optional)

If you have NVIDIA GPUs and want to enable GPU support with time-slicing:

```bash
# From the repository root
bash nvidia/nvidia-device-plugin.sh
```

See the `../nvidia/` directory for more details on GPU configuration.

### Helm

Helm is already included with k3s, so no separate installation is needed.

## Remote kubectl Access

To access the k3s cluster from a remote machine using kubectl:

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

Ensure port `6443` is accessible on the k3s server:

```bash
# For UFW (Ubuntu/Debian)
sudo ufw allow 6443/tcp

# For firewalld (RHEL/CentOS)
sudo firewall-cmd --permanent --add-port=6443/tcp
sudo firewall-cmd --reload

# Verify the port is listening
sudo ss -tlnp | grep 6443
```

### DNS and proxy considerations

- Your kubeconfig's server must resolve directly to your node's IP address. If you're using a CDN/proxy (e.g., Cloudflare orange-cloud), 6443 will not be reachable and kubectl will time out.
- Verify resolution points to your node:

```bash
getent hosts nimbus.carlboettiger.info
# The output should show your server's IP(s), not Cloudflare ranges like 104.16.0.0/12 or 2606:4700::/32
```

- If using Cloudflare, set the DNS record for the API hostname to "DNS only" (grey cloud) so it points directly to your node.
- Alternatively, use the node's IP in the kubeconfig (see `configure-remote-access.sh`).

### Security Considerations

- The generated kubeconfig contains **admin credentials** with full cluster access
- Consider creating namespace-scoped users instead (see `../users/README.md`)
- Keep the kubeconfig file secure and transfer it safely
- Rotate credentials periodically
- Use network-level security (VPN, firewall rules) to restrict access

### Manual Configuration

If you prefer to manually edit the kubeconfig:

```bash
# Copy the admin kubeconfig
cp /etc/rancher/k3s/k3s.yaml ~/k3s-remote-kubeconfig.yaml

# Edit and replace 127.0.0.1 with your server's IP or hostname
sed -i 's/127.0.0.1/YOUR_SERVER_IP/g' ~/k3s-remote-kubeconfig.yaml
```
