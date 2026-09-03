#!/usr/bin/env bash
# 02-join.sh -- turn nimbus from a standalone k3s server into an agent
# (worker) of the cirrus control plane.
#
#   sudo CIRRUS_K3S_VERSION=vX.Y.Z+k3s1 K3S_TOKEN='<cirrus node-token>' ./02-join.sh
#
# THIS IS DESTRUCTIVE AND NOT REVERSIBLE. k3s-uninstall.sh deletes
# /var/lib/rancher/k3s -- the whole datastore. Every object in nimbus's current
# cluster ceases to exist: Deployments, Services, Ingresses, Secrets, PVs.
# Run ./01-backup-nimbus.sh first and check its output.
#
# What is NOT touched:
#   /home/cboettig/.cache/huggingface  -- the 22 GiB model cache, hostPath-mounted
#   the openebs-zpool ZFS pool          -- orphaned but intact (see README)
#   /usr/local/bin/gpu-hang-watchdog.sh -- host-level, survives untouched
#
# Get the two required values from cirrus:
#   ssh cirrus 'k3s --version | head -1'                                  -> CIRRUS_K3S_VERSION
#   ssh cirrus 'sudo cat /var/lib/rancher/k3s/server/node-token'          -> K3S_TOKEN

set -euo pipefail

CIRRUS_IP="${CIRRUS_IP:-128.32.85.8}"
CIRRUS_URL="https://${CIRRUS_IP}:6443"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARDENING="$HERE/../nimbus-hardening"

[ "$EUID" -eq 0 ] || { echo "must run as root (use sudo -E, so the env vars survive)" >&2; exit 1; }
: "${CIRRUS_K3S_VERSION:?set CIRRUS_K3S_VERSION to the exact k3s version cirrus runs, e.g. v1.34.5+k3s1}"
: "${K3S_TOKEN:?set K3S_TOKEN to the contents of cirrus:/var/lib/rancher/k3s/server/node-token}"

echo "=============================================================="
echo " nimbus -> cirrus cluster join"
echo "   control plane : $CIRRUS_URL"
echo "   agent version : $CIRRUS_K3S_VERSION"
echo "   node IP       : 128.32.85.239"
echo "   taint         : dedicated=nimbus:NoSchedule (set at registration)"
echo "=============================================================="
echo

# --- preflight ---------------------------------------------------------------
echo "==> preflight"

# The agent must not be NEWER than the server. A newer kubelet against an older
# apiserver is outside k8s's supported skew and k3s will not stop you.
LOCAL_VER="$(k3s --version 2>/dev/null | awk '/^k3s version/ {print $3}')"
echo "    nimbus currently runs $LOCAL_VER, will install $CIRRUS_K3S_VERSION"
if [ "$LOCAL_VER" != "$CIRRUS_K3S_VERSION" ]; then
    echo "    NOTE: version change. Confirm $CIRRUS_K3S_VERSION is cirrus's *server* version."
fi

# 6443 must be reachable, and it must be cirrus directly -- not Cloudflare.
# cirrus.carlboettiger.info is orange-clouded and resolves to 172.67.x.x, which
# will never carry 6443. This is why CIRRUS_IP defaults to the LAN address.
if timeout 5 bash -c "cat < /dev/null > /dev/tcp/${CIRRUS_IP}/6443" 2>/dev/null; then
    echo "    ${CIRRUS_IP}:6443 reachable"
else
    echo "    FAIL: cannot reach ${CIRRUS_IP}:6443 -- fix this before continuing" >&2
    exit 1
fi

# flannel VXLAN between the two nodes. If 8472/udp is blocked, the node will
# join and go Ready, and then every cross-node pod connection will hang --
# a genuinely confusing failure mode, so check for a local firewall now.
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    echo "    WARNING: ufw is active. cirrus<->nimbus needs 6443/tcp, 8472/udp, 10250/tcp."
    ufw status numbered | sed 's/^/      /'
else
    echo "    no active ufw"
fi

[ -f "$HARDENING/harden-nimbus.sh" ] || { echo "    FAIL: $HARDENING/harden-nimbus.sh missing" >&2; exit 1; }
grep -q 'node-taint' "$HARDENING/k3s-agent-config.yaml" 2>/dev/null \
  || { echo "    FAIL: $HARDENING/k3s-agent-config.yaml missing or has no node-taint." >&2
       exit 1; }
echo "    hardening files present, agent config carries the taint"

BACKUP="$(cd "$HERE/../.." && pwd)/secrets/nimbus-join-backup"
if [ -f "$BACKUP/secret-vllm-api-key.yaml" ] && [ -f "$BACKUP/secret-ngc-pull.yaml" ]; then
    echo "    01-backup-nimbus.sh output found in $BACKUP"
else
    echo "    FAIL: no backup found at $BACKUP -- run ./01-backup-nimbus.sh first" >&2
    exit 1
fi

echo
read -r -p "Destroy nimbus's cluster and join cirrus? Type 'join nimbus' to proceed: " CONFIRM
[ "$CONFIRM" = "join nimbus" ] || { echo "aborted."; exit 1; }

# --- teardown ----------------------------------------------------------------
echo
echo "==> tearing down the standalone server"
# k3s-killall.sh first, deliberately. `systemctl stop k3s` does NOT stop pods:
# the unit ships KillMode=process, so every containerd-shim (and therefore every
# container, including vLLM holding ~64 GiB of the unified pool) keeps running
# as an orphan. See ../nimbus-hardening/README.md.
/usr/local/bin/k3s-killall.sh
echo "    killall done; GPU memory released"
/usr/local/bin/k3s-uninstall.sh
echo "    server uninstalled"

# --- install the agent -------------------------------------------------------
echo
echo "==> installing the agent"
# The config file must exist BEFORE the installer starts the service, so that
# node-taint is applied at registration. If the node were to register untainted
# even briefly, cirrus's scheduler could place pods on it in that window -- and
# on an arm64 node most of cirrus's amd64 images would CrashLoopBackOff.
install -d -m 0755 /etc/rancher/k3s
install -m 0644 "$HARDENING/k3s-agent-config.yaml" /etc/rancher/k3s/config.yaml
echo "    /etc/rancher/k3s/config.yaml installed (taint + eviction thresholds)"

curl -sfL https://get.k3s.io \
  | INSTALL_K3S_VERSION="$CIRRUS_K3S_VERSION" \
    K3S_URL="$CIRRUS_URL" \
    K3S_TOKEN="$K3S_TOKEN" \
    sh -s - agent

echo "    agent installed"

# --- re-apply the rest of the hardening --------------------------------------
echo
echo "==> re-applying node hardening"
# Layers 1, 2, 4 and 5 live outside /etc/rancher/k3s and survived the uninstall,
# but harden-nimbus.sh is idempotent and re-asserts all of them. It also
# reinstalls the config we just wrote, which is harmless.
bash "$HARDENING/harden-nimbus.sh"

echo
echo "==> waiting for the agent to register"
for i in $(seq 1 60); do
    if systemctl is-active --quiet k3s-agent; then break; fi
    sleep 2
done
systemctl is-active k3s-agent && echo "    k3s-agent is active" \
  || { echo "    k3s-agent did not come up; journalctl -u k3s-agent -n 50" >&2; exit 1; }

echo
echo "=============================================================="
echo " Agent installed. nimbus has NO kubeconfig of its own any more."
echo " Verify from a machine with cirrus admin credentials:"
echo "     kubectl get nodes -o wide"
echo " Then run 03-post-join.sh against the cirrus cluster."
echo "=============================================================="
