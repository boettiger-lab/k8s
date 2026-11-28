# Pod memory

Shows this container's memory use and limit in the VS Code status bar, e.g.
`3.1 / 16.0 GiB`. Turns yellow at 80% of the limit and red at 90%.

Numbers come from the container's cgroup, not `/proc/meminfo` (which inside a
pod describes the whole node): used = `memory.current - inactive_file`, the
working set kubelet and `kubectl top` report, and limit = `memory.max`. This is
the same figure the JupyterLab indicator shows, and it includes everything in
the pod: tmux sessions, background jobs and other terminals.

Click it to list the processes using the most memory.
