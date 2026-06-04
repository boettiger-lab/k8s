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
# jupyter-ai-acp-bridge is our PoC fork that adds a Zed-style per-chat
# harness toolbar (model picker, mode picker, config toggles, slash-command
# autocomplete) to the new-chat dialog and supersedes the legacy `@Claude` /
# `@OpenCode` personas. It depends on (but does not fork) the upstream
# jupyter_ai_acp_client / persona_manager packages that jupyter-ai>=3 already
# provides. Not on PyPI; installed from cboettig/jupyter-ai. The build hook
# runs jlpm to bundle the JupyterLab extension, which is why Node must be
# installed above this step.
#
# Pinned to a commit SHA rather than the acp-bridge-impl branch tip so the
# weekly no-cache image rebuild is reproducible — bump this when the bridge
# lands new work.
JUPYTER_AI_ACP_BRIDGE_REF="f653dbef872e14a5ea9e8952461579f22126b164"
/opt/venv/bin/pip install --no-cache-dir \
  "jupyter-ai>=3,<4" \
  "jupyter-ai-acp-bridge @ git+https://github.com/cboettig/jupyter-ai.git@${JUPYTER_AI_ACP_BRIDGE_REF}#subdirectory=jupyter-ai-acp-bridge" \
  "jupyter-geoagent @ git+https://github.com/boettiger-lab/jupyter-geoagent.git@main"

# Fail the build loudly if the bridge labextension didn't compile/ship,
# rather than shipping an image where the toolbar silently never appears.
# Gate on the prebuilt federated-extension artifact on disk rather than
# `jupyter labextension list`: the first post-install invocation of that
# command races (it triggers extension discovery and reports the extension
# as not-yet-enabled, self-healing on a second call), which gives false
# negatives under the slower multi-arch CI build. The artifact's presence is
# deterministic and is what actually makes the toolbar load at runtime.
BRIDGE_LABEXT="/opt/venv/share/jupyter/labextensions/@jupyter-ai/acp-bridge"
test -f "${BRIDGE_LABEXT}/package.json" \
  || { echo "ERROR: @jupyter-ai/acp-bridge labextension artifact missing at ${BRIDGE_LABEXT}" >&2; \
       ls -la "$(dirname "${BRIDGE_LABEXT}")" 2>&1 || true; exit 1; }
