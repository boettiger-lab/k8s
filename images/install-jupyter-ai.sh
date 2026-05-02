#!/usr/bin/env bash
set -euo pipefail

# Node.js (with bundled npm) is needed for @zed-industries/claude-agent-acp,
# the ACP bridge that jupyter-ai spawns when the user @mentions @Claude in
# the chat panel. OpenCode ships its own standalone binary, already installed
# to /usr/local/bin/opencode by the base image.
#
# Ubuntu 24.04's apt ships Node 18, but the ACP bridge uses ESM import
# attributes (`with { type: "json" }`) which require Node >= 20, so pull
# Node 22 LTS from NodeSource instead.
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y --no-install-recommends nodejs
rm -rf /var/lib/apt/lists/*

# Claude ACP bridge — installs a `claude-agent-acp` binary onto PATH.
npm install -g @zed-industries/claude-agent-acp
npm cache clean --force

# jupyter-ai v3 pulls in jupyter-ai-acp-client, jupyter-ai-chat-commands,
# and jupyter-ai-persona-manager, which register the Claude / OpenCode /
# Goose personas automatically. jupyter-geoagent (this lab) registers
# the GeoAgent Map launcher tile plus `geoagent:*` JupyterLab commands
# so the LLM personas can drive the map directly from chat.
#
# jupyter-ai-acp-bridge is our PoC fork that adds a Zed-style per-thread
# harness selector to the new-chat dialog and supersedes the legacy
# `@Claude` / `@OpenCode` personas. Not on PyPI; installed from the
# acp-bridge-impl branch of cboettig/jupyter-ai. The build hook runs
# jlpm to bundle the JupyterLab extension, which is why Node must be
# installed above this step.
/opt/venv/bin/pip install --no-cache-dir \
  "jupyter-ai>=3,<4" \
  "jupyter-ai-acp-bridge @ git+https://github.com/cboettig/jupyter-ai.git@acp-bridge-impl#subdirectory=jupyter-ai-acp-bridge" \
  "jupyter-geoagent @ git+https://github.com/boettiger-lab/jupyter-geoagent.git@main"
