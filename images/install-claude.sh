#!/usr/bin/env bash
set -euo pipefail

# Install the Claude Code CLI so that it can keep itself up to date at runtime
# without putting a quarter-gigabyte binary tree inside $HOME.
#
# The native installer uses exactly two locations, and only one of them can be
# moved:
#
#   * the versioned binary tree, $XDG_DATA_HOME/claude/versions/<version>
#     (XDG_DATA_HOME defaults to $HOME/.local/share) — ~250 MB per version
#   * the launcher symlink, $HOME/.local/bin/claude — hardcoded to $HOME, with
#     no environment variable to relocate it
#
# So the tree goes to /opt (out from under the PVC that JupyterHub mounts over
# $HOME) via XDG_DATA_HOME, and the launcher stays where claude insists on
# having it. XDG_DATA_HOME is exported only for claude, by the
# /usr/local/bin/claude wrapper written below: setting it image-wide would also
# move jupyter's data dir off the PVC, which is why these images stopped
# setting it in the first place. As a backstop for invocations that bypass the
# wrapper, ~/.local/share/claude/versions is also symlinked into /opt, so the
# default location resolves to the same tree with no environment variable set.
#
# The previous approach — move the tree to /opt behind claude's back, retarget
# /usr/local/bin/claude, and `rm -rf $HOME/.local` — left an installation that
# claude could not manage. It warned "claude command at
# /home/jovyan/.local/bin/claude missing or broken" on every start, and
# auto-update refused to touch a launcher it had not created ("the updater will
# not overwrite a launcher it does not own"), so the only way to get a newer
# claude was an image rebuild: a container from a week-old image was stuck with
# a week-old model list.
CLAUDE_DATA_HOME=/opt/claude-data
NB_USER=${NB_USER:-jovyan}

# NB_USER-owned so the runtime user can install new versions here. Created and
# filled in this one layer — chowning it in a later layer would duplicate the
# whole 250 MB tree in a second image layer.
install -d -o "${NB_USER}" -g "${NB_USER}" -m 0755 "${CLAUDE_DATA_HOME}"
install -d -o "${NB_USER}" -g "${NB_USER}" -m 0755 "${HOME}/.local" "${HOME}/.local/bin"

# Run the installer as NB_USER so nothing it writes lands root-owned. It puts
# the binary under ${CLAUDE_DATA_HOME}/claude/versions/ and the launcher symlink
# at ${HOME}/.local/bin/claude, and defaults to the "latest" release channel.
sudo -u "${NB_USER}" env HOME="${HOME}" XDG_DATA_HOME="${CLAUDE_DATA_HOME}" \
  bash -c 'curl -fsSL https://claude.ai/install.sh | bash'

install -d -o "${NB_USER}" -g "${NB_USER}" -m 0755 "${HOME}/.local/share" "${HOME}/.local/share/claude"
ln -sfn "${CLAUDE_DATA_HOME}/claude/versions" "${HOME}/.local/share/claude/versions"
chown -h "${NB_USER}:${NB_USER}" "${HOME}/.local/share/claude/versions"

# PATH wrapper. Also the entry point for a plain `docker run`, where nothing is
# mounted over $HOME and the baked-in launcher is used as-is.
cat > /usr/local/bin/claude <<WRAPPER
#!/bin/sh
# Wrapper for the Claude Code CLI (written by images/install-claude.sh).
#
# 1. Points claude at the versioned binary tree in /opt. Exported here rather
#    than in the image environment because jupyter honours XDG_DATA_HOME too.
# 2. Recreates the two symlinks claude needs in \$HOME. On JupyterHub \$HOME is a
#    PVC mounted over /home/${NB_USER}, which hides the ones baked into the
#    image; without the launcher, claude reports its installation as "missing or
#    broken" and auto-update has no launcher to re-point.
XDG_DATA_HOME=\${CLAUDE_DATA_HOME:-${CLAUDE_DATA_HOME}}
export XDG_DATA_HOME
versions=\$XDG_DATA_HOME/claude/versions
launcher=\$HOME/.local/bin/claude

# The versions dir also holds lock and staging files, so match only x.y.z names
# and take the newest.
newest=\$(find "\$versions" -maxdepth 1 -type f -perm -u+x -printf '%f\n' 2>/dev/null |
  grep -E '^[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -n 1)

# Auto-update re-points the launcher itself, so only repair a missing or
# dangling one (-x follows the link).
if [ ! -x "\$launcher" ] && [ -n "\$newest" ]; then
  mkdir -p "\$HOME/.local/bin" 2>/dev/null &&
    ln -sfn "\$versions/\$newest" "\$launcher" 2>/dev/null || true
fi

# Backstop for anything that runs the launcher directly instead of going
# through this wrapper: make the default \$HOME/.local/share/claude/versions
# resolve to the same tree, so an update started that way still lands in /opt.
if [ ! -e "\$HOME/.local/share/claude/versions" ]; then
  mkdir -p "\$HOME/.local/share/claude" 2>/dev/null &&
    ln -sfn "\$versions" "\$HOME/.local/share/claude/versions" 2>/dev/null || true
fi

if [ -x "\$launcher" ]; then
  exec "\$launcher" "\$@"
fi

# \$HOME is unwritable: run the binary directly. claude still works, it just
# reports the missing launcher and cannot self-update.
exec "\$versions/\$newest" "\$@"
WRAPPER
chmod 0755 /usr/local/bin/claude

# claude VSCode extension is available on Open VSX as Anthropic.claude-code
# Must run as NB_USER: code-server 4.x does not support --allow-root
sudo -u ${NB_USER} code-server --extensions-dir ${CODE_EXTENSIONSDIR} --install-extension Anthropic.claude-code
