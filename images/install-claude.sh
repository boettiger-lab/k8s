#!/usr/bin/env bash
set -euo pipefail

# Install Claude Code CLI — installer hardcodes $HOME/.local/bin, so move to /usr/local/bin
curl -fsSL https://claude.ai/install.sh | bash && \
  mv "${HOME}/.local/bin/claude" /usr/local/bin/claude && \
  rm -rf "${HOME}/.local/share/claude" "${HOME}/.local/bin/claude"

# claude VSCode extension is available on Open VSX as Anthropic.claude-code
# Must run as NB_USER: code-server 4.x does not support --allow-root
sudo -u ${NB_USER:-jovyan} code-server --extensions-dir ${CODE_EXTENSIONSDIR} --install-extension Anthropic.claude-code
