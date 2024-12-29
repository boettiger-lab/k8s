#!/bin/bash 

helm repo add openebs https://openebs.github.io/openebs
helm repo update
helm install openebs openebs/openebs -n openebs --create-namespace


# make sure we don't have stale ghcr.io credentials:
#docker logout ghcr.io

NAMESPACE="arc-systems"
helm upgrade --cleanup-on-fail --install arc \
    --namespace "${NAMESPACE}" \
    --create-namespace \
    oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller




INSTALLATION_NAME="arc-runner-espm157-f24"
NAMESPACE="arc-runners"
helm upgrade --cleanup-on-fail --install "${INSTALLATION_NAME}" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --values values.yaml \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set



#  --set githubConfigSecret.github_token=${GITHUB_PAT} \
#  --set githubConfigUrl=${GITHUB_CONFIG_URL} \


