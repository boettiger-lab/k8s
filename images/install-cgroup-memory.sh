#!/usr/bin/env bash
set -euo pipefail

# Server extension that makes the JupyterLab memory indicator report the
# container's cgroup working set instead of only the Jupyter server's process
# tree (see cgroup_memory_usage.py for why). Installed as a plain module next to
# jupyter_resource_usage and enabled through a conf.d JSON file, so rocker's
# /etc/jupyter/jupyter_server_config.py is left untouched.
NB_USER=${NB_USER:-jovyan}
SRC=${1:-/tmp/cgroup_memory_usage.py}

SITE=$(/opt/venv/bin/python -c "import jupyter_resource_usage, os; print(os.path.dirname(os.path.dirname(jupyter_resource_usage.__file__)))")
install -m 0644 "${SRC}" "${SITE}/cgroup_memory_usage.py"

CONF_D=/opt/venv/etc/jupyter/jupyter_server_config.d
install -d "${CONF_D}"
cat > "${CONF_D}/cgroup_memory_usage.json" <<'JSON'
{"ServerApp": {"jpserver_extensions": {"cgroup_memory_usage": true}}}
JSON

chown "${NB_USER}:${NB_USER}" "${SITE}/cgroup_memory_usage.py" "${CONF_D}/cgroup_memory_usage.json"

/opt/venv/bin/jupyter server extension list 2>&1 | grep -q "cgroup_memory_usage.*OK" \
  || { echo "ERROR: cgroup_memory_usage server extension did not load" >&2; exit 1; }
