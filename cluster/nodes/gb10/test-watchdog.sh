#!/usr/bin/env bash
# Exercise gpu-hang-watchdog.sh's memory escalation against synthetic
# /proc/meminfo and /proc/vmstat. No root, no GPU, no risk to a running model.
#
#   ./test-watchdog.sh
#
# This exists because the memory trigger killed a healthy production model on
# 2026-09-09 (see the header of gpu-hang-watchdog.sh). The distinction it now
# has to get right -- low memory WITHOUT reclaim distress must not escalate,
# low memory WITH it must -- is exactly the kind of thing that is easy to
# invert and impossible to notice until it costs an outage.
#
# Only the escalation decision is tested. kill_vllm/force_reboot are stubbed:
# the real ones are pkill and sysrq, which have no place in a test.
set -uo pipefail
cd "$(dirname "$0")"

PASS=0; FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkmeminfo() { printf 'MemTotal:       127600752 kB\nMemFree:        %s kB\nMemAvailable:   %s kB\nCached:          9000000 kB\n' "$1" "$2" > "$TMP/proc/meminfo"; }
mkvmstat()  { printf 'pgscan_direct %s\npswpin %s\npswpout 0\n' "$1" "$2" > "$TMP/proc/vmstat"; }

# Run one tick. Stubs replace the destructive actions and nvidia-smi (absent on
# most dev boxes, and its failure would add unrelated GPU-trigger noise).
tick() {
    mkdir -p "$TMP/bin"
    cat > "$TMP/bin/nvidia-smi" <<'EOF'
#!/bin/sh
exit 0
EOF
    cat > "$TMP/bin/pkill" <<'EOF'
#!/bin/sh
echo "STUB-KILL $*"
exit 0
EOF
    cat > "$TMP/bin/pgrep" <<'EOF'
#!/bin/sh
# Pretend vLLM is running, so the memory trigger is evaluated at all.
echo 1234
exit 0
EOF
    chmod +x "$TMP/bin"/*
    PATH="$TMP/bin:$PATH" PROC="$TMP/proc" STATE_DIR="$TMP/state" ALLOW_REBOOT=0 \
        DROP_CACHES_PATH="$TMP/drop_caches" \
        bash gpu-hang-watchdog.sh 2>&1
}

check() { # name, expected-substring-or-!absent, output
    local name="$1" want="$2" out="$3"
    if [[ "$want" == !* ]] && [[ "$out" != *"${want:1}"* ]]; then
        echo "  PASS  $name"; PASS=$((PASS+1))
    elif [[ "$want" != !* ]] && [[ "$out" == *"$want"* ]]; then
        echo "  PASS  $name"; PASS=$((PASS+1))
    else
        echo "  FAIL  $name"; echo "        wanted: $want"; echo "        got:    ${out//$'\n'/ | }"; FAIL=$((FAIL+1))
    fi
}

reset() { rm -rf "$TMP/state" "$TMP/proc"; mkdir -p "$TMP/state" "$TMP/proc"; }

echo "== 1. healthy: plenty of memory, no distress =="
reset; mkmeminfo 40000000 40000000; mkvmstat 1000 10; tick >/dev/null
mkvmstat 1000 10; out="$(tick)"
check "no escalation" "!ESCALATION" "$out"
check "silent" "!below" "$out"

echo "== 2. THE REGRESSION: low memory, no distress -- must NOT kill =="
# 7.9 GiB available: under the 8 GiB floor, which used to be a death sentence.
reset; mkmeminfo 8100000 8200000; mkvmstat 1000 10; tick >/dev/null
for i in 1 2 3 4; do mkvmstat $((1000 + i*50)) 10; out="$(tick)"; done
check "does not escalate" "!ESCALATION" "$out"
check "does not kill" "!STUB-KILL" "$out"
check "still reports the drift" "no reclaim distress" "$out"

echo "== 3. low memory WITH direct-reclaim distress -- must kill on the 3rd =="
reset; mkmeminfo 8100000 8200000; mkvmstat 1000 10; tick >/dev/null
mkvmstat 100000 10;  o1="$(tick)"   # +99k pages: over the 51200 threshold
mkvmstat 200000 10;  o2="$(tick)"
mkvmstat 300000 10;  o3="$(tick)"
check "tick 1 counts, no kill"  "!STUB-KILL" "$o1"
check "tick 2 drops caches"     "dropped clean page cache" "$o2"
check "tick 3 kills"            "ESCALATION: killing vLLM" "$o3"
check "kill targets EngineCore" "STUB-KILL -9 -f VLLM::EngineCore" "$o3"

echo "== 4. low memory with SWAP thrash -- also counts as distress =="
reset; mkmeminfo 8100000 8200000; mkvmstat 1000 10; tick >/dev/null
mkvmstat 1000 20000; o1="$(tick)"; mkvmstat 1000 40000; o2="$(tick)"; mkvmstat 1000 60000; o3="$(tick)"
check "swap distress escalates" "ESCALATION: killing vLLM" "$o3"

echo "== 5. critically low memory -- kills without waiting for distress =="
reset; mkmeminfo 1000000 1000000; mkvmstat 1000 10; tick >/dev/null
mkvmstat 1000 10; o1="$(tick)"; mkvmstat 1000 10; o2="$(tick)"; mkvmstat 1000 10; o3="$(tick)"
check "flags CRITICAL"    "CRITICAL" "$o1"
check "kills by 3rd tick" "ESCALATION: killing vLLM" "$o3"

echo "== 6. distress counter resets when pressure clears =="
reset; mkmeminfo 8100000 8200000; mkvmstat 1000 10; tick >/dev/null
mkvmstat 100000 10; tick >/dev/null          # 1 distress sample
mkmeminfo 40000000 40000000; mkvmstat 100010 10; tick >/dev/null   # recovered
mkmeminfo 8100000 8200000; mkvmstat 200000 10; o1="$(tick)"        # distress again
check "counter restarted at 1" "consecutive: 1" "$o1"

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
