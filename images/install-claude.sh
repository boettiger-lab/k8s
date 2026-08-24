#!/usr/bin/env bash
set -euo pipefail

# Install Claude Code CLI. The installer drops a versioned binary tree
# under $HOME/.local/share/claude/versions/<ver>/ and a symlink at
# $HOME/.local/bin/claude pointing to it. Moving just the symlink and
# deleting the share dir leaves a dangling link, so move the whole tree
# to /opt/claude and retarget the /usr/local/bin/claude symlink.
curl -fsSL https://claude.ai/install.sh | bash && \
  CLAUDE_TARGET="$(readlink "${HOME}/.local/bin/claude")" && \
  mv "${HOME}/.local/share/claude" /opt/claude && \
  ln -sf "${CLAUDE_TARGET/${HOME}\/.local\/share\/claude/\/opt\/claude}" /usr/local/bin/claude && \
  rm -rf "${HOME}/.local"

# claude VSCode extension is available on Open VSX as Anthropic.claude-code
# Must run as NB_USER: code-server 4.x does not support --allow-root
sudo -u ${NB_USER:-jovyan} code-server --extensions-dir ${CODE_EXTENSIONSDIR} --install-extension Anthropic.claude-code
