#!/usr/bin/env bash
# install-armada.sh
#
# Installs armadactl, the CLI for the Armada batch job queue used on NRP
# Nautilus, together with the D-Bus + Secret Service stack armadactl needs in
# order to cache its OIDC token.
#
# Armada matters because it is not bound by the Kubernetes indexed-Job
# completion cap (~200, an etcd pressure limit), so work can be split into
# thousands of small jobs instead of hundreds of large ones. Small jobs lose
# minutes rather than hours to preemption, request what one step needs instead
# of the peak of a long chain, and pack into free scraps instead of waiting for
# large contiguous slots.
#
# No credentials are written by this script. A config file pointing at the NRP
# Armada server is installed, but authentication happens after startup.

set -euo pipefail

curl_retry() { curl --retry 5 --retry-delay 3 --retry-all-errors -fsSL "$@"; }

# --------------------------------------------------------------------------
# Architecture detection
# --------------------------------------------------------------------------
case "$(uname -m)" in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    *)
        echo "ERROR: Unsupported architecture: $(uname -m)" >&2
        exit 1
        ;;
esac

echo "==> Detected architecture: ${ARCH}"

# --------------------------------------------------------------------------
# Secret Service, for armadactl's OIDC token cache
#
# armadactl caches its refresh token through go-keyring, which on Linux talks
# to a D-Bus Secret Service. Without one it fails with
#
#   failed to save refresh token to keyring: exec: "dbus-launch": executable
#   file not found in $PATH
#
# and then re-authenticates on EVERY invocation — which, given NRP's device
# codes expire in 60 seconds, makes the CLI painful to use and impossible to
# automate. These three packages supply the session bus, the secret store, and
# the secret-tool CLI used to verify it.
# --------------------------------------------------------------------------
echo "==> Installing D-Bus + Secret Service (armadactl token cache)..."

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    dbus-x11 \
    gnome-keyring \
    libsecret-tools
rm -rf /var/lib/apt/lists/*

# --------------------------------------------------------------------------
# Install armadactl
#
# Resolve the latest tag via the github.com redirect rather than the
# api.github.com REST endpoint, which is rate-limited for anonymous CI builds.
# --------------------------------------------------------------------------
echo "==> Installing armadactl..."

ARMADA_VERSION="$(
    curl_retry -o /dev/null -w '%{url_effective}' \
        https://github.com/armadaproject/armada/releases/latest \
    | sed 's#.*/tag/v##'
)"
echo "    Latest version: ${ARMADA_VERSION}"

curl_retry \
    "https://github.com/armadaproject/armada/releases/download/v${ARMADA_VERSION}/armadactl_${ARMADA_VERSION}_linux_${ARCH}.tar.gz" \
    -o /tmp/armadactl.tar.gz

mkdir -p /tmp/armadactl-extract
tar xzf /tmp/armadactl.tar.gz -C /tmp/armadactl-extract

install -o root -g root -m 0755 \
    /tmp/armadactl-extract/armadactl \
    /usr/local/bin/armadactl

rm -rf /tmp/armadactl.tar.gz /tmp/armadactl-extract

echo "    armadactl ${ARMADA_VERSION} installed to /usr/local/bin/armadactl"

# --------------------------------------------------------------------------
# Ship a default NRP config
#
# This uses openIdDeviceAuth, NOT the openIdAuth (PKCE) flow that NRP's own
# published config uses. PKCE binds 127.0.0.1:50000 and waits for a browser
# redirect, so it CANNOT complete in a headless container: it hangs silently,
# prints no URL, and keeps holding the port, so every later attempt dies with
# "bind: address already in use". The device flow prints a URL to approve on
# any device and needs no local callback port.
#
# Contains no secrets — the client id and endpoints are public. Follows the
# same pattern as the shipped kubeconfig: on JupyterHub this file is shadowed
# by the PVC mounted over the home directory, so it only takes effect for
# independent (non-hub) use of the image.
# --------------------------------------------------------------------------
echo "==> Installing default armadactl config..."

cat > /tmp/armadactl.yaml <<'YAML'
currentContext: main
contexts:
  main:
    cacheRefreshToken: true
    armadaUrl: armada.nrp-nautilus.io:50051
    openIdDeviceAuth:
      providerUrl: "https://authentik.nrp-nautilus.io/application/o/armada/"
      clientId: "8AeUAhsM1rA8WRJoX586BhJk8t5Icfrm169ESz8Y"
      scopes:
        - "openid"
        - "profile_prefixed"
        - "offline_access"
YAML

install -o "${NB_USER}" -g "${NB_USER}" -m 0600 \
    /tmp/armadactl.yaml "${HOME}/.armadactl.yaml"
rm /tmp/armadactl.yaml

echo "    config installed to ${HOME}/.armadactl.yaml"

# --------------------------------------------------------------------------
# Verify installs
# --------------------------------------------------------------------------
echo ""
echo "==> Verifying installs..."
armadactl version 2>/dev/null | head -2 || true
for b in dbus-run-session gnome-keyring-daemon secret-tool; do
    printf '    %-24s %s\n' "$b" "$(command -v "$b" || echo MISSING)"
done

# --------------------------------------------------------------------------
# Post-install instructions
# --------------------------------------------------------------------------
echo ""
echo "=========================================================="
echo "  armadactl installed successfully."
echo "=========================================================="
echo ""
echo "Queues correspond to cluster namespaces; submit to the ones you"
echo "normally access. You do not create a queue."
echo ""
echo "  armadactl get queues"
echo "  armadactl submit jobs.yaml"
echo ""
echo "Monitor at https://armada-lookout.nrp-nautilus.io"
echo ""
echo "AUTHENTICATION"
echo ""
echo "  The device code expires in 60 SECONDS. Have the browser ready before"
echo "  you run the command, then approve the printed URL immediately."
echo ""
echo "  To have the token cached so you authenticate once rather than on every"
echo "  command, run under a session bus with an unlocked keyring:"
echo ""
echo "      dbus-run-session -- bash -c '\\"
echo "        echo -n \"\" | gnome-keyring-daemon --unlock --components=secrets; \\"
echo "        armadactl get queues'"
echo ""
echo "  Without a session bus armadactl warns \"Failed to save token to cache\""
echo "  and re-authenticates every time. That is survivable for a submit — one"
echo "  call can carry thousands of jobs — but not for unattended use."
echo ""
echo "  For cron or an always-on agent, prefer a non-interactive method:"
echo "  execAuth (a command that returns a token) or"
echo "  openIdClientCredentialsAuth (a service-account client)."
echo "=========================================================="
