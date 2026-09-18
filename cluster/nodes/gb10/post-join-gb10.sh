#!/usr/bin/env bash
# post-join-gb10.sh -- the CIRRUS-side half of onboarding a GB10 node.
#
#   ./post-join-gb10.sh nimbus2
#
# Run on cirrus (which is the workstation itself). Idempotent.
#
# Much smaller than ../nimbus/join/03-post-join.sh, because that script also had
# to restore secrets and recreate workloads destroyed by demoting a control
# plane. Nothing here is being restored: the vllm namespace, its secrets and the
# sanctioned workloads already exist in the cluster. A new fleet member only
# needs a device-plugin label and a check that the GPU actually shows up.

set -euo pipefail

NODE="${1:?usage: post-join-gb10.sh <hostname>}"
TAINT_VALUE=gb10

say() { printf '\n==> %s\n' "$*"; }

say "checking $NODE has registered"
kubectl get node "$NODE" >/dev/null 2>&1 || {
    echo "    FAIL: node $NODE not found." >&2
    echo "          On $NODE: journalctl -u k3s-agent -n 50" >&2; exit 1; }
echo "    arch: $(kubectl get node "$NODE" -o jsonpath='{.metadata.labels.kubernetes\.io/arch}')"

# The taint is set at registration by /etc/rancher/k3s/config.yaml. If it is
# missing the node spent time schedulable and may already have amd64 pods on it
# that cannot possibly run -- worth knowing before going further.
say "verifying the registration-time taint and label"
if kubectl get node "$NODE" -o jsonpath='{.spec.taints[*].value}' | grep -qw "$TAINT_VALUE"; then
    echo "    tainted dedicated=$TAINT_VALUE:NoSchedule"
else
    echo "    WARNING: $NODE is NOT tainted. It registered schedulable." >&2
    echo "    Check what landed there before continuing:" >&2
    echo "      kubectl get pods -A -o wide --field-selector spec.nodeName=$NODE" >&2
    kubectl taint node "$NODE" "dedicated=$TAINT_VALUE:NoSchedule" --overwrite
fi
CLASS="$(kubectl get node "$NODE" -o jsonpath='{.metadata.labels.node-class}')"
[ "$CLASS" = gb10 ] && echo "    node-class=gb10" \
                    || echo "    WARNING: node-class is '${CLASS:-unset}', expected gb10" >&2

# --- the k3s auto-upgrade plan must be able to reach this node ---------------
# A NoSchedule taint the plan does not tolerate means the node is SILENTLY never
# upgraded -- no error, no event. Already seen on thelio and on nimbus (whose
# 2026-09-13 retaint to dedicated=gb10 dropped it out of a plan still tolerating
# dedicated=nimbus). Check rather than assume.
say "checking system-upgrade/agent-plan tolerates dedicated=$TAINT_VALUE"
if kubectl -n system-upgrade get plan agent-plan \
     -o jsonpath='{.spec.tolerations[*].value}' 2>/dev/null | grep -qw "$TAINT_VALUE"; then
    echo "    agent-plan tolerates dedicated=$TAINT_VALUE"
else
    echo "    WARNING: agent-plan does NOT tolerate dedicated=$TAINT_VALUE." >&2
    echo "    $NODE will never be auto-upgraded until this is fixed:" >&2
    echo "      kubectl -n system-upgrade edit plan agent-plan" >&2
fi

# --- device plugin label -----------------------------------------------------
# Not set via k3s --node-label: NodeRestriction only lets a kubelet self-assign
# labels from a short allow-list, and nvidia.com/* is not on it.
#
# `timeslice` to match nimbus: 8 slices of the ONE GB10. Read that as a
# co-tenancy cap, not a memory carve-up -- the "VRAM" those slices share is the
# host's 121 GiB unified pool, so the slice count bounds nothing. The only
# effective control on a model's footprint is --kv-cache-memory-bytes in the
# vLLM manifest. See ../../../platform/nvidia/nvidia-device-plugin-config.yaml.
say "labelling $NODE for the NVIDIA device plugin"
kubectl label node "$NODE" nvidia.com/device-plugin.config=timeslice --overwrite

say "waiting for $NODE to advertise nvidia.com/gpu"
GPUS=""
for _ in $(seq 1 60); do
    GPUS="$(kubectl get node "$NODE" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null || true)"
    [ -n "$GPUS" ] && [ "$GPUS" != "0" ] && break
    sleep 5
done
if [ -n "$GPUS" ] && [ "$GPUS" != "0" ]; then
    echo "    $NODE advertises $GPUS nvidia.com/gpu (8 time-slices of one GB10)"
else
    echo "    FAIL: $NODE advertises no GPU after 5 minutes." >&2
    echo "    Almost always the device plugin missing its toleration:" >&2
    echo "      kubectl -n nvidia-device-plugin get pods -o wide | grep $NODE" >&2
    exit 1
fi

say "state"
kubectl get nodes -o wide
echo
echo "Pods on $NODE (should be ONLY the tolerating DaemonSets):"
kubectl get pods -A -o wide --field-selector "spec.nodeName=$NODE"
echo
echo "Anything CrashLoopBackOff here is the usual arm64/amd64 image mismatch."
echo
echo "The fleet is a COLLECTIVE resource: schedule new work with"
echo "  nodeSelector: {node-class: gb10}"
echo "and reserve kubernetes.io/hostname for a real per-box reason."
