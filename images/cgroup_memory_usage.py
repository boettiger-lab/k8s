"""Make the JupyterLab memory indicator report the whole container.

jupyter-resource-usage counts only the Jupyter server process and its
descendants. Anything that leaves that tree is invisible to it: a tmux server
re-parents to PID 1, and so do nohup/setsid jobs. Meanwhile the OOM killer acts
on the pod's cgroup. So the indicator could read ~800 MB while the pod was being
killed at its 16 GB limit.

This extension keeps the endpoint as it is and replaces only the "used" figure
with the cgroup working set: memory.current minus inactive_file, the number
kubelet and `kubectl top` report. The limit is read from the same cgroup
(memory.max), so it follows whichever RAM option the server was started with;
when the cgroup has no limit, the spawner's MEM_LIMIT is kept. If the cgroup
files cannot be read, the original figures are left in place.
"""
import json
import pathlib

CGROUP = pathlib.Path("/sys/fs/cgroup")


def working_set():
    """Container working set in bytes (cgroup v2, else v1), or None."""
    try:
        current = int((CGROUP / "memory.current").read_text())
        stat_file, inactive_key = CGROUP / "memory.stat", "inactive_file"
    except (OSError, ValueError):
        try:
            current = int((CGROUP / "memory/memory.usage_in_bytes").read_text())
            stat_file, inactive_key = CGROUP / "memory/memory.stat", "total_inactive_file"
        except (OSError, ValueError):
            return None
    inactive = 0
    try:
        for line in stat_file.read_text().splitlines():
            key, _, value = line.partition(" ")
            if key == inactive_key:
                inactive = int(value)
                break
    except (OSError, ValueError):
        pass
    return max(current - inactive, 0)


def cgroup_limit():
    """Container memory limit in bytes, or None when unlimited/unreadable."""
    for path in (CGROUP / "memory.max", CGROUP / "memory/memory.limit_in_bytes"):
        try:
            value = path.read_text().strip()
        except OSError:
            continue
        # cgroup v1 reports "no limit" as a huge page-aligned number.
        if value.isdigit() and int(value) < 1 << 62:
            return int(value)
        return None
    return None


def _patch():
    from jupyter_resource_usage.api import ApiHandler

    if getattr(ApiHandler.get, "_cgroup_patched", False):
        return
    original_get = ApiHandler.get

    async def get(self):
        original_write = self.write

        def write(chunk):
            try:
                metrics = json.loads(chunk)
                used = working_set()
                if used is not None:
                    metrics["rss"] = metrics["pss"] = used
                    config = self.settings["jupyter_resource_usage_display_config"]
                    memory = metrics.setdefault("limits", {}).setdefault("memory", {})
                    limit = cgroup_limit() or memory.get("rss")
                    if limit:
                        memory["rss"] = memory["pss"] = limit
                        if config.mem_warning_threshold:
                            memory["warn"] = (limit - used) < limit * config.mem_warning_threshold
                    chunk = json.dumps(metrics)
            except Exception:
                pass
            original_write(chunk)

        self.write = write
        await original_get(self)

    get._cgroup_patched = True
    ApiHandler.get = get


def _jupyter_server_extension_points():
    return [{"module": "cgroup_memory_usage"}]


def _load_jupyter_server_extension(serverapp):
    try:
        _patch()
        serverapp.log.info("cgroup_memory_usage: memory indicator reads the container cgroup")
    except Exception as e:
        serverapp.log.warning("cgroup_memory_usage: not applied (%s)", e)
