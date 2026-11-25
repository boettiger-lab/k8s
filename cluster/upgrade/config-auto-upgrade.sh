# based on: https://docs.k3s.io/upgrades/automated

# Pinned; bump deliberately (and check plans.yml still has cordon: false on
# server-plan). The default-controller-env ConfigMap is left as upstream ships it.
SUC_VERSION=v0.21.1

kubectl apply -f https://github.com/rancher/system-upgrade-controller/releases/download/${SUC_VERSION}/crd.yaml
kubectl apply -f https://github.com/rancher/system-upgrade-controller/releases/download/${SUC_VERSION}/system-upgrade-controller.yaml

## deploy plans
kubectl apply -f plans.yml
