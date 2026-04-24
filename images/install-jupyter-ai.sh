#!/usr/bin/env bash
set -euo pipefail

# Node.js + npm are needed for @zed-industries/claude-agent-acp, the ACP
# bridge that jupyter-ai spawns when the user @mentions @Claude in the
# chat panel. OpenCode ships its own standalone binary, already installed
# to /usr/local/bin/opencode by the base image.
apt-get update
apt-get install -y --no-install-recommends nodejs npm
rm -rf /var/lib/apt/lists/*

# Claude ACP bridge — installs a `claude-agent-acp` binary onto PATH.
npm install -g @zed-industries/claude-agent-acp
npm cache clean --force

# jupyter-ai v3 pulls in jupyter-ai-acp-client, jupyter-ai-chat-commands,
# and jupyter-ai-persona-manager, which register the Claude / OpenCode /
# Goose personas automatically. jupyter-geoagent (this lab) registers
# the GeoAgent Map launcher tile plus `geoagent:*` JupyterLab commands
# so the LLM personas can drive the map directly from chat.
/opt/venv/bin/pip install --no-cache-dir \
  "jupyter-ai>=3,<4" \
  "jupyter-geoagent @ git+https://github.com/boettiger-lab/jupyter-geoagent.git@main"
