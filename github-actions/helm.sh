# ATTENTION!! For controller, NO AUTH NEEDED BUT YOU MUST FIRST LOGOUT:  
helm registry logout ghcr.io

helm upgrade --cleanup-on-fail --install arc \
      --namespace "arc-systems" \
      --create-namespace \
      oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller

## THESE REQUIRE AUTH.  SCOPED AUTH IS BEST!

## APP Must be installed from https://github.com/organizations/eco4cast/settings/apps/cirrus-arc-runner/installations
helm upgrade --cleanup-on-fail --install "efi-cirrus" \
  --namespace "arc-runners" \
  --create-namespace \
  --values secret_pat.yaml \
  --values cirrus-efi-values.yaml \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set


helm upgrade --cleanup-on-fail --install "arc-runner-espm157" \
  --namespace "arc-runners" \
  --create-namespace \
  --values secret_pat.yaml \
  --values cirrus-espm157-values.yaml \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set

helm upgrade --cleanup-on-fail --install "arc-runner-espm288" \
  --namespace "arc-runners" \
  --create-namespace \
  --values secret_pat.yaml \
  --values cirrus-espm288-values.yaml \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set




