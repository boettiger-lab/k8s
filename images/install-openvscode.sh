#!/usr/bin/env bash
set -euo pipefail

# openvscode-server is Gitpod's build of VS Code's *upstream* web server, offered
# as an alternative backend to code-server (Coder's fork) for jupyter-vscode-proxy.
# The proxy chooses the backend from $CODE_EXECUTABLE and launches whichever of
# `code-server` / `openvscode-server` is named; both accept --port/--socket and
# --extensions-dir, so the "VS Code" launcher tile is otherwise unchanged.
#
# Why we test it: terminal, file explorer, and the Claude extension all hang off
# code-server's WebSocket + reconnection layer, which is one of the most heavily
# *patched* parts of Coder's fork. Under iOS/iPadOS WebKit (which every iOS
# browser is forced to use) that layer fails — the shell renders but nothing
# interactive connects. openvscode-server stays close to the upstream VS Code-web
# code Microsoft actually exercises on Safari for vscode.dev, so swapping it in
# isolates that single variable.

# Pin with OPENVSCODE_VERSION (e.g. 1.109.5); the default resolves the latest
# release tag so the test image tracks upstream without a hardcoded version.
VERSION="${OPENVSCODE_VERSION:-latest}"
if [ "${VERSION}" = "latest" ]; then
  TAG="$(curl -fsSL https://api.github.com/repos/gitpod-io/openvscode-server/releases/latest \
          | grep '"tag_name"' | head -1 \
          | sed -E 's/.*"openvscode-server-v([^"]+)".*/\1/')"
else
  TAG="${VERSION}"
fi
[ -n "${TAG}" ] || { echo "ERROR: could not resolve openvscode-server version" >&2; exit 1; }

# Map Docker's arch to the release asset suffix. The CI workflow builds
# linux/amd64,linux/arm64 just like the other images, so both must resolve.
case "$(uname -m)" in
  x86_64)  ARCH=x64 ;;
  aarch64) ARCH=arm64 ;;
  *) echo "ERROR: unsupported arch $(uname -m)" >&2; exit 1 ;;
esac

NAME="openvscode-server-v${TAG}-linux-${ARCH}"
URL="https://github.com/gitpod-io/openvscode-server/releases/download/openvscode-server-v${TAG}/${NAME}.tar.gz"
echo "Installing ${NAME}"

mkdir -p /opt
curl -fsSL "${URL}" | tar -xz -C /opt
mv "/opt/${NAME}" /opt/openvscode-server
ln -sf /opt/openvscode-server/bin/openvscode-server /usr/local/bin/openvscode-server

# Fail the build loudly if the binary doesn't run on this arch, rather than
# shipping an image whose "VS Code" tile dies at spawn time.
openvscode-server --version

# The base CPU image already installed Anthropic.claude-code into the shared
# extensions dir that jupyter-vscode-proxy passes via --extensions-dir
# (${CODE_EXTENSIONSDIR}). openvscode-server reads that same dir with the same
# standard VSIX layout, so the Claude extension is inherited — no reinstall here
# (avoids a marketplace round-trip in CI). Confirm it's present so a missing
# extension surfaces at build time, not when a user opens the panel on a tablet.
EXT_DIR="${CODE_EXTENSIONSDIR:-/opt/share/code-server}"
ls "${EXT_DIR}" | grep -qi 'anthropic.claude-code' \
  || { echo "ERROR: Anthropic.claude-code not found in ${EXT_DIR}" >&2; \
       ls -la "${EXT_DIR}" 2>&1 || true; exit 1; }
