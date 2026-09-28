#!/bin/bash
# host-gpu-setup.sh -- host-side GPU requirements that live outside Kubernetes.
# Run with sudo, ON a GPU node. Idempotent; a no-op on a host without
# nvidia-ctk. cluster/os-updates/install-os-updates.sh runs it first, and
# join-gb10.sh runs that, so every GPU node gets it before its first upgrade.
#
#   sudo platform/nvidia/host-gpu-setup.sh
#
# /dev/char symlinks for the NVIDIA devices (71-nvidia-dev-char.rules). On
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

sed "s|__NVIDIA_CTK__|$CTK|" "$HERE/71-nvidia-dev-char.rules" > /etc/udev/rules.d/71-nvidia-dev-char.rules
chmod 0644 /etc/udev/rules.d/71-nvidia-dev-char.rules
udevadm control --reload-rules
"$CTK" system create-dev-char-symlinks --create-all
echo "    udev rule installed; $(ls -l /dev/char | grep -c nvidia) NVIDIA /dev/char links:"
ls -l /dev/char | grep nvidia | awk '{print "      " $(NF-2), $NF}'
echo "    GPU containers started BEFORE these links existed are still exposed to"
echo "    the next systemd reload: restart them once."
