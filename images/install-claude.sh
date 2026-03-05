#!/usr/bin/env bash
set -euo pipefail

# Install Claude Code CLI (native installer, recommended for Linux)
curl -fsSL https://claude.ai/install.sh | bash

# claude VSCode extension is available on Open VSX as Anthropic.claude-code
# Must run as NB_USER: code-server 4.x does not support --allow-root
sudo -u ${NB_USER:-jovyan} code-server --extensions-dir ${CODE_EXTENSIONSDIR} --install-extension Anthropic.claude-code
