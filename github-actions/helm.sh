# May need to: 
# helm registry logout ghcr.io

## do not think auth is needed in this...
NAMESPACE="arc-systems"
helm upgrade --cleanup-on-fail --install arc \
      --namespace "${NAMESPACE}" \
      --create-namespace \
      oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller


## APP Must be installed from https://github.com/organizations/eco4cast/settings/apps/cirrus-arc-runner/installations
INSTALLATION_NAME="efi-cirrus"
NAMESPACE="arc-runners"
helm upgrade --cleanup-on-fail --install "${INSTALLATION_NAME}" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --values secret_pat.yaml \
  --values cirrus-efi-values.yaml \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set


INSTALLATION_NAME="arc-runner-espm157"
NAMESPACE="arc-runners"
helm upgrade --cleanup-on-fail --install "${INSTALLATION_NAME}" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --values secret_pat.yaml \
  --values cirrus-espm157-values.yaml \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set

INSTALLATION_NAME="arc-runner-espm288"
NAMESPACE="arc-runners"
helm upgrade --cleanup-on-fail --install "${INSTALLATION_NAME}" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --values secret_pat.yaml \
  --values cirrus-espm288-values.yaml \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set




