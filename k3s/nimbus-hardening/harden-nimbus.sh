#!/bin/bash
# harden-nimbus.sh -- make a runaway GPU pod on nimbus survivable without a
# physical power cycle. Run with sudo. Idempotent.
#
#   sudo ./harden-nimbus.sh
#
# Installs four independent layers:
#   1. GPU hang watchdog   -- detects the wedge, kills vLLM, reboots if needed
#   2. systemd hardware watchdog -- last resort if the kernel itself stops responding
#   3. k3s kubelet eviction thresholds -- keeps the scheduler honest
#   4. full magic sysrq    -- so the recovery path above can actually reboot
#   5. VM reclaim tuning   -- so kswapd reclaims early instead of deadlocking
#                             inside the driver's page fault path
#
# Swap resizing is deliberately NOT done here -- it deletes a 128 GiB file, so it
# lives in resize-swap.sh and you run it separately after reading it.

set -euo pipefail
[ "$EUID" -eq 0 ] || { echo "must run as root (use sudo)" >&2; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"

echo "==> 1/5  GPU hang watchdog"
install -m 0755 "$HERE/gpu-hang-watchdog.sh" /usr/local/bin/gpu-hang-watchdog.sh
install -m 0644 "$HERE/gpu-hang-watchdog.service" /etc/systemd/system/
install -m 0644 "$HERE/gpu-hang-watchdog.timer"   /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now gpu-hang-watchdog.timer
echo "    enabled (runs every 60s)"

echo "==> 2/5  systemd hardware watchdog"
# /dev/watchdog is a hardware timer on the GB10. If the kernel stops petting it
# for RuntimeWatchdogSec the board resets itself -- no physical access needed.
# This does NOT catch the NVIDIA-driver-only wedge (the kernel stays alive
# there); layer 1 is what covers that case. This covers a true kernel hang.
if [ -c /dev/watchdog ]; then
    mkdir -p /etc/systemd/system.conf.d
    cat > /etc/systemd/system.conf.d/10-watchdog.conf <<'CONF'
[Manager]
RuntimeWatchdogSec=60
RebootWatchdogSec=10min
CONF
    systemctl daemon-reexec
    echo "    RuntimeWatchdogSec=60 (device: $(ls /dev/watchdog))"
else
    echo "    SKIPPED: no /dev/watchdog on this host"
fi

echo "==> 3/5  k3s kubelet eviction thresholds"
if [ -f /etc/rancher/k3s/config.yaml ]; then
    cp -a /etc/rancher/k3s/config.yaml "/etc/rancher/k3s/config.yaml.bak-$STAMP"
    echo "    backed up existing config to config.yaml.bak-$STAMP"
fi
install -m 0644 "$HERE/k3s-config.yaml" /etc/rancher/k3s/config.yaml
echo "    installed. NOTE: requires 'systemctl restart k3s' to take effect."

echo "==> 4/5  full magic sysrq"
cat > /etc/sysctl.d/99-nimbus-sysrq.conf <<'CONF'
# Full sysrq so the GPU hang watchdog can force a sync+reboot when the clean
# path is blocked. Was 176 (reboot+remount-ro+sync) -- 1 additionally enables
# process signalling and task dumps, which is what makes a wedge debuggable.
kernel.sysrq = 1
CONF
sysctl -q -p /etc/sysctl.d/99-nimbus-sysrq.conf
echo "    kernel.sysrq = $(sysctl -n kernel.sysrq)"

echo "==> 5/5  VM reclaim tuning"
# The incident had no OOM kill at all: the kernel fell into *direct* reclaim
# inside the fault path while holding the NVIDIA rw-semaphore. Waking kswapd
# earlier keeps reclaim in the background where it cannot deadlock.
echo "    before: min_free_kbytes=$(sysctl -n vm.min_free_kbytes) watermark_scale_factor=$(sysctl -n vm.watermark_scale_factor) swappiness=$(sysctl -n vm.swappiness)"
install -m 0644 "$HERE/99-nimbus-vm.conf" /etc/sysctl.d/99-nimbus-vm.conf
sysctl -q -p /etc/sysctl.d/99-nimbus-vm.conf
echo "    after:  min_free_kbytes=$(sysctl -n vm.min_free_kbytes) watermark_scale_factor=$(sysctl -n vm.watermark_scale_factor) swappiness=$(sysctl -n vm.swappiness)"

echo
echo "Done. Verify with:"
echo "  systemctl list-timers gpu-hang-watchdog.timer"
echo "  journalctl -u gpu-hang-watchdog.service -f"
echo
echo "Not yet applied -- restart k3s when you are ready for the eviction thresholds:"
echo "  sudo systemctl restart k3s"
echo
echo "Separate, and destructive -- read it first, then run to drop the 128 GiB swapfile:"
echo "  sudo ./resize-swap.sh"
