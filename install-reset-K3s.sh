#!/bin/bash
curl -sfL https://get.k3s.io | sh -s - --disable=traefik 

## Restart service without re-installing:
## sudo systemctl restart k3.service

