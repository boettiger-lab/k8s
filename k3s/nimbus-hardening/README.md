# nimbus hardening — surviving a runaway GPU pod

Node-level guards added after nimbus (DGX Spark, GB10) was wedged twice by a
vLLM deployment on 2026-08-24 and needed a physical power cycle both times.

## What actually happened

`vllm/nimbus/deploy-qwen38.yaml` served `unsloth/Qwen3.8-27B-NVFP4` with
`--gpu-memory-utilization 0.75` and `--max-num-seqs 8`. On a GB10 there is no
discrete VRAM — that is 0.75 of the *same* 121.69 GiB pool the host OS, k3s,
prometheus, jupyterhub and every other pod live in. It left about 30 GiB for
everything else.

The box did not die of a clean OOM kill. It died of a driver deadlock. From the
previous boot's journal:

```
INFO: task NvmlTaskRunner:11290 blocked for more than 368 seconds.
INFO: task NvmlTaskRunner:11290 <reader> blocked on an rw-semaphore likely owned by task VLLM::EngineCor:46249 <writer>
INFO: task gpu-feature-dis:13672 <writer> blocked on an rw-semaphore likely owned by task VLLM::EngineCor:46249 <writer>
INFO: task nvidia-smi:49301 <writer> blocked on an rw-semaphore likely owned by task VLLM::EngineCor:46249 <writer>
```

Under unified-memory pressure `VLLM::EngineCore` took the NVIDIA driver's
rw-semaphore and never gave it back. Every NVML consumer — `nvidia-smi`,
`dcgm-exporter`, `gpu-feature-discovery` — piled up behind it in uninterruptible
D-state. **The kernel stayed alive throughout**, which is why nothing recovered
on its own: there was no panic, no OOM kill, and the hardware watchdog had
nothing to notice.

### Where the memory actually went

The `shared` column is the tell. When vLLM was killed:

| | during vLLM | after kill |
|---|---|---|
| `shared` | **33 GiB** | **10 MiB** |
| `buff/cache` | 61 GiB | **30 GiB** |

`/dev/shm` was empty throughout (the `dshm` emptyDir is 1 GiB and only carries
torch IPC), so that 33 GiB of "shared" *was* the CUDA allocation — on GB10,
GPU memory maps as shared pages. That is the direct confirmation that
`--gpu-memory-utilization` spends host-visible RAM.

The second row is the part that is easy to miss: **the weights are resident
twice.** `hf-cache` is a `hostPath` to `/home/cboettig/.cache/huggingface`, and
`--load-format fastsafetensors` reads the 22 GiB checkpoint through the host page
cache — the same physical pool the GPU allocation comes from. So the real
steady-state budget was:

```
  91 GiB  vLLM CUDA reservation (0.75 x 121.69)
+ 22 GiB  page-cache copy of the same weights
= 113 GiB of 121.69
```

leaving ~8 GiB — not the ~30 GiB the utilization figure implies — for k3s, ~25
system pods, prometheus, jupyterhub, and the GNOME desktop session also running
on this host. On a discrete-VRAM machine that page cache is free real estate.
Here it is charged twice against one pool.

That page cache is clean and reclaimable, so it is not *waste* in the leak sense
— the kernel may drop all 22 GiB instantly. The problem is that it never got the
chance, which is the next section.

### Why the OOM killer never fired

**Zero kernel OOM events in the crash boot.** Not "the OOM killer picked the
wrong victim" — it never ran at all. Four things stack up:

1. **`vm.overcommit_memory = 1`** ("never refuse"). Every allocation succeeds
   regardless of what is left, so failure is deferred from allocation time to
   *fault* time — deep inside the page fault path, where the driver holds locks.
2. **`vm.min_free_kbytes = 45167`** — a 44 MiB reserve on a 121 GiB machine,
   with `watermark_scale_factor = 10` (0.1%). vLLM allocates in GiB-sized steps,
   so it blows past the watermark between kswapd wakeups and lands in *direct*
   reclaim: synchronous reclaim inside the faulting task.
3. **143 GiB of swap** kept the OOM killer asleep. It fires only when reclaim
   *and* swap both fail to progress. CUDA pages are unswappable, so the kernel
   dutifully swapped out everything *else* and thrashed, never reaching the OOM
   condition. Oversized swap did not protect this box; it disabled the one
   mechanism that would have. (See `resize-swap.sh`.)
4. **The deadlock closed the loop.** The task in direct reclaim *was*
   `VLLM::EngineCore`, holding the driver's rw-semaphore. Every other CUDA/NVML
   caller queued behind it in uninterruptible D-state — exactly what the log
   above shows. D-state tasks cannot be killed: SIGKILL, Ctrl-C and the OOM
   killer are all no-ops against them. Even had OOM fired and correctly chosen
   vLLM, it could not have reaped it.

That is the difference between "out of memory" and "hung box": nothing was ever
refused, so nothing was ever killed. The machine ran out of runway inside a lock.

### Two things worth knowing

**1. The cgroup memory limit was never going to save us.** As documented in
`vllm/nimbus/dgx-spark-memory.md`, CUDA allocations are not tracked by the cgroup
memory controller on unified memory. `memory: 96Gi` in the pod spec is scheduler
accounting only. The single effective control on vLLM's footprint is
`--gpu-memory-utilization`.

**2. `systemctl stop k3s` does not stop your pods.** The k3s unit ships with:

```
KillMode=process
Delegate=yes
```

`KillMode=process` kills only the main k3s process, leaving every
`containerd-shim-runc-v2` — and therefore every container — running as an
orphan. This is deliberate: it means a k3s restart or upgrade does not disrupt
running workloads. The journal says so explicitly:

```
k3s.service: Unit process 33727 (containerd-shim) remains running after unit stopped.
```

So stopping k3s during the incident detached vLLM from its supervisor without
releasing a single byte of GPU memory. To actually tear workloads down:

```bash
sudo /usr/local/bin/k3s-killall.sh   # stops k3s AND every pod
```

## The fix, in three parts

### Part 1 — the manifest (already applied)

`vllm/nimbus/deploy-qwen38.yaml`:

| setting | before | after |
|---|---|---|
| `--gpu-memory-utilization` | 0.75 (~91 GiB) | **0.55** (advisory only — see below) |
| `--kv-cache-memory-bytes` | *(unset)* | **42949672960 (40 GiB)** |
| `--max-num-seqs` | 8 | **4** |
| `memory` request/limit | 96Gi | **72Gi** |
| `--max-model-len` | 262144 | **262144 (unchanged)** |

Full 262144 context is preserved. The KV cache for this checkpoint is far
cheaper than it looks, because `config.json` shows only every 4th layer is
`full_attention` — 16 of 64. The other 48 are Gated-DeltaNet linear attention,
whose state is constant per sequence rather than proportional to context length:

```
2 (K+V) x 4 kv_heads x 256 head_dim x 1 B (fp8) =  2 KiB / token / full layer
                                x 16 full layers = 32 KiB / token
                                  x 262144 tokens =  8 GiB / sequence
```

So the old `0.75` + `max-num-seqs 8` was budgeting 64 GiB of KV plus 22 GiB of
weights — about 91 GiB, exactly what it reserved. At `0.55` with `max-num-seqs 4`
the worst case is 32 GiB KV + 22 GiB weights + ~3 GiB activations ≈ 57 GiB,
leaving ~55 GiB of the pool for the rest of the machine. **We bought safety with
concurrency, not context length.**

#### `--gpu-memory-utilization` is advisory, not a cap

The first attempt at this fix set `0.55` and nothing else. It made things
**worse** — 97.7 GiB RSS, node down to 2.2 GiB available. vLLM's profiler took
all remaining free memory rather than `0.55 x 121.69`:

```
expected budget                    0.55 x 121.69 = 66.9 GiB
free memory just before KV alloc                 = 73    GiB
vLLM: "Available KV cache memory:                  73.24 GiB"   <- took all of it
```

The working control is the absolute cap `--kv-cache-memory-bytes`, which
bypasses the profiler. Size it from a *measured* run: 73.24 GiB held 2,066,397
tokens = **38,057 B/token** for this checkpoint. See the CORRECTION section of
`vllm/nimbus/dgx-spark-memory.md`.

Verified after redeploy — prediction vs. reality:

| | predicted | measured |
|---|---|---|
| KV cache tokens | ~1,128,000 | **1,129,123** |
| max concurrency @ 262144 | ~4.3x | **4.31x** |
| vLLM total footprint | ~64.5 GiB | **64.5 GiB** (66,047 MiB) |
| node MemAvailable, steady state | ~36 GiB | **36 GiB** |

**One caveat worth knowing:** during CUDA graph capture the node briefly dipped
to ~4 GiB available before settling at 36 GiB. That transient is expected and is
why the watchdog requires *three consecutive* sub-threshold samples before
acting — a single spike during a cold start must not trigger a kill. If you
lower `KILL_AFTER`, you will start killing healthy startups.

### Part 2 — the node (run `harden-nimbus.sh`)

```bash
sudo ./harden-nimbus.sh
sudo systemctl restart k3s     # to pick up the eviction thresholds
```

Four independent layers, so no single one has to be perfect:

| # | layer | catches | recovery |
|---|---|---|---|
| 1 | `gpu-hang-watchdog.timer` | `nvidia-smi` hanging, or MemAvailable < 8 GiB | kills vLLM after 3 min, force-reboots after 6 |
| 2 | systemd hardware watchdog | a true kernel hang | board self-resets after 60 s |
| 3 | k3s eviction thresholds | scheduler overcommit | kubelet evicts before the pool is gone |
| 4 | `kernel.sysrq = 1` | — | lets layer 1's reboot path work when the clean one is blocked |
| 5 | `99-nimbus-vm.conf` | late reclaim | kswapd wakes at 2 GiB free instead of 44 MiB |

**Layer 1 is the one that matters for this specific failure.** Layer 2 would not
have helped on 2026-08-24, because the kernel never stopped responding — only the
GPU did. The watchdog polls `nvidia-smi` under a 20 s timeout and requires three
consecutive failures before acting, so a slow model load (which legitimately
takes minutes) is never killed. Its escalation is deliberately narrow: **it only
ever kills vLLM**, never a user's Jupyter session or another team's pod.

To keep the kill escalation but never let it reboot the node, set
`Environment=ALLOW_REBOOT=0` in `gpu-hang-watchdog.service`.

### Part 3 — swap (run `resize-swap.sh`)

```bash
sudo ./resize-swap.sh     # read it first; it deletes a 128 GiB file
```

nimbus had **143 GiB of swap on a 121 GiB machine** — `/swap.img` (16 GiB,
Ubuntu default) plus `/swapfile128` (128 GiB, created 2025-12-15, no recorded
rationale). As reason 3 above explains, that much free swap makes the OOM
killer's trigger condition effectively unreachable. This script drops the
128 GiB file and keeps the 16 GiB default, which still cushions genuine cold
anonymous pages and Jupyter bursts at a ratio where OOM can actually fire.

Verified safe before writing it: hibernation is **not** available on this host
(`/sys/power/disk` is empty, no `resume=` on the kernel cmdline), so no
swap>=RAM requirement applies. The script re-checks this at runtime and refuses
to proceed if hibernation has since been configured, or if `swapoff` would need
to fault in more than it can fit in RAM.

### A note on the duplicated weights

There is no deployment-level fix for the 22 GiB page-cache copy, and that is
fine. Any loader that reads the checkpoint through the `hostPath` mount
populates the page cache — `--load-format fastsafetensors` is not the culprit,
it just makes the load fast. The copy is clean and reclaimable; the correct
answer is to make sure the kernel reclaims it in time (Part 2, layer 5) rather
than to fight the loader.

What *did* change is the budgeting. At `--gpu-memory-utilization 0.55` the
reservation is ~67 GiB, so even with the full 22 GiB page-cache copy resident
the total is ~89 GiB of 121.69 — about 32 GiB of genuine headroom, versus the
~8 GiB the old 0.75 config actually had. The watchdog also now drops clean page
cache as its first escalation rung, so this memory is reclaimed *before*
anything gets killed.

## Verifying

```bash
systemctl list-timers gpu-hang-watchdog.timer
journalctl -u gpu-hang-watchdog.service -f
sudo systemctl show -p RuntimeWatchdogUSec        # expect 1min
kubectl describe node | grep -A6 'Allocated resources'
```

Dry-run the watchdog's logic without arming the escalation:

```bash
sudo ALLOW_REBOOT=0 /usr/local/bin/gpu-hang-watchdog.sh
```

## Files

| file | installs to |
|---|---|
| `gpu-hang-watchdog.sh` | `/usr/local/bin/gpu-hang-watchdog.sh` |
| `gpu-hang-watchdog.service` | `/etc/systemd/system/` |
| `gpu-hang-watchdog.timer` | `/etc/systemd/system/` |
| `k3s-config.yaml` | `/etc/rancher/k3s/config.yaml` (backed up first) |
| `99-nimbus-vm.conf` | `/etc/sysctl.d/99-nimbus-vm.conf` |
| `harden-nimbus.sh` | — (installer, layers 1-5) |
| `resize-swap.sh` | — (separate, destructive: deletes the 128 GiB swapfile) |

## See also

- `vllm/nimbus/dgx-spark-memory.md` — why cgroup limits don't bound CUDA on unified memory
- `vllm/nimbus/deploy-qwen38.yaml` — the patched manifest, with the KV arithmetic inline
