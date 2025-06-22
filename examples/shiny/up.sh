#!/bin/bash

kubectl apply -f service.yaml 
kubectl apply -f ingress.yaml
kubectl apply -f deployment.yaml 

kubectl get pods
