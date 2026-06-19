#!/usr/bin/env bash
set -euo pipefail

# Node.js (with bundled npm) is needed for two things here: the
# @zed-industries/claude-agent-acp binary (the Claude Code ACP agent that
# jupyter-sidekick drives), and building jupyter-geoagent's JupyterLab extension
# frontend from source via jlpm. OpenCode ships its own standalone binary,
# already on PATH at /usr/local/bin/opencode in the base image.
#
# Ubuntu 24.04's apt ships Node 18, but the ACP agent uses ESM import
# attributes (`with { type: "json" }`) which require Node >= 20, so pull
# Node 22 LTS from NodeSource instead.
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y --no-install-recommends nodejs
rm -rf /var/lib/apt/lists/*

# Claude ACP agent — installs a `claude-agent-acp` binary onto PATH.
npm install -g @zed-industries/claude-agent-acp
npm cache clean --force

# jupyter-sidekick (SchmidtDSE) provides Jupyter-native, per-chat access to
# coding agents over the Agent Client Protocol — Claude Code, OpenCode, Goose,
# Gemini, etc. It is standalone (no jupyter_ai_* dependency), keeps agent
# selection separate from model choice, edits the open .ipynb directly, and
# discovers agents from the shared ACP Agent Registry rather than a hard-coded
# list. Shipped as a prebuilt wheel on PyPI, so it needs no Node build step.
# https://github.com/SchmidtDSE/jupyter-sidekick
#
# jupyter-geoagent (this lab) registers the GeoAgent Map launcher tile plus
# `geoagent:*` JupyterLab commands so agents can drive the map from chat. It is
# installed from git and builds its frontend via jlpm, which is why Node must
# be installed above this step.
/opt/venv/bin/pip install --no-cache-dir \
  jupyter-sidekick \
  "jupyter-geoagent @ git+https://github.com/boettiger-lab/jupyter-geoagent.git@main"

# Fail the build loudly if either prebuilt labextension didn't ship, rather
# than shipping an image where the chat panel or map launcher silently never
# appears. Gate on the federated-extension artifact on disk (deterministic)
# rather than `jupyter labextension list`, whose first post-install invocation
# races (it triggers extension discovery and can report an extension as
# not-yet-enabled, self-healing on a second call) and gives false negatives
# under the slower multi-arch CI build.
LABEXT_DIR="/opt/venv/share/jupyter/labextensions"
for ext in "jupyter-sidekick" "@geojupyter/jupyter-geoagent"; do
  test -f "${LABEXT_DIR}/${ext}/package.json" \
    || { echo "ERROR: ${ext} labextension artifact missing at ${LABEXT_DIR}/${ext}" >&2; \
         ls -la "${LABEXT_DIR}" 2>&1 || true; exit 1; }
done
