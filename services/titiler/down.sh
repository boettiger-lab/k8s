#!/bin/bash

kubectl delete -f deployment.yaml
kubectl delete -f ingress.yaml
kubectl delete -f service.yaml
