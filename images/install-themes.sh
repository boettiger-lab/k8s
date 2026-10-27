#!/usr/bin/env bash
set -euo pipefail

# Nord color theme for JupyterLab and VS Code (code-server). This only installs
# the themes; each user still picks Nord in the theme menu, so the default look
# of both editors is unchanged.
NB_USER=${NB_USER:-jovyan}

# JupyterLab: prebuilt labextension wheel (JupyterLab 4), no Node build step.
/opt/venv/bin/pip install --no-cache-dir jupyterlab-nord-theme

# Gate on the labextension artifact on disk, as install-jupyter-ai.sh does,
# rather than on `jupyter labextension list`, which can race after an install.
LABEXT_DIR="/opt/venv/share/jupyter/labextensions"
test -f "${LABEXT_DIR}/jupyterlab-nord-theme/package.json" \
  || { echo "ERROR: jupyterlab-nord-theme labextension missing at ${LABEXT_DIR}" >&2; exit 1; }

# pip ran as root; hand the new files back to the notebook user like the rest of /opt/venv.
chown -R "${NB_USER}:${NB_USER}" \
  "${LABEXT_DIR}/jupyterlab-nord-theme" \
  /opt/venv/lib/python*/site-packages/jupyterlab_nord_theme*

# VS Code: the Nord extension from Open VSX, into the shared extensions dir that
# jupyter-vscode-proxy passes via --extensions-dir. Must run as NB_USER:
# code-server 4.x does not support --allow-root.
sudo -u "${NB_USER}" code-server --extensions-dir "${CODE_EXTENSIONSDIR}" \
  --install-extension arcticicestudio.nord-visual-studio-code
