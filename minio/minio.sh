#!/bin/bash


helm repo add minio-operator https://operator.min.io

helm install \
  --namespace minio-operator \
  --create-namespace \
  operator minio-operator/operator


