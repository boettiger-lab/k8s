#!/usr/bin/env bash
# join-gb10.sh -- join a GB10 box to the cirrus cluster as a tainted agent.
#
#   sudo -E CIRRUS_K3S_VERSION=vX.Y.Z+k3s1 K3S_TOKEN='<cirrus node-token>' ./join-gb10.sh
#
# Run ON the box being joined. Get the two required values from the control-plane
# host (cirrus):
#   k3s --version | head -1
#   sudo cat /var/lib/rancher/k3s/server/node-token
#
# GREENFIELD ONLY. These boxes were never control planes, so the nimbus teardown
# steps (01-backup-nimbus.sh, k3s-killall.sh, k3s-uninstall.sh) have no analogue
# here and nothing is destroyed. This script REFUSES to run on a host that
# already has k3s installed -- use ../nimbus/join/ for the demote-a-server case.

set -euo pipefail

CIRRUS_IP="${CIRRUS_IP:-128.32.85.8}"
CIRRUS_URL="https://${CIRRUS_IP}:6443"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ "$EUID" -eq 0 ] || { echo "must run as root (use sudo -E, so the env vars survive)" >&2; exit 1; }
: "${CIRRUS_K3S_VERSION:?set CIRRUS_K3S_VERSION to the exact k3s version cirrus runs, e.g. v1.36.4+k3s1}"
: "${K3S_TOKEN:?set K3S_TOKEN to the contents of cirrus:/var/lib/rancher/k3s/server/node-token}"

echo "==> preflight"

# --- 1. this must be a greenfield box ----------------------------------------
if command -v k3s >/dev/null 2>&1 || [ -d /var/lib/rancher/k3s ]; then
    echo "    FAIL: k3s is already present on this host." >&2
    echo "          This script only does greenfield joins. If you meant to rejoin," >&2
    echo "          uninstall first and know what you are destroying." >&2
    exit 1
fi
echo "    no existing k3s"

# --- 2. hostname must match campus DNS ---------------------------------------
# kubectl shows the hostname; taints, nodeSelectors and DNS all have to agree.
# A box still answering to the factory promaxgb10-* name registers under it.
HOST="$(hostname -s)"
case "$HOST" in
    nimbus[0-9]*) echo "    hostname: $HOST" ;;
    *) echo "    FAIL: hostname is '$HOST', not a nimbusN name." >&2
       echo "          sudo hostnamectl set-hostname nimbusN   (then re-run)" >&2
       exit 1 ;;
esac

# --- 3. find the campus interface and its address ----------------------------
# Deliberately NOT `hostname -I` -- that would happily return docker0's
# 172.17.0.1. Pick the interface carrying the 128.32.85.0/24 address.
NODE_IP="$(ip -4 -o addr show scope global \
           | awk '$4 ~ /^128\.32\.85\./ {split($4,a,"/"); print a[1]; exit}')"
NODE_DEV="$(ip -4 -o addr show scope global \
           | awk '$4 ~ /^128\.32\.85\./ {print $2; exit}')"
[ -n "$NODE_IP" ] || { echo "    FAIL: no 128.32.85.0/24 address on any interface." >&2
                       ip -4 -o addr show scope global >&2; exit 1; }
echo "    campus interface: $NODE_DEV -> $NODE_IP"

# --- 4. wired only; Wi-Fi must be down ---------------------------------------
# Fleet decision: a second interface is how a node registers an unroutable
# address and flannel silently blackholes cross-node traffic. `disconnected` is
# not good enough -- NetworkManager can still bring it up later.
for WDEV in $(nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2=="wifi" {print $1}'); do
    STATE="$(nmcli -t -f DEVICE,STATE device 2>/dev/null | awk -F: -v d="$WDEV" '$1==d {print $2}')"
    if [ "$STATE" != "unavailable" ] && [ "$STATE" != "unmanaged" ]; then
        echo "    $WDEV is '$STATE' -- setting it down and unmanaged (wired-only fleet)"
        nmcli device set "$WDEV" managed no  2>/dev/null || true
        nmcli device disconnect "$WDEV"      2>/dev/null || true
        ip link set "$WDEV" down             2>/dev/null || true
    else
        echo "    $WDEV is '$STATE' -- already off"
    fi
done

# --- 5. the control plane must be reachable ----------------------------------
# It must be cirrus directly, not Cloudflare: cirrus.carlboettiger.info is
# orange-clouded and resolves to 172.67.x.x, which will never carry 6443. That
# is why CIRRUS_IP defaults to the LAN address.
if timeout 5 bash -c "cat < /dev/null > /dev/tcp/${CIRRUS_IP}/6443" 2>/dev/null; then
    echo "    ${CIRRUS_IP}:6443 reachable"
else
    echo "    FAIL: cannot reach ${CIRRUS_IP}:6443 -- fix this before continuing" >&2
    exit 1
fi

# --- 6. flannel VXLAN --------------------------------------------------------
# If 8472/udp is blocked the node joins, goes Ready, and then every cross-node
# pod connection hangs -- a genuinely confusing failure mode.
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    echo "    WARNING: ufw is active. cirrus<->$HOST needs 6443/tcp, 8472/udp, 10250/tcp."
    ufw status numbered | sed 's/^/      /'
else
    echo "    no active ufw"
fi

# --- 7. the token must be plausible -----------------------------------------
# Learned on nimbus3, 2026-09-20: a copy-paste that left the literal string
# "<token>" in place sailed straight past the `${K3S_TOKEN:?}` guard above (which
# only catches *empty*), the agent installed cleanly, and then k3s-agent --
# Type=notify -- sat in `systemctl start` for twenty minutes while the agent
# retried "not authorized" every few seconds. Nothing looked broken; the node
# simply never appeared.
echo "    token: ${#K3S_TOKEN} chars"
case "$K3S_TOKEN" in
    *"::server:"*) : ;;
    *) echo "    FAIL: token has no '::server:'. Expected K10<hash>::server:<secret>." >&2
       echo "          Got ${#K3S_TOKEN} chars -- a placeholder or a truncated paste?" >&2
       echo "          On cirrus: sudo cat /var/lib/rancher/k3s/server/node-token" >&2
       exit 1 ;;
esac
[ "${#K3S_TOKEN}" -ge 80 ] || {
    echo "    FAIL: token is only ${#K3S_TOKEN} chars; a node-token is 100+." >&2
    exit 1; }

# A server-side check would be better -- a well-formed token from the wrong
# cluster fails the same silent way -- but k3s's bootstrap endpoints use several
# different credentials (node name + node password, not the token, for the
# serving-kubelet.crt path), and a probe that returns 401 for a VALID token would
# block every join. Not shipping a check whose passing case is unverified.
# The shape checks above catch the failure actually seen; a wrong-cluster token
# still shows up as "not authorized" in `journalctl -u k3s-agent`.

# --- 8. the files we are about to install ------------------------------------
for f in k3s-agent-config.yaml harden-gb10.sh gpu-hang-watchdog.sh 99-gb10-vm.conf; do
    [ -f "$HERE/$f" ] || { echo "    FAIL: $HERE/$f missing" >&2; exit 1; }
done
grep -q 'node-taint' "$HERE/k3s-agent-config.yaml" \
  || { echo "    FAIL: k3s-agent-config.yaml has no node-taint." >&2; exit 1; }
echo "    fleet files present, agent config carries the taint"

echo
echo "=============================================================="
echo " $HOST -> cirrus cluster join (greenfield)"
echo "   control plane : $CIRRUS_URL"
echo "   agent version : $CIRRUS_K3S_VERSION"
echo "   node IP       : $NODE_IP  ($NODE_DEV)"
echo "   taint         : dedicated=gb10:NoSchedule (set at registration)"
echo "   label         : node-class=gb10"
echo "=============================================================="
read -r -p "Proceed? Type 'join $HOST' to continue: " CONFIRM
[ "$CONFIRM" = "join $HOST" ] || { echo "aborted."; exit 1; }

# --- render and install the config BEFORE the agent starts -------------------
# This ordering is the whole point: the node comes up already tainted, so there
# is no window in which cirrus's untainted amd64 workloads can land on it.
echo
echo "==> installing /etc/rancher/k3s/config.yaml"
install -d -m 0755 /etc/rancher/k3s
sed "s|__NODE_IP__|$NODE_IP|" "$HERE/k3s-agent-config.yaml" > /etc/rancher/k3s/config.yaml
chmod 0644 /etc/rancher/k3s/config.yaml
grep -q '__NODE_IP__' /etc/rancher/k3s/config.yaml \
  && { echo "    FAIL: placeholder survived substitution" >&2; exit 1; }
echo "    node-ip $NODE_IP, taint + eviction thresholds in place"

# --- host hardening, before the agent can schedule anything ------------------
echo
echo "==> node hardening"
bash "$HERE/harden-gb10.sh"

# --- install the agent -------------------------------------------------------
echo
echo "==> installing the k3s agent"
curl -sfL https://get.k3s.io \
  | INSTALL_K3S_VERSION="$CIRRUS_K3S_VERSION" \
    K3S_URL="$CIRRUS_URL" \
    K3S_TOKEN="$K3S_TOKEN" \
    sh -s - agent

echo
echo "==> waiting for the agent to come up"
for _ in $(seq 1 60); do
    systemctl is-active --quiet k3s-agent && break
    sleep 2
done
systemctl is-active --quiet k3s-agent && echo "    k3s-agent is active" \
  || { echo "    k3s-agent did not come up; journalctl -u k3s-agent -n 50" >&2; exit 1; }

echo
echo "=============================================================="
echo " Agent installed. $HOST has no kubeconfig of its own."
echo " From cirrus:  ./post-join-gb10.sh $HOST"
echo "=============================================================="
