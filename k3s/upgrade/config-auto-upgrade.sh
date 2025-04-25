# based on: https://docs.k3s.io/upgrades/automated

## install deps
kubectl apply -f https://github.com/rancher/system-upgrade-controller/releases/latest/download/system-upgrade-controller.yaml


## deploy controller:
kubectl apply -f https://github.com/rancher/system-upgrade-controller/releases/latest/download/crd.yaml

## deploy plans
kubectl apply -f plans.yml
