// Status bar memory indicator for the container's cgroup. See README.md.
const vscode = require("vscode");
const fs = require("fs/promises");
const { execFile } = require("child_process");

const V2 = "/sys/fs/cgroup";
const V1 = "/sys/fs/cgroup/memory";
const POLL_MS = 2000;

async function readNumber(path) {
  const s = (await fs.readFile(path, "utf8")).trim();
  return /^\d+$/.test(s) ? Number(s) : null; // "max" (v2 unlimited) -> null
}

async function statValue(path, key) {
  const text = await fs.readFile(path, "utf8");
  for (const line of text.split("\n")) {
    const [k, v] = line.split(" ");
    if (k === key) return Number(v);
  }
  return 0;
}

// { used, current, inactive, limit } in bytes; limit null when unlimited.
async function sample() {
  try {
    const current = await readNumber(`${V2}/memory.current`);
    if (current === null) throw new Error("no v2");
    const inactive = await statValue(`${V2}/memory.stat`, "inactive_file");
    const limit = await readNumber(`${V2}/memory.max`);
    return { used: Math.max(current - inactive, 0), current, inactive, limit };
  } catch (_) {
    const current = await readNumber(`${V1}/memory.usage_in_bytes`);
    const inactive = await statValue(`${V1}/memory.stat`, "total_inactive_file");
    let limit = await readNumber(`${V1}/memory.limit_in_bytes`);
    if (limit !== null && limit >= 2 ** 62) limit = null; // v1 "unlimited"
    return { used: Math.max(current - inactive, 0), current, inactive, limit };
  }
}

const GiB = 1024 ** 3;
const fmt = (b) => (b / GiB).toFixed(1);

function activate(context) {
  const item = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 100);
  item.command = "cgroupMemory.showTop";
  context.subscriptions.push(item);

  const output = vscode.window.createOutputChannel("Pod memory");
  context.subscriptions.push(output);

  context.subscriptions.push(
    vscode.commands.registerCommand("cgroupMemory.showTop", () => {
      execFile("ps", ["-eo", "rss,pid,etime,args", "--sort=-rss"], (err, stdout) => {
        output.clear();
        if (err) {
          output.appendLine(`ps failed: ${err.message}`);
        } else {
          const lines = stdout.trimEnd().split("\n");
          output.appendLine("   MiB     PID     ELAPSED COMMAND");
          for (const line of lines.slice(1, 21)) {
            const m = line.trim().match(/^(\d+)\s+(.*)$/);
            if (m) output.appendLine(`${(Number(m[1]) / 1024).toFixed(0).padStart(6)} ${m[2].slice(0, 200)}`);
          }
        }
        output.show(true);
      });
    })
  );

  let failures = 0;
  async function update() {
    let s;
    try {
      s = await sample();
      failures = 0;
    } catch (_) {
      if (++failures >= 3) item.hide(); // not in a readable cgroup: stay out of the way
      return;
    }
    const frac = s.limit ? s.used / s.limit : 0;
    item.text = s.limit
      ? `$(pulse) ${fmt(s.used)} / ${fmt(s.limit)} GiB`
      : `$(pulse) ${fmt(s.used)} GiB`;
    item.backgroundColor =
      frac >= 0.9 ? new vscode.ThemeColor("statusBarItem.errorBackground")
      : frac >= 0.8 ? new vscode.ThemeColor("statusBarItem.warningBackground")
      : undefined;
    const tip = new vscode.MarkdownString(
      `**Pod memory** (whole container, from its cgroup)\n\n` +
      `| | GiB |\n|---|---:|\n` +
      `| in use (working set) | ${fmt(s.used)} |\n` +
      `| limit | ${s.limit ? fmt(s.limit) : "none"} |\n` +
      `| reclaimable file cache | ${fmt(s.inactive)} |\n\n` +
      `The pod is OOM-killed when it reaches the limit. Click to list top processes.`
    );
    item.tooltip = tip;
    item.show();
  }

  update();
  const timer = setInterval(update, POLL_MS);
  context.subscriptions.push({ dispose: () => clearInterval(timer) });
}

function deactivate() {}

module.exports = { activate, deactivate };
