#!/usr/bin/env bash
# install-kubectl-tools.sh
#
# Installs kubectl and the kubelogin OIDC plugin (kubectl-oidc_login) for
# access to the NRP Nautilus Kubernetes cluster.
#
# No credentials or kubeconfig are written by this script.
# Authentication must happen manually after container startup.

set -euo pipefail

# Resilient curl wrapper: retries transient network errors / GitHub API
# rate-limits (HTTP 403/429/5xx) so the image build doesn't flake in CI.
curl_retry() { curl --retry 5 --retry-delay 3 --retry-all-errors -fsSL "$@"; }

# --------------------------------------------------------------------------
# Architecture detection
# --------------------------------------------------------------------------
case "$(uname -m)" in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    armv7l)  ARCH="arm"   ;;
    *)
        echo "ERROR: Unsupported architecture: $(uname -m)" >&2
        exit 1
        ;;
esac

echo "==> Detected architecture: ${ARCH}"

# --------------------------------------------------------------------------
# Install kubectl
# --------------------------------------------------------------------------
echo "==> Installing kubectl..."

KUBECTL_VERSION="$(curl_retry https://dl.k8s.io/release/stable.txt)"
echo "    Latest stable version: ${KUBECTL_VERSION}"

curl_retry \
    "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" \
    -o /tmp/kubectl

chmod +x /tmp/kubectl
install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl
rm /tmp/kubectl

echo "    kubectl ${KUBECTL_VERSION} installed to /usr/local/bin/kubectl"

# --------------------------------------------------------------------------
# Install kubelogin as kubectl-oidc_login
# Required by NRP Nautilus for CILogon/OIDC authentication.
# See: https://github.com/int128/kubelogin
# --------------------------------------------------------------------------
echo "==> Installing kubelogin (kubectl-oidc_login plugin)..."

# Resolve the latest tag via the github.com redirect (NOT the api.github.com
# REST endpoint, which is rate-limited to 60 req/hr for anonymous CI builds and
# was intermittently 403'ing the amd64 build).
KUBELOGIN_VERSION="$(
    curl_retry -o /dev/null -w '%{url_effective}' \
        https://github.com/int128/kubelogin/releases/latest \
    | sed 's#.*/tag/##'
)"
echo "    Latest version: ${KUBELOGIN_VERSION}"

curl_retry \
    "https://github.com/int128/kubelogin/releases/download/${KUBELOGIN_VERSION}/kubelogin_linux_${ARCH}.zip" \
    -o /tmp/kubelogin.zip

mkdir -p /tmp/kubelogin-extract
unzip -q /tmp/kubelogin.zip -d /tmp/kubelogin-extract

install -o root -g root -m 0755 \
    /tmp/kubelogin-extract/kubelogin \
    /usr/local/bin/kubectl-oidc_login

rm -rf /tmp/kubelogin.zip /tmp/kubelogin-extract

echo "    kubelogin ${KUBELOGIN_VERSION} installed to /usr/local/bin/kubectl-oidc_login"

# --------------------------------------------------------------------------
# Verify installs
# --------------------------------------------------------------------------
echo ""
echo "==> Verifying installs..."
kubectl version --client 2>/dev/null | head -2
kubectl oidc-login --version 2>/dev/null || true

# --------------------------------------------------------------------------
# Post-install instructions
# --------------------------------------------------------------------------
echo ""
echo "=========================================================="
echo "  kubectl + kubelogin installed successfully."
echo "=========================================================="
echo ""
echo "Next steps to connect to NRP Nautilus (run inside container):"
echo ""
echo "  1. Download your kubeconfig from https://portal.nrp-nautilus.io/"
echo "     and place it at:  ~/.kube/config"
echo ""
echo "  2. Verify available contexts:"
echo "       kubectl config get-contexts"
echo ""
echo "  3. Set the active context:"
echo "       kubectl config use-context nautilus"
echo ""
echo "  4. Run any kubectl command to trigger OIDC browser login:"
echo "       kubectl get pods"
echo ""
echo "  For headless/remote auth (no browser), use device code flow:"
echo "       kubectl oidc-login get-token --grant-type=device-code --skip-open-browser"
echo ""
echo "  To clear cached tokens (e.g. after namespace changes):"
echo "       kubectl oidc-login clean"
echo "=========================================================="
