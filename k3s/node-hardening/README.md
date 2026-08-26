# Node hardening — freeze detection and recovery

Host sysctls that decide what a k3s node does when it stops responding.

## Why these are files, not a DaemonSet

`juicefs/node-inotify.yaml` sets `fs.inotify.max_user_instances` via a privileged
nsenter DaemonSet, and that is the right pattern there: the CSI driver **cannot
work at all** without it, so it must land on every node unconditionally.

These are different. `hung_task_panic` **reboots the node**. Whether a given node
should reboot itself is a per-node policy call, not a cluster-wide invariant —
auto-rebooting `cirrus` takes the control plane with it. So these stay explicit
files you apply per node, deliberately.

## The two files

### `60-lockup-capture.conf` — hard lockups

Originally written by a `freeze-hardening.sh` that was never committed; recovered
here from `thelio` on 2026-08-26 so it is finally tracked. **Currently applied on
`thelio` only** — reconcile other nodes before assuming it is cluster-wide.

Catches a **hard lockup**: a CPU wedged with interrupts disabled. Converts it to a
panic so the node reboots and leaves a trace instead of hanging silently.

Note it deliberately leaves `softlockup_panic` off — it false-positives under
heavy ZFS/k3s I/O.

### `61-hung-task-panic.conf` — hung tasks

Closes the gap `60-` cannot see. The 2026-08-24 `thelio` incident was **not** a
hard lockup: `juicefs` sat blocked in uninterruptible D state past 122s, 245s and
368s while every CPU stayed perfectly healthy. `hardlockup_panic` is blind to
that, which is why the node wedged for six hours, never panicked, and had to be
power-cycled — leaving the ZFS pool dirty and breaking the next boot.

`hung_task_timeout_secs` is raised to 300 (from the 120s default) for the same
reason `60-` leaves `softlockup_panic` off: a merely slow JuiceFS metadata or
object backend must not cycle the node. A task still blocked after five minutes
is not coming back.

Also sets `kernel.sysrq = 1`, overriding the distro's 176. That already allowed
sync / remount-ro / reboot; bit 8 adds the debugging dumps, so **Alt+SysRq+W**
prints every blocked task to the console — the one command that names what is
stuck when SSH is dead and userspace is gone.

## Apply

```bash
sudo install -m 0644 60-lockup-capture.conf 61-hung-task-panic.conf /etc/sysctl.d/
sudo sysctl --system
```

Verify:

```bash
sysctl kernel.sysrq kernel.hung_task_panic kernel.hung_task_timeout_secs \
       kernel.hardlockup_panic kernel.panic
```

## A watchdog would not have helped

`systemd`'s `RuntimeWatchdogSec` (the box has an SP5100 TCO timer) is **not** a fix
for the D-state wedge. PID 1 stays healthy throughout and keeps petting the
watchdog, so it never fires. A hardware watchdog catches total kernel or PID 1
death; `hung_task_panic` is what catches "userspace is stuck but init is fine."

## Recovering a wedged node by hand

If any shell still answers, this releases every blocked process at once — no
reboot needed:

```bash
for c in /sys/fs/fuse/connections/*/abort; do echo 1 > "$c"; done
```

At the physical console, use SysRq rather than the power button. Hold **Alt** and
**SysRq** (PrtSc), then press with a few seconds between each:

```
Alt+SysRq+S   sync filesystems
Alt+SysRq+U   remount read-only
Alt+SysRq+B   reboot
```

If `S` stalls (plausible — sync may itself touch the wedged mount), skip to `U`
then `B`.

After any hard power-off, **wait several minutes at a blank screen** before
assuming the boot failed: four SMR drives replaying a dirty pool are genuinely
slow, and interrupting that is what lands you in recovery mode. Then confirm the
pool actually came back — `zfs-import-cache.service` has
`ConditionFileNotEmpty=/etc/zfs/zpool.cache` and will silently skip on an emptied
cache, leaving a healthy-looking node with no storage:

```bash
zpool status -x      # want: all pools are healthy
cat /proc/cmdline    # want: no 'recovery'
```
