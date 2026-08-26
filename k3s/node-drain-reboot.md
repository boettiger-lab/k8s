# Draining and rebooting a worker node

Rebooting a k3s worker that has JuiceFS (FUSE) volumes mounted will **hang
indefinitely at shutdown** if you just run `sudo reboot`. The symptom is a
console stuck on a `Waiting for ...juicefs...` job that never times out,
which leaves a hard power cycle as the only way out — and a hard power cycle
on a node with an active FUSE mount can leave stale mountpoints and stranded
CSI cleanup jobs behind.

This is the ordered procedure that avoids that.

## Why it hangs

The JuiceFS CSI driver runs in **mount-pod mode** (`juicefs-csi-node`
DaemonSet in `kube-system`, no `--by-process` flag). Each volume is served by
a separate mount pod, also in `kube-system`, which holds the FUSE connection
backing `/var/lib/juicefs/volume/...` and the kubelet bind-mounts under
`/var/lib/kubelet/pods/*/volumes/kubernetes.io~csi/*/mount`.

At shutdown, systemd stops containerd (killing the mount pods) and then tries
to unmount the filesystems. Once the FUSE server process is gone, nothing is
left to answer the kernel, so `umount` blocks in uninterruptible sleep and
systemd waits on it forever.

The fix is to make Kubernetes tear the mounts down **in order**, while the
mount pods are still alive, before touching the OS.

## Procedure

Run these from a machine with cluster admin (cirrus, or your laptop with the
remote kubeconfig). Substitute the node name for `<node>`.

### 1. Cordon and drain

```bash
kubectl cordon <node>

kubectl drain <node> \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --timeout=10m
```

`--ignore-daemonsets` is required: DaemonSet pods (`juicefs-csi-node`,
device plugin, node exporters, `svclb-*`) are not evicted by drain and will
be handled in the next step.

> **Never cordon or drain `cirrus`.** It is simultaneously the control plane,
> the storage node, and the compute node — cordoning it strands every
> workload in the cluster. This is why both system-upgrade plans in
> `upgrade/plans.yml` pin `cordon: false`. This procedure is for *worker*
> nodes only.

### 2. Confirm the JuiceFS mounts are actually gone

Drain evicts the workload pods, which releases the volumes, which lets the
CSI driver reap the mount pods. That last step is asynchronous — wait for it
rather than assuming it.

```bash
# No mount pods left for this node (should return nothing):
kubectl get pods -n kube-system -o wide | grep juicefs | grep <node>

# And on the node itself, no FUSE mounts left (should return nothing):
ssh <node> 'mount | grep -i juicefs'
```

Do not proceed until both are empty. If mount pods linger, find what is still
holding the volume:

```bash
kubectl get pods -A -o wide --field-selector spec.nodeName=<node>
```

### 3. Stop the k3s agent

```bash
ssh <node> 'sudo systemctl stop k3s-agent'
```

Stopping the agent cleanly — rather than letting the shutdown sequence race
it — ensures containerd shuts down with no volumes still attached.

### 4. Reboot

```bash
ssh <node> 'sudo systemctl reboot'
```

### 5. Uncordon after it returns

```bash
kubectl get nodes -w        # wait for <node> to report Ready
kubectl uncordon <node>
```

## If it hangs anyway

If the console is already stuck on a JuiceFS job, a hard power cycle is the
only remaining option — but clean up afterwards, because the CSI volume
deletion jobs that were mid-flight on that node become permanently stranded.

Symptoms of the aftermath:

```bash
# Deletion jobs stuck Terminating on the dead node:
kubectl get pods -n kube-system | grep delvol

# Volumes stuck Released instead of being reclaimed:
kubectl get pv | grep -v Bound
```

Those `Released` PVs still occupy space in the object store — the delete
never ran. Clean-up options, in order of preference:

1. **Bring the node back.** Once it is `Ready`, the stranded pods are
   reconciled and the deletions finish on their own. Always try this first.
2. **Delete the node object** if it is not coming back
   (`kubectl delete node <node>`). This releases the stranded pods, and the
   controller reschedules the outstanding deletion jobs onto a live node.
3. Only if neither applies, force-delete the pods
   (`kubectl delete pod -n kube-system <pod> --force`). This orphans the
   underlying data in the object store, which then has to be reclaimed
   manually.

## Scope note

Node-local storage does **not** follow the node. ZFS-LocalPV volumes
(`openebs-zfs`) are pinned to the node that holds the pool, so a drained node
cannot have its ZFS-backed workloads rescheduled elsewhere — they stay
`Pending` until the node returns. Only RWX `juicefs-sc` volumes are portable
between nodes. Check what a node is actually carrying before planning
downtime:

```bash
kubectl get pvc -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,SC:.spec.storageClassName
```

## When a node dies unexpectedly (recovering jupyter servers)

The procedure above is for a *planned* reboot. If thelio dies on its own, the
jupyter servers that were running on it need one manual step before they can
come back on cirrus.

Why: a pod on an unreachable node is marked for deletion after the eviction
timeout, but the API object stays `Terminating` for as long as the node is
gone -- the kubelet that would confirm the deletion is not there to do it.
JupyterHub names user pods deterministically (`jupyter-<user>`), so that stuck
pod occupies the name its own replacement needs, and the user's spawn fails.

Kubernetes' Non-Graceful Node Shutdown handles this. Once you are **certain the
node is really down** (not merely unreachable -- see the warning below), taint
it:

```bash
kubectl taint nodes <node> node.kubernetes.io/out-of-service=nodeshutdown:NoExecute
```

The pods are then force-deleted and their volumes released, and users can
spawn again immediately -- landing on cirrus, since it is the only node left.
Remove the taint before the node rejoins:

```bash
kubectl taint nodes <node> node.kubernetes.io/out-of-service=nodeshutdown:NoExecute-
```

> **Only apply this taint to a node you have confirmed is off.** It tells
> Kubernetes to skip the safety handshake and assume nothing is still writing.
> If the node is actually alive but merely partitioned from the API server,
> two pods can end up writing the same home directory at once.

### What survives, and what does not

Homes on `juicefs-home` survive a node loss: the data lives in rustfs, not on
the node, and that class deliberately omits `writeback` so no writes are
staged on local disk awaiting upload (see `../juicefs/storageclass.yaml`).
A server lost with thelio restarts on cirrus with its home intact.

Homes on `openebs-zfs` do **not** move. Those volumes are node-local to
cirrus's tank, which pins their pods to cirrus -- they were never at risk from
a thelio failure, and equally cannot be rescued from a cirrus one. The 21
pre-existing homes are in this category; only claims created after the switch
to `juicefs-home` are node-mobile.

Anything held only in the notebook's memory is lost either way. This protects
saved files, not unsaved state.
