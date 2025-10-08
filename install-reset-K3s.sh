#!/bin/bash
# Install k3s with Traefik enabled (default behavior)
curl -sfL https://get.k3s.io | sh -s -

## Restart service without re-installing:
## sudo systemctl restart k3s.service

## To disable Traefik (if needed):
## curl -sfL https://get.k3s.io | sh -s - --disable=traefik

