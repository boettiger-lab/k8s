---
title: "Networking"
weight: 3
---

# Networking

| Piece | Role |
|---|---|
| [Traefik](https://traefik.io/) (bundled with K3s) | ingress controller for every public hostname, pinned to the storage node so traffic to storage stays local |
| [cert-manager](https://cert-manager.io/) | Let's Encrypt certificates via DNS-01 on Cloudflare (ClusterIssuer `letsencrypt-production`) |
| [external-dns](https://github.com/kubernetes-sigs/external-dns) | creates Cloudflare DNS records from Ingress hostnames |
| Cloudflare | DNS for `*.carlboettiger.info`; most web services are proxied, the Kubernetes API is DNS-only |

A new public service needs only an Ingress with a hostname under
`carlboettiger.info` and the `letsencrypt-production` issuer annotation.
external-dns and cert-manager handle the DNS record and the certificate. See
[Deploying a service]({{< relref "/docs/admin/deploying-a-service" >}}).

The nodes share one switched LAN, 10 GbE for the main machines. A pair of GB10s also has a direct high-speed link,
which lets them serve one model split across both machines.
