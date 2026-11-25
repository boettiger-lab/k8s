#!/bin/bash
# Install/upgrade ARC (gha-runner-scale-set-controller) and the three runner scale
# sets. Controller and scale sets must run the SAME chart version.
#
# Within one chart version this is a plain idempotent `helm upgrade -i`. Moving to
# a NEW chart version is not: Helm never upgrades CRDs in a chart's crds/ dir, so
# follow "Upgrading ARC" (README) -- uninstall the scale sets and the controller,
# replace the CRDs, then run this script.
#
# GitHub credentials: every scale set reads the pre-created Secret
# `github-runner-token` (arc-runners). It is not Helm-managed, so an uninstall
# leaves it in place.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

VERSION=0.15.1
CHARTS=oci://ghcr.io/actions/actions-runner-controller-charts

# Controller runs on chart defaults (live values were exactly the 0.12 defaults).
helm upgrade -i arc "$CHARTS/gha-runner-scale-set-controller" \
  --version "$VERSION" \
  --namespace arc-systems --create-namespace \
  --wait

kubectl apply -f ci-backfill.yaml
kubectl apply -n arc-runners -f cirrus-espm-hook-template.yaml
kubectl apply -n arc-runners -f cirrus-efi-hook-template.yaml

# release name == runs-on: label
for pair in \
  arc-runner-espm157:cirrus-espm157-values.yaml \
  arc-runner-espm288:cirrus-espm288-values.yaml \
  efi-cirrus:cirrus-efi-values.yaml
do
  name=${pair%%:*}; values=${pair#*:}
  helm upgrade -i "$name" "$CHARTS/gha-runner-scale-set" \
    --version "$VERSION" \
    --namespace arc-runners --create-namespace \
    --reset-values -f "$values" \
    --wait
done

kubectl -n arc-systems get pods
kubectl -n arc-runners get autoscalingrunnersets
