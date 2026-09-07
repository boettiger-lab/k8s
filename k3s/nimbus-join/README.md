# Joining nimbus to the cirrus cluster

nimbus (DGX Spark, GB10, arm64) stops being its own single-node k3s cluster and
becomes a **tainted worker** in the cirrus cluster. It runs only specially
sanctioned work — today the vLLM endpoint, the GPU MCP data server, and GPU
telemetry. Everything else on the cluster continues to ignore it.

This is the same move made for thelio in `06d24ab`, with one difference that
shapes every decision below: **nimbus is arm64 and cirrus is amd64.** A mixed
architecture cluster is fine, but only as long as nothing schedules onto nimbus
by accident. That is what the taint is for.

## Why a taint and not just a nodeSelector

A `nodeSelector` pins a pod *to* a node. It does nothing to stop other pods from
landing there. With ~25 system pods, JupyterHub spawns, CI runners and Armada
jobs all free-floating on the cluster, an untainted nimbus would start
collecting workloads within minutes of joining — and most of cirrus's images are
amd64-only, so they would `CrashLoopBackOff` with an exec-format error rather
than fail cleanly.

So nimbus registers with:

```
node-taint: dedicated=nimbus:NoSchedule
```

set in `/etc/rancher/k3s/config.yaml` **before the agent first starts**, so the
node is never schedulable for even a moment. Sanctioned workloads then say so
twice — a toleration to get past the taint, and a `nodeSelector` to actually
land there:

```yaml
nodeSelector:
  kubernetes.io/hostname: nimbus
tolerations:
- key: dedicated
  operator: Equal
  value: nimbus
  effect: NoSchedule
```

## What is destroyed, what survives

`k3s-uninstall.sh` deletes `/var/lib/rancher/k3s` — the entire datastore. Every
object in nimbus's cluster stops existing.

**Destroyed, and fine:** cert-manager, external-dns, Traefik, JupyterHub, RustFS
(the PVC held 276 KiB — it was never used), the local Prometheus (~950 MiB of
history), and all the `*-nimbus` TLS secrets. Cirrus already runs every one of
these, which is the whole point of merging.

**Destroyed, and recovered by this runbook:**

| thing | how it comes back |
|---|---|
| `mcp-gpu-nimbus` Deployment/Service/Ingress | committed to `mcp/nimbus/` — it had never been in git |
| `nimbus-carbon-api` | archived to `monitoring/nimbus-carbon-api.yaml`, deliberately **not** redeployed (see below) |
| `ngc-pull`, `huggingface-token`, `vllm-api-key`, `ghcr-pull` | `01-backup-nimbus.sh` dumps them; `03-post-join.sh` restores them |
| the vLLM endpoint | `vllm/nimbus/endpoint.yaml` + `up.sh`, now in namespace `vllm` |

**Untouched by any of this:** `/home/cboettig/.cache/huggingface` (the 22 GiB
model cache — a hostPath, not a volume), the GPU hang watchdog and the rest of
`../nimbus-hardening/`, and the `openebs-zpool` ZFS pool.

### The carbon API

`carbon-nimbus.carlboettiger.info` is retired rather than migrated. One
per-node carbon API per machine was the right shape for two separate clusters;
for one cluster the replacement is a single cluster-wide API that breaks power
down per node. The nimbus source is archived in `monitoring/` so nothing is
lost when that gets built.

### The leftover ZFS pool

`openebs-zpool` (1.94 TiB, 995 MiB used) becomes orphaned — all cluster storage
lives on cirrus (`tank`, JuiceFS, RustFS), and nothing storage-related tolerates
the nimbus taint on purpose. The pool is left intact rather than destroyed;
reclaim it deliberately later if you want the space:

```bash
zfs list                      # four orphaned pvc-* datasets, no PV objects left
sudo zpool destroy openebs-zpool
```

## Before you start

### Access: nimbus cannot reach cirrus, and xps14 reaches nimbus only via cirrus

Three facts about this network shape, none of them obvious, all of them load
bearing:

- **nimbus has no SSH key.** No private key, no agent socket. Port 22 to cirrus
  is open, so this is purely credentials. Any instruction of the form
  `ssh cirrus` *run on nimbus* will fail.
- **The key is resident on the laptop (xps14)**, which can reach both machines.
- **xps14 reaches nimbus only through cirrus** (`ssh -J cirrus nimbus`), because
  of the campus firewall.

So xps14 ferries exactly two things to nimbus — a kubeconfig and the node-token
— and everything else runs on nimbus. Set the jump host once, on xps14, and the
commands below work as written:

```
Host nimbus
    HostName 128.32.85.239
    User cboettig
    ProxyJump cirrus
```

Note what that makes cirrus: the jump host, the control plane, **and** (via the
pinned Traefik) the ingress for nimbus's endpoints. If cirrus is down you cannot
reach nimbus at all. Prefer to run this with physical access to the Spark
available, not purely remotely.

### Step 0, on xps14

```bash
# The version that gates everything. cirrus runs v1.36.4+k3s1.
ssh cirrus 'k3s --version | head -1'

# Ferry the kubeconfig to nimbus, rewritten to the LAN address.
ssh cirrus 'sudo cat /etc/rancher/k3s/k3s.yaml' \
  | sed 's|127.0.0.1|128.32.85.8|' \
  | ssh nimbus 'install -m600 /dev/stdin ~/.kube/cirrus-config'

# The node-token. Keep it on screen -- it is passed by hand in step 3 rather
# than written to nimbus's disk.
ssh cirrus 'sudo cat /var/lib/rancher/k3s/server/node-token'
```

**On the version.** A k3s agent must not be *newer* than its server — outside
Kubernetes' supported skew, and nothing will stop you. Today the skew runs the
safe way: cirrus is `v1.36.4+k3s1`, nimbus `v1.34.5+k3s1`, so nimbus is behind.
`02-join.sh` installs whatever `CIRRUS_K3S_VERSION` says, so nimbus lands on the
server's exact version. The 1.34 → 1.36 jump needs no care here because this is
not an in-place upgrade: the datastore is destroyed and the agent is a fresh
install. **Re-read cirrus's version at the time you run this** rather than
trusting the number above.

### Two kubeconfigs on one box

After step 0 nimbus holds both `~/.kube/config` (its own cluster, dies in step
3) and `~/.kube/cirrus-config`. Which one is active decides which cluster each
step talks to:

| step | cluster | kubeconfig |
|---|---|---|
| 1 backup | nimbus's own | default |
| 2 prepare | cirrus | `export KUBECONFIG=~/.kube/cirrus-config` |
| 3 join | none (local) | — |
| 4 post-join | cirrus | `export KUBECONFIG=~/.kube/cirrus-config` |
| 5 vLLM | cirrus | `export KUBECONFIG=~/.kube/cirrus-config` |

`01-backup-nimbus.sh` and `03-post-join.sh` both refuse to run against the wrong
cluster. So does `nvidia/nvidia-device-plugin.sh`. Once step 3 is done, replace
the dead default with the cirrus one:

```bash
cp ~/.kube/cirrus-config ~/.kube/config
```

Also confirm from nimbus that the control plane is reachable **directly** — the
LAN address, never `cirrus.carlboettiger.info`, which is orange-clouded and
resolves into Cloudflare, which does not carry 6443:

```bash
getent hosts cirrus.local        # expect 128.32.85.8, same /24 as nimbus
nc -vz 128.32.85.8 6443
```

## The steps

Steps 1, 2, 4 and 5 run on nimbus. Only step 3 needs the token from xps14.

```bash
cd k3s/nimbus-join

# 1. Capture everything that exists only in nimbus's cluster.
#    Writes to secrets/nimbus-join-backup/ (git-ignored). Check its output.
unset KUBECONFIG
./01-backup-nimbus.sh
grep -c . ../../secrets/nimbus-join-backup/secret-*.yaml   # four, all non-zero

# 2. Prepare the cirrus side FIRST, while nimbus is still separate.
#    These add the nimbus toleration to the DaemonSets that are allowed on it.
#    With no nimbus node in the cluster yet, both are no-ops -- which is exactly
#    why it is safe to do them before the destructive step.
export KUBECONFIG=~/.kube/cirrus-config
cd ../../nvidia && bash nvidia-device-plugin.sh
cd ../monitoring
helm repo add gpu-helm-charts https://nvidia.github.io/dcgm-exporter/helm-charts
helm upgrade -i dcgm-exporter gpu-helm-charts/dcgm-exporter \
      -n monitoring --version 4.8.2 --wait --values dcgm-exporter-values.yaml

#    Confirm thelio did not regress -- it is tainted too, and both charts above
#    carry its toleration in the same list as nimbus's.
kubectl get pods -n nvidia-device-plugin -o wide
```

Step 3 is irreversible, and its middle section is a `curl | sh` installer plus a
two-minute registration wait. A dropped SSH there leaves nimbus with its cluster
destroyed and the agent half-installed, so run it under tmux — from xps14:

```bash
ssh -t nimbus 'tmux new -As join'
```

```bash
# 3. The destructive step, inside that tmux. Paste the node-token at the
#    prompt: `read -rs` keeps it out of the terminal and out of shell history,
#    and `sudo -E` is what carries it into the script.
read -rs K3S_TOKEN && export K3S_TOKEN
unset KUBECONFIG
cd ~/Documents/github/boettiger-lab/k8s/k3s/nimbus-join
sudo -E CIRRUS_K3S_VERSION=v1.36.4+k3s1 ./02-join.sh
```

If the link drops, reconnect and `tmux a -t join`; the script keeps running.

```bash
# 4. The cirrus side.
export KUBECONFIG=~/.kube/cirrus-config
./03-post-join.sh

# 5. vLLM last, once the GPU is actually being advertised.
cd ../../vllm/nimbus && NIMBUS_KEY='<api key>' ./up.sh
```

## Verifying

```bash
kubectl get nodes -o wide                    # nimbus Ready, arm64, cirrus's version
kubectl get node nimbus -o jsonpath='{.spec.taints}'
kubectl get node nimbus -o jsonpath='{.status.allocatable.nvidia\.com/gpu}'  # 8

# The important one: nothing unexpected has landed on nimbus.
kubectl get pods -A -o wide --field-selector spec.nodeName=nimbus
```

That last list should contain only tolerating DaemonSets (device plugin,
node-feature-discovery, gpu-feature-discovery, dcgm-exporter) plus the
sanctioned workloads. Anything else — especially anything in
`CrashLoopBackOff` — is the arm64/amd64 mismatch, and means something got past
the taint.

Then the endpoints, which take a few minutes (external-dns polls at 1m, then
cert-manager has to solve HTTP-01 through Traefik on cirrus):

```bash
dig +short vllm-nimbus.carlboettiger.info    # should now be cirrus's IP, not .239
curl -s https://vllm-nimbus.carlboettiger.info/v1/models -H "Authorization: Bearer $NIMBUS_KEY"
curl -s https://gpu-mcp-nimbus.carlboettiger.info/healthz
```

## Things that will bite

**The DNS records move.** Traefik is pinned to cirrus (see
`docs/.../node-placement.md`), so `vllm-nimbus` and `gpu-mcp-nimbus` now resolve
to cirrus's IP and hairpin over the LAN to nimbus. Negligible for token
streaming, but it does make cirrus a hard dependency for nimbus's endpoints.
external-dns runs `--policy=upsert-only` with the default TXT owner ID on both
clusters, so cirrus's copy owns and updates the existing records cleanly.

**No kubeconfig on nimbus.** An agent has no `/etc/rancher/k3s/k3s.yaml`, so
after the join `kubectl` on nimbus talks to nothing until it uses the cirrus
kubeconfig ferried in at step 0. Note the direction: nimbus cannot `scp` from
cirrus, it has no key. Copy the file into place as the default:

```bash
cp ~/.kube/cirrus-config ~/.kube/config
```

The GPU hang watchdog does **not** care -- it is entirely host-level (`nvidia-smi`,
`/proc`, `pkill`) and never calls kubectl. It keeps working through the join
untouched, which is deliberate: the wedge it recovers from is exactly the
situation where the control plane is unreachable.

**The auto-upgrade plan does not reach tainted nodes.** `../upgrade/plans.yml`
selects every non-control-plane node for `agent-plan`, and
system-upgrade-controller places its upgrade Job *on* the target node -- so a
`NoSchedule` taint blocks it unless the Plan tolerates it. Both tainted nodes
now carry tolerations there. Without them nimbus would join at the server's
version and then silently never upgrade again while cirrus advances on the
stable channel: the same version-skew hazard this runbook guards against at join
time, arriving later by a different door. After the join, confirm nimbus is
actually being upgraded rather than merely quiet:

```bash
kubectl get nodes -o wide            # versions should converge over time
kubectl -n system-upgrade get jobs   # a job should appear for nimbus on a bump
```

**Flannel needs 8472/udp.** If it is blocked between the two hosts, nimbus joins,
goes `Ready`, and then every cross-node connection hangs — including Traefik
reaching the vLLM pod. `02-join.sh` warns if ufw is active. Between them the
pair needs 6443/tcp, 8472/udp and 10250/tcp.

**`systemctl stop k3s` does not stop pods.** The unit ships `KillMode=process`,
so containerd-shims survive as orphans, still holding GPU memory. `02-join.sh`
runs `k3s-killall.sh` first for this reason. See `../nimbus-hardening/README.md`.

**Two k3s configs now.** `../nimbus-hardening/` carries both
`k3s-config.yaml` (server) and `k3s-agent-config.yaml` (agent). They are not
interchangeable — `write-kubeconfig-mode` is server-only and `k3s agent` refuses
to start on an unknown flag. `harden-nimbus.sh` picks by which systemd unit
exists, so it stays correct on both sides of the join.

## Rolling back

There is no undo. Reverting means rebuilding nimbus as a standalone server:
`k3s-uninstall.sh`, then `install-reset-K3s.sh`, then re-running the service
installs from the repo root in the order the top-level README gives. The
backup from step 1 has the secrets. Everything else was already redundant with
cirrus, which is why this is a low-stakes migration despite being irreversible.

One caveat on that word "low-stakes": it assumes you can still reach nimbus.
xps14 gets there only by jumping through cirrus, so a rollback needs cirrus up
-- or console access to the Spark. Rolling back is not something you can count
on doing purely remotely.
