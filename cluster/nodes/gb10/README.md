# GB10 fleet nodes

Shared config and runbook for **any GB10 box joining the cirrus cluster as an
agent** — today `nimbus2`, `nimbus3`, `nimbus4` (Dell Pro Max with GB10).

`../nimbus/` stays as it is. nimbus is the same silicon but a different vendor
(NVIDIA DGX Spark) and, more importantly, a different *history*: it was a live
single-node control plane that had to be demoted, so its directory carries a
teardown runbook that has no analogue here. Everything in this directory is
greenfield.

## What is shared and what is not

| | where |
|---|---|
| kubelet eviction thresholds, taint, label, `server:` | `k3s-agent-config.yaml` (one template) |
| `node-ip` | the **only** per-host value; rendered by `join-gb10.sh` |
| GPU hang watchdog | `gpu-hang-watchdog.{sh,service,timer}` |
| VM reclaim tuning | `99-gb10-vm.conf` |
| everything above, installed | `harden-gb10.sh` |

One template rather than three per-host files: three copies of the same 60 lines
of rationale drift, and the drift is invisible until a node registers wrong.
`join-gb10.sh` derives `node-ip` from the interface actually carrying the
`128.32.85.0/24` address — deliberately not `hostname -I`, which would happily
hand back `docker0`'s `172.17.0.1`.

## Why the hardening applies to the whole fleet

The incident it defends against (nimbus, 2026-08-24) was an NVIDIA driver
rw-semaphore deadlock under unified-memory pressure: the kernel stayed alive, so
no OOM kill fired and the hardware watchdog had nothing to notice, and the box
needed a physical power cycle. That is a property of **GB10 silicon with a
unified memory pool**, not of the DGX Spark chassis. The full writeup is in
`../nimbus/README.md`; it is not duplicated here.

What does *not* carry over is anything vendor-specific — NVIDIA firmware tooling,
DGX-branded packages (`nvidia-dgx-telemetry` exists on nimbus and not on the
Dells), chassis and serial layout, support channel.

### Swap

`../nimbus/resize-swap.sh` has **no counterpart here**. It removed a 128 GiB
`/swapfile128` that the DGX Spark shipped with, alongside the ordinary 16 GiB
`/swap.img`; 143 GiB of swap on a 121 GiB box made the OOM killer effectively
unreachable, so the kernel thrashed instead of reaping the runaway. The Dell Pro
Max boxes ship with only the 16 GiB `/swap.img`, which is the size we want.

`harden-gb10.sh` still checks — it refuses to run if total swap exceeds 32 GiB,
because that is the 2026-08-24 configuration and layer 5 assumes it is gone.

## Order of operations

1. **SSH first.** Key-based login, then `cluster-ops/reference/harden-ssh-gb10.sh`
   to turn off password auth. Hostname must already be the `nimbusN` name — the
   join refuses to run on a box still answering to a factory `promaxgb10-*` name.
2. **`apt full-upgrade` and reboot, BEFORE joining.** An unjoined box is the only
   free canary you have for a GPU driver bump; once it is a cluster member that
   is gone. It also means the k3s agent installs against the driver you will
   actually be running.
3. On the box: `sudo -E CIRRUS_K3S_VERSION=… K3S_TOKEN=… ./join-gb10.sh`
4. On cirrus: `./post-join-gb10.sh nimbusN`

`join-gb10.sh` installs `/etc/rancher/k3s/config.yaml` **before** the agent first
starts, so the node is tainted at registration and never spends a moment
schedulable. On an arm64 node most of cirrus's amd64 images would
`CrashLoopBackOff` with an exec-format error rather than fail cleanly, so that
window matters.

## Watch out

- **The auto-upgrade plan must tolerate `dedicated=gb10`.** A `NoSchedule` taint
  the plan does not tolerate means the node is silently never upgraded — no
  error, no event. This has already bitten thelio, and bit nimbus for real: the
  2026-09-13 retaint from `dedicated=nimbus` to `dedicated=gb10` dropped it out
  of a plan whose tolerations were never updated. `post-join-gb10.sh` checks.
  `rancher/k3s-upgrade` is a multi-arch image (amd64/arm64/arm-v7), so arm64 is
  not and has never been the obstacle here.
- **The fleet is a collective compute resource** (ruling of 2026-09-13). Schedule
  with `nodeSelector: {node-class: gb10}`; reserve `kubernetes.io/hostname` for
  cases with a real per-box reason, such as a model tied to one box's local
  weight cache. Each such pin is a place the fleet stops behaving like a pool.
- **These nodes hold no cluster data** — no JuiceFS, no RustFS, no ZFS-LocalPV,
  regardless of workload. Nothing storage-related may tolerate this taint. The
  `juicefs-csi-node` DaemonSet briefly did (live helm rev 4) and landed on
  nimbus; reverted in rev 6.
- **Wired only.** `join-gb10.sh` sets any Wi-Fi device down and unmanaged. A
  second interface is how a node registers an unroutable address and flannel
  silently blackholes cross-node traffic; `disconnected` is not sufficient,
  because NetworkManager can still bring it up later.
