#!/bin/bash
# Setup ZFS pool for OpenEBS on a single-disk system
# This script creates a file-backed ZFS pool when no spare disk/partition is available
#
# Usage: sudo ./setup-zfs-pool.sh [pool-size-in-GB]
# Default size: 2000 GB (2 TB)

set -e

POOL_NAME="openebs-zpool"
POOL_SIZE_GB="${1:-2000}"
ZFS_DIR="/var/lib/openebs/zfs"
ZFS_FILE="${ZFS_DIR}/${POOL_NAME}.img"

echo "============================================"
echo "ZFS Pool Setup for OpenEBS"
echo "============================================"
echo "Pool name:     $POOL_NAME"
echo "Pool size:     ${POOL_SIZE_GB} GB"
echo "Backing file:  $ZFS_FILE"
echo "============================================"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "❌ Please run as root (sudo)"
    exit 1
fi

# Check if ZFS is installed
if ! command -v zpool &> /dev/null; then
    echo "📦 Installing ZFS utilities..."
    apt update && apt install -y zfsutils-linux
fi

# Check if pool already exists
if zpool list "$POOL_NAME" &> /dev/null; then
    echo "⚠️  Pool '$POOL_NAME' already exists!"
    zpool status "$POOL_NAME"
    echo ""
    echo "To destroy and recreate, run:"
    echo "  sudo zpool destroy $POOL_NAME"
    echo "  sudo rm -f $ZFS_FILE"
    exit 1
fi

# Check available disk space
AVAIL_GB=$(df -BG / | tail -1 | awk '{print $4}' | tr -d 'G')
echo "📊 Available disk space: ${AVAIL_GB} GB"

if [ "$AVAIL_GB" -lt "$POOL_SIZE_GB" ]; then
    echo "❌ Not enough disk space!"
    echo "   Requested: ${POOL_SIZE_GB} GB"
    echo "   Available: ${AVAIL_GB} GB"
    exit 1
fi

# Create directory for ZFS backing file
echo "📁 Creating ZFS backing directory..."
mkdir -p "$ZFS_DIR"

# Create sparse file (doesn't allocate space until used)
echo "📄 Creating sparse backing file (${POOL_SIZE_GB} GB)..."
truncate -s "${POOL_SIZE_GB}G" "$ZFS_FILE"

# Create ZFS pool
echo "🔧 Creating ZFS pool '$POOL_NAME'..."
zpool create -f -o ashift=12 "$POOL_NAME" "$ZFS_FILE"

# Set recommended properties for container storage
echo "⚙️  Configuring pool properties..."
zfs set compression=lz4 "$POOL_NAME"
zfs set atime=off "$POOL_NAME"
zfs set xattr=sa "$POOL_NAME"

# Verify
echo ""
echo "============================================"
echo "✅ ZFS Pool Created Successfully!"
echo "============================================"
zpool status "$POOL_NAME"
echo ""
zfs list
echo ""
echo "Next steps:"
echo "  1. Install OpenEBS:  cd openebs && bash helm.sh"
echo "  2. Apply storage class: kubectl apply -f openebs/zfs-storage.yml"
echo ""

# Create systemd service to import pool on boot
echo "🔄 Creating systemd service for pool import on boot..."
cat > /etc/systemd/system/zfs-import-openebs.service << EOF
[Unit]
Description=Import OpenEBS ZFS Pool
DefaultDependencies=no
Before=zfs-import-scan.service
Before=zfs-import-cache.service
After=systemd-udev-settle.service
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/zpool import -d ${ZFS_DIR} ${POOL_NAME}
ExecStop=/sbin/zpool export ${POOL_NAME}

[Install]
WantedBy=zfs-mount.service
EOF

systemctl daemon-reload
systemctl enable zfs-import-openebs.service
echo "✅ Pool will auto-import on boot"
