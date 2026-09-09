#!/bin/bash
# gpu-hang-watchdog.sh -- detect and recover from the DGX Spark GPU wedge.
#
# Failure signature we are recovering from (nimbus, 2026-08-24):
#   a vLLM pod over-reserves the GB10 unified memory pool, the NVIDIA driver
#   deadlocks on an rw-semaphore, and every NVML consumer piles up in
#   uninterruptible D-state:
#     INFO: task nvidia-smi:49301 blocked for more than 245 seconds.
#     <writer> blocked on an rw-semaphore likely owned by task VLLM::EngineCor
#   The kernel stays alive (so the systemd hardware watchdog never fires) but
#   the GPU is unusable and the box needs a physical power cycle.
#
# Two independent triggers, each requiring consecutive failures so that a slow
# model load (which legitimately takes minutes and lots of RAM) is not killed:
#   1. nvidia-smi hangs or errors                    -> GPU is wedged
#   2. MemAvailable low AND the kernel is in reclaim
#      distress (or memory is critically low)        -> heading for the wedge
#
# Escalation is deliberately narrow: it only ever kills vLLM. Jupyter sessions
# and other users' pods are never targeted.
#
# --- 2026-09-09: why trigger 2 now needs corroboration -----------------------
# Low MemAvailable alone is NOT evidence of danger, and acting on it killed a
# perfectly healthy model. Qwen3.8-Flash-Next serves its 48 GiB PLE n-gram table
# by mmap from NVMe (services/vllm/qwen38-flashnext-nimbus.yaml), so its decode
# path is *supposed* to hold a large, growing, file-backed mapping. MemAvailable
# discounts actively-mapped file pages, so it drifts down ~0.23 GiB/h as the
# model touches more of the table -- indistinguishable, to the old check, from
# an impending wedge. It tripped after 14h52m:
#
#   dropped clean page cache: MemAvailable 8038 -> 8125 MiB
#   MemAvailable 8122 MiB below 8192 MiB (consecutive: 3)
#   ESCALATION: killing vLLM (consecutive failures reached 3)
#
# Note the first line: the lossless rung recovered 87 MiB. It cannot do better,
# because MemAvailable *already counts* reclaimable page cache -- dropping it
# moves pages from Cached to MemFree, both already inside the metric. So the old
# ladder had no real step between "below threshold" and "SIGKILL the model",
# and gpu_fails stayed 0 throughout: the GPU was healthy the entire time.
#
# What actually preceded the 2026-08-24 wedge was *direct reclaim* -- from that
# incident writeup: "vLLM allocates in GiB-sized steps, so it blows past the
# watermark between kswapd wakeups and lands in direct reclaim: synchronous
# reclaim inside the faulting task", and that faulting task held the driver's
# rw-semaphore. Direct reclaim and swap thrashing are both counted in
# /proc/vmstat, so trigger 2 now measures the distress itself rather than
# inferring it from a headroom number.

set -uo pipefail

# Overridable so the escalation logic can be exercised against synthetic
# meminfo/vmstat without root and without a GPU -- see test-watchdog.sh. Only
# the two *read* paths are redirected; drop_caches and sysrq always use /proc.
PROC="${PROC:-/proc}"
# Also overridable for tests, so the lossless rung's success path is exercised
# rather than skipped on a permission error.
DROP_CACHES_PATH="${DROP_CACHES_PATH:-/proc/sys/vm/drop_caches}"
STATE_DIR="${STATE_DIR:-/run/gpu-hang-watchdog}"
GPU_FAILS="$STATE_DIR/gpu_fails"
MEM_FAILS="$STATE_DIR/mem_fails"
VMSTAT_PREV="$STATE_DIR/vmstat_prev"

SMI_TIMEOUT=20          # seconds to wait for nvidia-smi before calling it hung
MEM_MIN_KIB=$((8*1024*1024))     # 8 GiB: "worth watching", NOT on its own a kill
MEM_CRIT_KIB=$((1536*1024))      # 1.5 GiB: kill without waiting for corroboration.
                                 # The 2026-08-24 wedge bottomed out at 2.2 GiB.
# Reclaim distress, measured per tick (the timer runs every 60s). Both are page
# counts, so at 4 KiB/page: 51200 pages ~= 200 MiB/min of direct reclaim, and
# 12800 pages ~= 50 MiB/min of swap traffic. Steady-state mmap paging sits well
# under these; the numbers to calibrate against are logged every tick.
DIRECT_RECLAIM_PAGES=51200
SWAP_PAGES=12800
DROP_CACHES_AFTER=2     # consecutive DISTRESS samples before dropping page cache
KILL_AFTER=3            # consecutive failures before we kill vLLM
REBOOT_AFTER=6          # consecutive failures before we force a reboot
ALLOW_REBOOT="${ALLOW_REBOOT:-1}"   # set 0 to disable the reboot escalation

mkdir -p "$STATE_DIR"
read_count() { cat "$1" 2>/dev/null || echo 0; }
log() { echo "[gpu-hang-watchdog] $*"; }

drop_caches() {
    # Clean, file-backed page cache only -- nothing dirty is discarded, so this
    # is lossless for correctness. It is NOT free, though: on the Flash-Next
    # model this evicts the mmapped PLE table and the next pass over a cold
    # region reads from NVMe at 2-3x the latency. So it now runs only when there
    # is real distress, not merely because MemAvailable looks low.
    #
    # Expect little movement in MemAvailable -- that metric already counts
    # reclaimable cache. MemFree is the one that actually changes, which is why
    # both are logged.
    local before after fbefore fafter
    before=$(awk '/^MemAvailable:/ {print $2}' "$PROC/meminfo")
    fbefore=$(awk '/^MemFree:/ {print $2}' "$PROC/meminfo")
    sync
    if ! echo 1 > "$DROP_CACHES_PATH" 2>/dev/null; then
        log "could not drop caches (need root)"; return
    fi
    after=$(awk '/^MemAvailable:/ {print $2}' "$PROC/meminfo")
    fafter=$(awk '/^MemFree:/ {print $2}' "$PROC/meminfo")
    log "dropped clean page cache: MemAvailable $((before/1024)) -> $((after/1024)) MiB, MemFree $((fbefore/1024)) -> $((fafter/1024)) MiB"
}

kill_vllm() {
    log "ESCALATION: killing vLLM (consecutive failures reached $KILL_AFTER)"
    # SIGKILL directly -- a wedged EngineCore does not honour SIGTERM.
    pkill -9 -f 'VLLM::EngineCore' && log "killed VLLM::EngineCore"
    pkill -9 -f 'vllm serve'       && log "killed vllm serve"
}

force_reboot() {
    # Fire once. Without this the timer would stack a new sysrq sequence every
    # minute while the reboot is already in progress.
    [ -e "$STATE_DIR/rebooting" ] && { log "reboot already in progress"; return; }
    touch "$STATE_DIR/rebooting"
    log "ESCALATION: unrecoverable GPU wedge, forcing reboot"
    # Try the clean path first, but it will hang if systemd is blocked on the
    # driver, so give it a short window and then use magic sysrq. sysrq is a
    # kernel-side path that works even when userspace cannot be scheduled.
    systemctl --no-block reboot 2>/dev/null
    ( sleep 30
      log "clean reboot did not take, using magic sysrq"
      echo 1 > /proc/sys/kernel/sysrq
      echo s > /proc/sysrq-trigger    # sync filesystems
      sleep 5
      echo u > /proc/sysrq-trigger    # remount read-only
      sleep 5
      echo b > /proc/sysrq-trigger    # reboot immediately
    ) &
}

# -ge rather than -eq throughout: if the kill does not take (a D-state process
# cannot be reaped) we retry every tick instead of giving up after one attempt.

escalate_gpu() {
    local n=$1
    # No drop_caches rung here -- a wedged driver is not a memory shortage, and
    # dropping cache would not touch the semaphore that is actually stuck.
    if   [ "$n" -ge "$REBOOT_AFTER" ] && [ "$ALLOW_REBOOT" = 1 ]; then force_reboot
    elif [ "$n" -ge "$KILL_AFTER" ];                              then kill_vllm
    fi
}

escalate_mem() {
    local n=$1
    # Only ever reached when there is corroborated distress (or memory is
    # critically low), so the lossless rung is worth its cost here.
    if   [ "$n" -ge "$REBOOT_AFTER" ] && [ "$ALLOW_REBOOT" = 1 ]; then force_reboot
    elif [ "$n" -ge "$KILL_AFTER" ];                              then kill_vllm
    elif [ "$n" -ge "$DROP_CACHES_AFTER" ];                       then drop_caches
    fi
}

# --- is the kernel actually struggling to reclaim? --------------------------
# Deltas since the previous tick. pgscan_direct counts pages scanned in *direct*
# reclaim -- reclaim performed synchronously inside the faulting task, which is
# the state that had VLLM::EngineCore holding the driver rw-semaphore during the
# 2026-08-24 wedge. pswpin/pswpout catch the thrashing half of the same story.
# Steady mmap paging touches neither meaningfully.
#
# Must run every tick, whatever the memory level, or the deltas span arbitrary
# intervals and mean nothing.
DISTRESS_DESC="unknown"
vmstat_field() { awk -v k="$1" '$1==k {print $2; exit}' "$PROC/vmstat"; }

reclaim_distress() {
    local dr sw prev_dr prev_sw d_dr d_sw
    dr=$(vmstat_field pgscan_direct); dr=${dr:-0}
    sw=$(( $(vmstat_field pswpin) + $(vmstat_field pswpout) ))
    prev_dr=$dr; prev_sw=$sw
    [ -r "$VMSTAT_PREV" ] && read -r prev_dr prev_sw < "$VMSTAT_PREV"
    echo "$dr $sw" > "$VMSTAT_PREV"
    d_dr=$(( dr - prev_dr )); d_sw=$(( sw - prev_sw ))
    # Counters are monotonic but reset across reboots; never report a negative.
    [ "$d_dr" -lt 0 ] && d_dr=0
    [ "$d_sw" -lt 0 ] && d_sw=0
    DISTRESS_DESC="direct_reclaim=${d_dr}p/tick swap=${d_sw}p/tick"
    [ "$d_dr" -ge "$DIRECT_RECLAIM_PAGES" ] || [ "$d_sw" -ge "$SWAP_PAGES" ]
}

DISTRESS=0
reclaim_distress && DISTRESS=1

# --- trigger 1: is the GPU responsive? ------------------------------------
if timeout "$SMI_TIMEOUT" nvidia-smi --query-gpu=memory.used --format=csv,noheader >/dev/null 2>&1; then
    [ "$(read_count $GPU_FAILS)" -gt 0 ] && log "nvidia-smi responsive again, clearing counter"
    echo 0 > "$GPU_FAILS"
else
    n=$(( $(read_count $GPU_FAILS) + 1 ))
    echo "$n" > "$GPU_FAILS"
    log "nvidia-smi did not respond within ${SMI_TIMEOUT}s (consecutive failures: $n)"
    escalate_gpu "$n"
fi

# --- trigger 2: is the unified pool about to be exhausted? ----------------
# Only meaningful while vLLM is actually running -- otherwise whatever is
# eating memory is not ours to kill.
if pgrep -f 'VLLM::EngineCore' >/dev/null 2>&1; then
    avail=$(awk '/^MemAvailable:/ {print $2}' "$PROC/meminfo")
    avail=${avail:-0}
    if [ "$avail" -lt "$MEM_CRIT_KIB" ]; then
        # Far past arguing about metrics -- act.
        n=$(( $(read_count $MEM_FAILS) + 1 ))
        echo "$n" > "$MEM_FAILS"
        log "CRITICAL: MemAvailable $((avail/1024)) MiB below $((MEM_CRIT_KIB/1024)) MiB (consecutive: $n; $DISTRESS_DESC)"
        escalate_mem "$n"
    elif [ "$avail" -lt "$MEM_MIN_KIB" ] && [ "$DISTRESS" = 1 ]; then
        n=$(( $(read_count $MEM_FAILS) + 1 ))
        echo "$n" > "$MEM_FAILS"
        log "MemAvailable $((avail/1024)) MiB below $((MEM_MIN_KIB/1024)) MiB WITH reclaim distress (consecutive: $n; $DISTRESS_DESC)"
        escalate_mem "$n"
    elif [ "$avail" -lt "$MEM_MIN_KIB" ]; then
        # The Flash-Next steady state. Log it so the drift stays visible and the
        # distress thresholds can be calibrated against real numbers, but do not
        # escalate: a large mmapped file is this model's normal decode path, not
        # a fault, and killing it here is exactly the 2026-09-09 regression.
        echo 0 > "$MEM_FAILS"
        log "note: MemAvailable $((avail/1024)) MiB below $((MEM_MIN_KIB/1024)) MiB but no reclaim distress ($DISTRESS_DESC) -- not escalating"
    else
        echo 0 > "$MEM_FAILS"
    fi
else
    echo 0 > "$MEM_FAILS"
fi
