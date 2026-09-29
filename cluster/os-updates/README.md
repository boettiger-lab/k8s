# OS security updates

How the host OS under k3s stays patched. There are three layers, and each is
automated differently:

| Layer | What | How | Reboots? |
|---|---|---|---|
| k3s | kubelet, containerd, k3s itself | system-upgrade-controller, `../upgrade/plans.yml`, `stable` channel | no (k3s restarts in place) |
| OS, routine | security-pocket packages (openssl, libc, curl, sshd…) | **unattended-upgrades, nightly, this directory** | never |
| OS, held | kernel, NVIDIA driver/CUDA, ZFS | **by hand, in a maintenance window** (below) | yes |

Container images are none of these. A vLLM or Jupyter image gets its security
fixes only when it is rebuilt.

## Why nothing was patching before 2026-09-28

Both failures were silent: nothing logged an error, and no alert fired.

- **cirrus (Pop 22.04):** unattended-upgrades was enabled and ran every day, but
  the stock rule `${distro_id}:${distro_codename}-security` expands to
  `Pop:jammy-security`. Ubuntu's security archive is origin `Ubuntu`, so the
  rule matched nothing. Twelve months of apt history show it only ever
  autoremoving old kernels. 131 security updates were pending, openssl and libc6
  among them.
- **GB10s (nimbus, nimbus2–4):** the NVIDIA base image ships without
  unattended-upgrades, so nothing was ever installed automatically.
- thelio (stock Ubuntu 24.04) was the only node doing it correctly.

## GPU nodes: pass the reload test before enabling nightly runs

Any `systemctl daemon-reload`, which package upgrades trigger, strips **running** GPU containers
of their GPU (`Failed to initialize NVML: Unknown Error`) **unless the node hands GPUs over via
CDI**. The first unattended run on cirrus did exactly that. The fix is in the NVIDIA docs page
(troubleshooting): a current toolkit, `deviceListStrategy: cdi-cri`, and `/dev/char` links.

| node | status |
|---|---|
| cirrus | **passes** (2026-09-28): toolkit 1.20.1, `timeslice-cdi` |
| GB10s (nimbus, nimbus2–4) | **pass** (2026-09-28): toolkit 1.20.0, `timeslice-cdi` |

On a GPU node that has not passed, hold the nightly run until it does:

    echo 'APT::Periodic::Unattended-Upgrade "0";' | sudo tee /etc/apt/apt.conf.d/52hold-unattended-gpu

The metrics then report `node_apt_unattended_upgrades_enabled 0`, so `OsAutoUpdatesMissing`
keeps the hold visible.

## What `install-os-updates.sh` installs

**GPU nodes first:** before touching any package, it runs
`platform/nvidia/host-gpu-setup.sh`. Upgrades trigger systemd reloads, and
without that script's `/dev/char` links a reload strips every running GPU
container of its GPU. The very first run on cirrus (2026-09-28) did exactly
that. It is also why the installer needs a full repo clone, not just this
directory.

Run with sudo on each node, from a repo clone. It is idempotent, and it is the
same script for Pop and Ubuntu. `join-gb10.sh` runs it automatically on new GB10s.

    sudo cluster/os-updates/install-os-updates.sh           # install + dry run
    sudo cluster/os-updates/install-os-updates.sh --apply   # ...and apply now

1. **`51cluster-unattended-upgrades`** goes in `/etc/apt/apt.conf.d/`.
   - Allows security pockets only, matched by *origin*: Ubuntu, plus Ubuntu Pro
     ESM where it is attached.
   - Blacklists `nvidia-`, `libnvidia-`, `cuda`, the kernel packages
     (`linux-image`, `linux-modules`, `linux-headers`… but not userland such as
     `linux-libc-dev`) and the ZFS packages.
     An unattended NVIDIA userspace bump under a loaded kernel module breaks
     every new GPU pod with a driver/library mismatch.
   - Never reboots.
2. **`50-cluster.conf`** goes in `/etc/needrestart/conf.d/`. needrestart
   restarts daemons automatically after a library update; a patched openssl
   does nothing for an sshd that still maps the old one. k3s, containerd and
   nvidia services are excluded, so a package upgrade never restarts the node
   agent.
3. **`apt-metrics.sh`** runs from an hourly timer. It writes
   `/var/lib/node_exporter/textfile_collector/apt.prom` for node-exporter's
   textfile collector. It reads the blacklist from the live apt config, so it
   classifies packages exactly the way unattended-upgrades does.

## Alerts (`platform/monitoring/prometheus-values.yaml`, group `os-updates`)

| Alert | Fires when | Means |
|---|---|---|
| `OsAutoUpdatesMissing` | a node has no apt metrics, or unattended-upgrades is off | run the install script there (a new node?) |
| `OsAutoUpdatesStalled` | no unattended-upgrades run for 3 days | timer dead, or a dpkg lock / broken package |
| `OsSecurityUpdatesNotApplying` | eligible security updates pending for 3 days | the cirrus failure: it runs but installs nothing |
| `NodeRebootPending` | `/var/run/reboot-required` older than 14 days | schedule a reboot |
| `OsMaintenanceDue` (info) | held kernel/GPU/ZFS security updates pending for 7 days | a maintenance window is due |

## Why reboots are not automated

The usual tool is kured, which reboots a node when `/var/run/reboot-required`
appears. It cordons and drains the node first, and **cirrus must never be
cordoned**: it is the control plane, the storage node and the compute node at
once. On a GB10, a reboot drops a loaded model, and reloading takes minutes.
So reboots stay a human decision, and `NodeRebootPending` reminds you when one
is due. If the GB10 pool ever needs to run unattended, kured limited to those
nodes (`node-class=gb10`), one at a time and in a weekly window, would be the
next step. It would never run on cirrus.

## Maintenance window (held packages, reboots)

Do one node at a time. Do a GB10 first, as the canary for a driver bump.

**GB10 / thelio (workers):**

1. Drain the node following `../node-drain-reboot.md`. The JuiceFS teardown
   order matters there.
2. On the node: `sudo apt update && sudo apt full-upgrade`. The blacklist
   applies only to unattended-upgrades, so this brings the held packages too.
3. Reboot. Never leave an upgraded NVIDIA userspace running against the old
   kernel module.
4. Check `nvidia-smi`, confirm the device plugin advertises `nvidia.com/gpu`,
   then `kubectl uncordon <node>`.

**cirrus:** same steps 2–4, but **do not cordon or drain**. Treat it as a
planned outage of the whole cluster: announce it, then upgrade and reboot.
Pop-forked packages (kernel, NVIDIA driver, anything from `apt.pop-os.org`)
arrive only this way, because Pop's repo has no separate security pocket.
They show up as `class="other"` in the metrics.
