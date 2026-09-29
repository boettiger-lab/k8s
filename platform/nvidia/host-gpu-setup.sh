#!/bin/bash
# host-gpu-setup.sh -- host-side GPU requirements that live outside Kubernetes.
# Run with sudo, ON a GPU node. Idempotent; a no-op on a host without
# nvidia-ctk. cluster/os-updates/install-os-updates.sh runs it first, and
# join-gb10.sh runs that, so every GPU node gets it before its first upgrade.
#
#   sudo platform/nvidia/host-gpu-setup.sh
#
# /dev/char symlinks for the NVIDIA devices (nvidia-dev-char-symlinks.service,
# at every boot, before k3s). On
# cgroup v2 with systemd-managed containers, a `systemctl daemon-reload` --
# which package upgrades trigger routinely -- rebuilds each container's device
# cgroup from systemd's list. The runtime can only put a device on that list
# through its /dev/char/<major>:<minor> path, and nvidia-modprobe creates the
# NVIDIA nodes outside udev, so without these links every running GPU container
# silently loses its GPU ("Failed to initialize NVML: Unknown Error") while
# the host driver stays perfectly healthy.

set -euo pipefail
[ "$EUID" -eq 0 ] || { echo "must run as root (use sudo)" >&2; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CTK="$(command -v nvidia-ctk || true)"
if [ -z "$CTK" ]; then
    echo "    no nvidia-ctk on this host -- not a GPU node, skipped"
    exit 0
fi

SMI="$(command -v nvidia-smi)"
# Superseded: NVIDIA's udev rule needs --create-all, which fails on this
# nvidia-ctk with the 580 driver -- remove it if an earlier run installed it.
if [ -e /etc/udev/rules.d/71-nvidia-dev-char.rules ]; then
    rm -f /etc/udev/rules.d/71-nvidia-dev-char.rules
    udevadm control --reload-rules
fi
sed -e "s|__NVIDIA_CTK__|$CTK|" -e "s|__NVIDIA_SMI__|$SMI|" \
    "$HERE/nvidia-dev-char-symlinks.service" > /etc/systemd/system/nvidia-dev-char-symlinks.service
chmod 0644 /etc/systemd/system/nvidia-dev-char-symlinks.service
systemctl daemon-reload
systemctl enable nvidia-dev-char-symlinks.service >/dev/null
systemctl restart nvidia-dev-char-symlinks.service
echo "    boot service enabled; $(ls -l /dev/char | grep -c nvidia) NVIDIA /dev/char links:"
ls -l /dev/char | grep nvidia | awk '{print "      " $(NF-2), $NF}'
echo "    GPU containers started BEFORE these links existed are still exposed to"
echo "    the next systemd reload: restart them once."
