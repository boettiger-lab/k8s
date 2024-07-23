
INSTALLATION_NAME="arc-runner-set"
NAMESPACE="arc-runners"
GITHUB_CONFIG_URL="https://github.com/eco4cast/"
helm upgrade --cleanup-on-fail --install "${INSTALLATION_NAME}" \
  --namespace "${NAMESPACE}" \
  --values values.yaml \
  --create-namespace \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set

NAMESPACE="arc-systems"
helm upgrade --cleanup-on-fail --install arc \
    --namespace "${NAMESPACE}" \
    --create-namespace \
    oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller



