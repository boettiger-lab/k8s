#!/bin/bash
# apt-metrics.sh -- export this node's OS-update state for node-exporter's
# textfile collector. Run by apt-metrics.timer; installed by
# install-os-updates.sh. Read-only: it never changes package state.
#
# Exists because the failure it watches for is SILENT. On cirrus,
# unattended-upgrades ran daily for a year and installed nothing; on the GB10s
# it was never installed at all. Neither produced an error anywhere. The alert
# rules in platform/monitoring/prometheus-values.yaml read these series.
#
#   node_apt_upgrades_pending{class="security_auto"}  security updates unattended-upgrades
#                                                     SHOULD install -- nonzero for days = it is broken
#   node_apt_upgrades_pending{class="security_held"}  security updates we hold on purpose
#                                                     (kernel/GPU/ZFS) -- a maintenance window is due
#   node_apt_upgrades_pending{class="other"}          everything else (-updates, vendor repos)
#   node_apt_unattended_upgrades_enabled              APT::Periodic::Unattended-Upgrade != 0
#   node_apt_unattended_upgrades_last_run_timestamp_seconds
#   node_reboot_required                              1 while /var/run/reboot-required exists
#   node_reboot_required_timestamp_seconds            when it appeared (only while it exists)

set -euo pipefail
DIR=/var/lib/node_exporter/textfile_collector
OUT="$DIR/apt.prom"
mkdir -p "$DIR"

# The same blacklist unattended-upgrades applies, read from the live apt
# config so the two can never disagree.
mapfile -t BLACKLIST < <(apt-config dump --format '%v%n' Unattended-Upgrade::Package-Blacklist | sed '/^$/d')
held() {
    local re
    for re in "${BLACKLIST[@]}"; do
        [[ "$1" =~ ^$re ]] && return 0
    done
    return 1
}

sec_auto=0; sec_held=0; other=0
# Lines look like: openssl/jammy-security,jammy-updates 3.0.2-0ubuntu1.29 amd64 [upgradable from: ...]
while read -r line; do
    [[ "$line" == */* ]] || continue
    pkg="${line%%/*}"
    archives="${line#*/}"; archives="${archives%% *}"
    if [[ ",$archives," == *-security,* ]]; then
        if held "$pkg"; then sec_held=$((sec_held+1)); else sec_auto=$((sec_auto+1)); fi
    else
        other=$((other+1))
    fi
done < <(apt list --upgradable 2>/dev/null)

enabled=0
periodic="$(apt-config dump --format '%v' APT::Periodic::Unattended-Upgrade)"
if [ -x /usr/bin/unattended-upgrade ] && [ -n "$periodic" ] && [ "$periodic" != "0" ]; then
    enabled=1
fi

tmp="$(mktemp "$DIR/.apt.prom.XXXXXX")"
{
    echo "# HELP node_apt_upgrades_pending Upgradable apt packages by class."
    echo "# TYPE node_apt_upgrades_pending gauge"
    echo "node_apt_upgrades_pending{class=\"security_auto\"} $sec_auto"
    echo "node_apt_upgrades_pending{class=\"security_held\"} $sec_held"
    echo "node_apt_upgrades_pending{class=\"other\"} $other"
    echo "# HELP node_apt_unattended_upgrades_enabled 1 if unattended-upgrades is installed and enabled."
    echo "# TYPE node_apt_unattended_upgrades_enabled gauge"
    echo "node_apt_unattended_upgrades_enabled $enabled"
    stamp=/var/lib/apt/periodic/unattended-upgrades-stamp
    if [ -e "$stamp" ]; then
        echo "# HELP node_apt_unattended_upgrades_last_run_timestamp_seconds Last unattended-upgrades run."
        echo "# TYPE node_apt_unattended_upgrades_last_run_timestamp_seconds gauge"
        echo "node_apt_unattended_upgrades_last_run_timestamp_seconds $(stat -c %Y "$stamp")"
    fi
    echo "# HELP node_reboot_required 1 if /var/run/reboot-required exists."
    echo "# TYPE node_reboot_required gauge"
    if [ -e /var/run/reboot-required ]; then
        echo "node_reboot_required 1"
        echo "# HELP node_reboot_required_timestamp_seconds When /var/run/reboot-required appeared."
        echo "# TYPE node_reboot_required_timestamp_seconds gauge"
        echo "node_reboot_required_timestamp_seconds $(stat -c %Y /var/run/reboot-required)"
    else
        echo "node_reboot_required 0"
    fi
} > "$tmp"
chmod 0644 "$tmp"
mv "$tmp" "$OUT"
