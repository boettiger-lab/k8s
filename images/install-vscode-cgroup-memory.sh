#!/usr/bin/env bash
set -euo pipefail

# Package images/vscode-cgroup-memory (a status bar indicator of the pod's
# cgroup memory use and limit) and install it into the shared code-server
# extensions dir, as install-themes.sh does for Nord. Node comes from
# install-jupyter-ai.sh, which must run first.
NB_USER=${NB_USER:-jovyan}
SRC=${1:-/tmp/vscode-cgroup-memory}
VSCE_VERSION=4.1.0

BUILD=$(mktemp -d)
cp -r "${SRC}/." "${BUILD}/"
(cd "${BUILD}" && npm_config_cache="${BUILD}/.npm-cache" \
   npx --yes "@vscode/vsce@${VSCE_VERSION}" package --skip-license --out cgroup-memory.vsix)
chmod -R a+rX "${BUILD}"

# code-server 4.x does not support --allow-root.
sudo -u "${NB_USER}" code-server --extensions-dir "${CODE_EXTENSIONSDIR}" \
  --install-extension "${BUILD}/cgroup-memory.vsix"
rm -rf "${BUILD}"

test -f "${CODE_EXTENSIONSDIR}"/boettiger-lab.cgroup-memory-*/extension.js \
  || { echo "ERROR: cgroup-memory extension missing from ${CODE_EXTENSIONSDIR}" >&2; exit 1; }
