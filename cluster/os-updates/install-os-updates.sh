#!/bin/bash
# install-os-updates.sh -- automatic OS security updates for a cluster node.
# Run with sudo, ON the node. Idempotent. Same script for every node: cirrus
# (Pop 22.04), the GB10s and thelio (Ubuntu 24.04).
#
#   sudo ./install-os-updates.sh           # install, then show what WOULD be upgraded
#   sudo ./install-os-updates.sh --apply   # ...and apply those security updates now
#
# Installs four things (policy and rationale in README.md):
#   1. GPU nodes: /dev/char symlinks, so a systemd reload during an upgrade
#      does not strip running GPU containers of their devices
#   2. unattended-upgrades, security pockets only, GPU/kernel/ZFS held
#   3. needrestart, restarting daemons after library updates (never k3s)
#   4. apt-metrics timer, feeding node-exporter so the alerts can see this node
#
# It never reboots. --apply installs only what the nightly run would install,
# i.e. the non-held security updates; the held packages stay for a
# maintenance window.

set -euo pipefail
[ "$EUID" -eq 0 ] || { echo "must run as root (use sudo)" >&2; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1
export DEBIAN_FRONTEND=noninteractive

echo "==> $(hostname): $(lsb_release -ds) ($(lsb_release -cs))"

echo "==> 1/4  GPU device symlinks"
# FIRST, before anything below touches a package: the first unattended run on
# cirrus (2026-09-28) reloaded systemd and every running GPU container lost its
# GPU, and the apt-get install in the next step can trigger a reload too.
bash "$HERE/../../platform/nvidia/host-gpu-setup.sh"

echo "==> 2/4  unattended-upgrades"
# The GB10 base image ships WITHOUT unattended-upgrades -- nothing at all was
# applying security updates there. Pop has it but was matching nothing.
# needrestart's policy goes in BEFORE the package: its apt hook fires at the end
# of the very install that brings it in, and must not run with the defaults.
install -d /etc/needrestart/conf.d
install -m 0644 "$HERE/50-cluster.conf" /etc/needrestart/conf.d/50-cluster.conf
apt-get -qq update
apt-get -qq install -y unattended-upgrades needrestart >/dev/null
rm -f /etc/apt/apt.conf.d/51cluster-unattended-upgrades   # pre-2026-09-29 name; lost to 99update-notifier-nvidia
install -m 0644 "$HERE/99zz-cluster-unattended-upgrades" /etc/apt/apt.conf.d/99zz-cluster-unattended-upgrades
systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null
systemctl enable unattended-upgrades.service >/dev/null
echo "    origins:   $(apt-config dump --format '%v ' Unattended-Upgrade::Origins-Pattern)"
echo "    held:      $(apt-config dump --format '%v ' Unattended-Upgrade::Package-Blacklist)"
echo "    allowed-origins (must be empty): '$(apt-config dump --format '%v' Unattended-Upgrade::Allowed-Origins)'"
# Verify the EFFECTIVE values, not the file we wrote: a vendor file sorting
# later (99update-notifier-nvidia on the GB10s) once overrode ours silently.
for k in APT::Periodic::Unattended-Upgrade APT::Periodic::Update-Package-Lists; do
    v="$(apt-config dump --format '%v' "$k")"
    [ "$v" = "1" ] || { echo "    FAIL: effective $k is '$v', not 1 -- a later file in /etc/apt/apt.conf.d overrides ours:" >&2; grep -l "$k" /etc/apt/apt.conf.d/* >&2; exit 1; }
done
echo "    effective: Unattended-Upgrade=1, Update-Package-Lists=1"

echo "==> 3/4  needrestart"
echo "    restart mode 'a' (automatic); k3s/containerd/nvidia excluded"

echo "==> 4/4  apt-metrics timer"
install -m 0755 "$HERE/apt-metrics.sh" /usr/local/bin/apt-metrics.sh
install -m 0644 "$HERE/apt-metrics.service" /etc/systemd/system/
install -m 0644 "$HERE/apt-metrics.timer"   /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now apt-metrics.timer >/dev/null
systemctl start apt-metrics.service
sed -n 's/^\(node_[a-z_]*\({[^}]*}\)\?\) /    \1 /p' /var/lib/node_exporter/textfile_collector/apt.prom

if [ "$APPLY" -eq 1 ]; then
    echo "==> applying security updates now (unattended-upgrade -v)"
    unattended-upgrade -v
    systemctl start apt-metrics.service
    echo "    after:"
    sed -n 's/^\(node_apt_upgrades_pending{[^}]*}\) /    \1 /p; s/^\(node_reboot_required\) /    \1 /p' \
        /var/lib/node_exporter/textfile_collector/apt.prom
else
    echo "==> dry run: what the nightly run will install"
    unattended-upgrade --dry-run -v 2>&1 | grep -E "^(Packages that will be upgraded|Allowed origins|No packages found)" || true
    echo
    echo "Nothing was upgraded. To apply now: sudo $0 --apply"
fi
