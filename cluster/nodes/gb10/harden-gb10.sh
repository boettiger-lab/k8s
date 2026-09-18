#!/bin/bash
# harden-gb10.sh -- make a runaway GPU pod on a GB10 node survivable without a
# physical power cycle. Run with sudo, ON the node. Idempotent.
#
#   sudo ./harden-gb10.sh
#
# Generalised from ../nimbus/harden-nimbus.sh. The incident it defends against
# (nimbus, 2026-08-24: NVIDIA driver rw-semaphore deadlock under unified-memory
# pressure, kernel alive throughout so no OOM kill and no hardware watchdog) is
# a property of the GB10 silicon, not of the DGX Spark chassis -- so every box
# in the fleet gets the same treatment.
#
# Installs five independent layers:
#   1. GPU hang watchdog          -- detects the wedge, kills vLLM, reboots if needed
#   2. systemd hardware watchdog  -- last resort if the kernel itself stops responding
#   3. k3s kubelet eviction thresholds -- keeps the scheduler honest
#   4. full magic sysrq           -- so the recovery path above can actually reboot
#   5. VM reclaim tuning          -- so kswapd reclaims early instead of deadlocking
#                                    inside the driver's page fault path
#
# Unlike the nimbus original there is NO swap step here. That script removed a
# 128 GiB /swapfile128 that the DGX Spark shipped with; the Dell Pro Max boxes
# ship with only the 16 GiB /swap.img, which is the size we want. Layer 5 assumes
# swap is small -- if `swapon --show` on this box lists anything beyond a ~16 GiB
# /swap.img, stop and read ../nimbus/resize-swap.sh before going further.

set -euo pipefail
[ "$EUID" -eq 0 ] || { echo "must run as root (use sudo)" >&2; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"

echo "==> 0/5  swap sanity"
# Oversized swap is what prevented the OOM killer from ever firing on 2026-08-24:
# with 143 GiB of swap free, "reclaim and swap both failed to progress" is
# effectively unreachable, so the kernel thrashed instead of reaping the runaway.
SWAP_KIB=$(awk 'NR>1 {s+=$3} END {print s+0}' /proc/swaps)
echo "    total swap: $((SWAP_KIB/1024/1024)) GiB"
if [ "$SWAP_KIB" -gt $((32*1024*1024)) ]; then
    echo "    FAIL: more than 32 GiB of swap on a 121 GiB box. This is the 2026-08-24" >&2
    echo "          configuration. Read ../nimbus/resize-swap.sh and fix this first." >&2
    swapon --show >&2
    exit 1
fi

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
# Only ever an agent in this fleet -- these boxes were never control planes, so
# unlike nimbus there is no server-config branch to pick between. If
# /etc/rancher/k3s/config.yaml is already in place (join-gb10.sh installs it
# BEFORE the agent first starts, so the taint applies at registration), leave it
# alone rather than clobbering a live node's node-ip.
if [ -f /etc/rancher/k3s/config.yaml ]; then
    if grep -q '__NODE_IP__' /etc/rancher/k3s/config.yaml; then
        echo "    FAIL: /etc/rancher/k3s/config.yaml still has the __NODE_IP__ placeholder." >&2
        echo "          It was copied by hand instead of rendered by join-gb10.sh." >&2
        exit 1
    fi
    echo "    config.yaml present (node-ip $(awk '/^node-ip:/ {print $2}' /etc/rancher/k3s/config.yaml)); left as is"
else
    echo "    no /etc/rancher/k3s/config.yaml yet -- join-gb10.sh installs it. Skipping."
fi

echo "==> 4/5  full magic sysrq"
cat > /etc/sysctl.d/99-gb10-sysrq.conf <<'CONF'
# Full sysrq so the GPU hang watchdog can force a sync+reboot when the clean
# path is blocked. Was 176 (reboot+remount-ro+sync) -- 1 additionally enables
# process signalling and task dumps, which is what makes a wedge debuggable.
kernel.sysrq = 1
CONF
sysctl -q -p /etc/sysctl.d/99-gb10-sysrq.conf
echo "    kernel.sysrq = $(sysctl -n kernel.sysrq)"

echo "==> 5/5  VM reclaim tuning"
echo "    before: min_free_kbytes=$(sysctl -n vm.min_free_kbytes) watermark_scale_factor=$(sysctl -n vm.watermark_scale_factor) swappiness=$(sysctl -n vm.swappiness)"
install -m 0644 "$HERE/99-gb10-vm.conf" /etc/sysctl.d/99-gb10-vm.conf
sysctl -q -p /etc/sysctl.d/99-gb10-vm.conf
echo "    after:  min_free_kbytes=$(sysctl -n vm.min_free_kbytes) watermark_scale_factor=$(sysctl -n vm.watermark_scale_factor) swappiness=$(sysctl -n vm.swappiness)"

echo
echo "Done. Verify with:"
echo "  systemctl list-timers gpu-hang-watchdog.timer"
echo "  journalctl -u gpu-hang-watchdog.service -f"
