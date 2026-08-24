#!/bin/bash
# Install k3s with Traefik enabled (default behavior) and make admin kubeconfig readable
# Prefer readable kubeconfig so non-root users can access /etc/rancher/k3s/k3s.yaml
curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644

## Restart service without re-installing:
## sudo systemctl restart k3s.service

## To disable Traefik (if needed) while keeping readable kubeconfig:
## curl -sfL https://get.k3s.io | sh -s - --disable=traefik --write-kubeconfig-mode 644

