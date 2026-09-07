#!/bin/bash
# Tears down the workload but KEEPS the PVC (the LevelDB store).
# To remove the data too:  kubectl -n hash-archive delete pvc hash-archive-data
set -e
cd "$(dirname "$0")"
kubectl delete -f deployment.yaml --ignore-not-found
kubectl delete -f ingress.yaml --ignore-not-found
kubectl delete -f service.yaml --ignore-not-found
echo "PVC hash-archive-data retained. Delete it explicitly if you mean to lose the store."
