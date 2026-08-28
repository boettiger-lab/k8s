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
#   1. nvidia-smi hangs or errors        -> GPU is wedged
#   2. MemAvailable falls below MEM_MIN  -> heading for the wedge
#
# Escalation is deliberately narrow: it only ever kills vLLM. Jupyter sessions
# and other users' pods are never targeted.

set -uo pipefail

STATE_DIR="${STATE_DIR:-/run/gpu-hang-watchdog}"
GPU_FAILS="$STATE_DIR/gpu_fails"
MEM_FAILS="$STATE_DIR/mem_fails"

SMI_TIMEOUT=20          # seconds to wait for nvidia-smi before calling it hung
MEM_MIN_KIB=$((8*1024*1024))   # 8 GiB of MemAvailable
DROP_CACHES_AFTER=2     # consecutive MEMORY failures before dropping page cache
KILL_AFTER=3            # consecutive failures before we kill vLLM
REBOOT_AFTER=6          # consecutive failures before we force a reboot
ALLOW_REBOOT="${ALLOW_REBOOT:-1}"   # set 0 to disable the reboot escalation

mkdir -p "$STATE_DIR"
read_count() { cat "$1" 2>/dev/null || echo 0; }
log() { echo "[gpu-hang-watchdog] $*"; }

drop_caches() {
    # Clean, file-backed page cache only -- nothing dirty is discarded, so this
    # is lossless. On nimbus this is usually the ~22 GiB duplicate of the model
    # weights that fastsafetensors pulled in through the hostPath mount; the
    # kernel is free to drop it, it just has not gotten around to it yet.
    local before after
    before=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
    sync
    if ! echo 1 > /proc/sys/vm/drop_caches 2>/dev/null; then
        log "could not drop caches (need root)"; return
    fi
    after=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
    log "dropped clean page cache: MemAvailable $((before/1024)) -> $((after/1024)) MiB"
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
    # Memory pressure gets a lossless rung first: reclaiming the page cache
    # duplicate of the weights often resolves this without killing anything.
    if   [ "$n" -ge "$REBOOT_AFTER" ] && [ "$ALLOW_REBOOT" = 1 ]; then force_reboot
    elif [ "$n" -ge "$KILL_AFTER" ];                              then kill_vllm
    elif [ "$n" -ge "$DROP_CACHES_AFTER" ];                       then drop_caches
    fi
}

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
    avail=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
    if [ "${avail:-0}" -lt "$MEM_MIN_KIB" ]; then
        n=$(( $(read_count $MEM_FAILS) + 1 ))
        echo "$n" > "$MEM_FAILS"
        log "MemAvailable $((avail/1024)) MiB below $((MEM_MIN_KIB/1024)) MiB (consecutive: $n)"
        escalate_mem "$n"
    else
        echo 0 > "$MEM_FAILS"
    fi
else
    echo 0 > "$MEM_FAILS"
fi
