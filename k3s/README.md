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

## Node Maintenance

Rebooting a worker node that has JuiceFS volumes mounted will hang at
shutdown unless you drain it first. See
[`node-drain-reboot.md`](node-drain-reboot.md) for the ordered drain,
verify, stop-agent, reboot procedure — and for cleaning up the stranded
CSI deletion jobs left behind by a hard power cycle.

Note that `cirrus` must never be cordoned or drained: it is the control
plane, the storage node, and the compute node at once. **This is exactly why
`juicefs/node-shutdown-cleanup.yaml` must be deployed cluster-wide:** with
draining unavailable on cirrus, that DaemonSet is the only thing standing
between a stalled JuiceFS mount and a control plane that will not power down.

### Node hardening — where things live

Hardening is **per-node**, because the failure modes are hardware-specific. Do
not copy one node's config onto another.

| Path | Node | Guards against |
|---|---|---|
| [`node-drain-reboot.md`](node-drain-reboot.md) | any JuiceFS node | the ordered drain/reboot procedure, and cleaning up stranded CSI deletion jobs |
| [`thelio-hardening/`](thelio-hardening/) | **thelio** (amd64, consumer board, non-ECC, RTX 2080) | freeze *detection* — `hung_task_panic` and full SysRq, so a wedge reboots itself and can be diagnosed from the console |
| [`nimbus-hardening/`](nimbus-hardening/) | **nimbus** (DGX Spark GB10, unified memory) | a runaway GPU pod exhausting the *shared* RAM pool — vLLM budgeting, swap sizing, and the GPU hang watchdog |

**These are three different failures. Do not conflate them:**

- **nimbus** — a *runtime* GPU driver deadlock. Under unified-memory pressure
  `VLLM::EngineCore` took the NVIDIA driver's rw-semaphore and never released
  it; every NVML consumer piled up behind it. GB10-specific, because there is
  no discrete VRAM to isolate the GPU's allocation from the host's.
- **thelio's JuiceFS wedge** — a *runtime* filesystem hang. A stalled FUSE
  mount (metadata/object backend unreachable) blocks anything that stats the
  path, and then strands `systemd-shutdown`. Not GPU-related. See
  [`../juicefs/README.md`](../juicefs/README.md) gotcha 3.
- **thelio's boot hang (2026-08-24 → 08-28)** — self-inflicted configuration,
  not hardware. A `memmap=`/ramoops GRUB drop-in installed to *capture* freezes
  was itself preventing every standard boot. Recorded in the private
  `cluster-ops` journal; the GPU was exonerated.

**The one thing they share** is worth internalising: each was a **D-state
pile-up with the kernel still alive** — no panic, no OOM kill, so a hardware
watchdog has nothing to notice and nothing recovers on its own. That is why
both hardening dirs reach for `hung_task_panic` and userspace watchdogs rather
than relying on the board's watchdog. It is a shared *class* of failure, not a
shared cause.
