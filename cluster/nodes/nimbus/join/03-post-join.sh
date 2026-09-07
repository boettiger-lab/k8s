#!/usr/bin/env bash
# 03-post-join.sh -- everything that happens on the CIRRUS side once nimbus has
# registered as an agent.
#
#   ./03-post-join.sh            # run with a kubeconfig for the cirrus cluster
#
# Idempotent: safe to re-run. It does not create the vLLM workload -- that is
# services/vllm/up.sh, run last, once the GPU is actually being advertised.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BACKUP="$REPO_ROOT/secrets/nimbus-join-backup"
TAINT="dedicated=nimbus:NoSchedule"

say() { printf '\n==> %s\n' "$*"; }

# --- 0. sanity: are we pointed at the joined cluster? ------------------------
say "checking cluster"
NODES="$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"
echo "$NODES" | sed 's/^/    /'
echo "$NODES" | grep -qx cirrus || { echo "    FAIL: no cirrus node -- wrong kubeconfig?" >&2; exit 1; }
echo "$NODES" | grep -qx nimbus || { echo "    FAIL: nimbus has not registered yet." >&2
                                     echo "          On nimbus: journalctl -u k3s-agent -n 50" >&2; exit 1; }

# The taint is set at registration by /etc/rancher/k3s/config.yaml. If it is
# missing, the node spent time schedulable and may already have pods on it that
# do not belong -- worth knowing before going further.
if kubectl get node nimbus -o jsonpath='{.spec.taints[*].key}' | grep -qw dedicated; then
    echo "    nimbus is tainted $TAINT"
else
    echo "    WARNING: nimbus is NOT tainted. It registered schedulable." >&2
    echo "    Applying now, then check what landed there:" >&2
    echo "      kubectl get pods -A -o wide --field-selector spec.nodeName=nimbus" >&2
    kubectl taint node nimbus "$TAINT" --overwrite
fi

# Architecture is worth stating out loud: cirrus is amd64, nimbus arm64. The
# taint is the only thing keeping cirrus's amd64-only images off this node.
echo "    arch: $(kubectl get node nimbus -o jsonpath='{.metadata.labels.kubernetes\.io/arch}') (cirrus: $(kubectl get node cirrus -o jsonpath='{.metadata.labels.kubernetes\.io/arch}'))"

# --- 1. node label for the device plugin -------------------------------------
say "labelling nimbus for the NVIDIA device plugin"
# Not set via k3s --node-label: NodeRestriction only lets a kubelet self-assign
# labels from a short allow-list, and nvidia.com/* is not on it.
kubectl label node nimbus nvidia.com/device-plugin.config=timeslice --overwrite

# --- 2. roll the DaemonSets that are allowed on nimbus -----------------------
say "re-applying charts whose DaemonSets must tolerate the nimbus taint"
echo "    nvidia device plugin + node-feature-discovery"
( cd "$REPO_ROOT/nvidia" && bash nvidia-device-plugin.sh )
echo "    dcgm-exporter"
helm repo add gpu-helm-charts https://nvidia.github.io/dcgm-exporter/helm-charts >/dev/null
helm repo update gpu-helm-charts >/dev/null
helm upgrade -i dcgm-exporter gpu-helm-charts/dcgm-exporter \
  --namespace monitoring --version 4.8.2 --wait \
  --values "$REPO_ROOT/platform/monitoring/dcgm-exporter-values.yaml"

# --- 3. restore the secrets that could not be regenerated --------------------
say "restoring secrets into the vllm namespace"
kubectl create namespace vllm --dry-run=client -o yaml | kubectl apply -f -
for s in huggingface-token vllm-api-key ngc-pull; do
    f="$BACKUP/secret-$s.yaml"
    if [ -f "$f" ]; then
        kubectl -n vllm apply -f "$f"
    else
        echo "    MISSING $f -- recreate $s by hand before services/vllm/up.sh" >&2
    fi
done
# mcp-gpu-nimbus pulls a public ghcr image, but keep the pull secret in default
# in case the package is ever made private.
[ -f "$BACKUP/secret-ghcr-pull.yaml" ] && kubectl -n default apply -f "$BACKUP/secret-ghcr-pull.yaml"

# --- 4. wait for the GPU to be advertised ------------------------------------
say "waiting for nimbus to advertise nvidia.com/gpu"
for i in $(seq 1 60); do
    GPUS="$(kubectl get node nimbus -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null || true)"
    [ -n "${GPUS:-}" ] && [ "$GPUS" != "0" ] && break
    sleep 5
done
if [ -n "${GPUS:-}" ] && [ "$GPUS" != "0" ]; then
    echo "    nimbus advertises $GPUS nvidia.com/gpu (8 time-slices of one GB10)"
else
    echo "    FAIL: nimbus advertises no GPU after 5 minutes." >&2
    echo "    Almost always the device plugin missing its toleration:" >&2
    echo "      kubectl -n nvidia-device-plugin get pods -o wide | grep nimbus" >&2
    exit 1
fi

# --- 5. workloads -------------------------------------------------------------
say "deploying the sanctioned nimbus workloads"
kubectl apply -f "$REPO_ROOT/services/mcp/"
echo
echo "    vLLM is deliberately left to you -- it needs NIMBUS_KEY in the env:"
echo "      cd $REPO_ROOT/services/vllm && NIMBUS_KEY=... ./up.sh"

# --- 6. report ----------------------------------------------------------------
say "state"
kubectl get nodes -o wide
echo
echo "Pods on nimbus (should be ONLY the tolerating DaemonSets + sanctioned work):"
kubectl get pods -A -o wide --field-selector spec.nodeName=nimbus
echo
echo "Anything CrashLoopBackOff here is the usual arm64/amd64 image mismatch."
echo
echo "DNS will move these to cirrus's IP within a few minutes (external-dns"
echo "runs on a 1m interval), then cert-manager issues the certs:"
echo "  vllm-nimbus.carlboettiger.info"
echo "  gpu-mcp-nimbus.carlboettiger.info"
