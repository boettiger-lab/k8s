---
title: "Deploying a service"
weight: 3
---

# Deploying a service

Every service under `services/` follows the same pattern.

1. **A directory** `services/<name>/` holding the manifests or Helm values, a
   README, and an `up.sh` that applies them.
2. **A namespace** for the service.
3. **Placement:**
   - Anything that needs a ZFS LocalPV volume runs on the storage node.
   - Add the `dedicated=gb10` toleration and an arm64-capable image to run on
     the GB10s.
   - Pin `kubernetes.io/arch: amd64` if the image is amd64-only.

   See [Compute and GPUs]({{< relref "/docs/architecture/compute" >}}).
4. **An Ingress** for anything public:

   ```yaml
   apiVersion: networking.k8s.io/v1
   kind: Ingress
   metadata:
     name: myservice
     annotations:
       cert-manager.io/cluster-issuer: letsencrypt-production
       external-dns.alpha.kubernetes.io/cloudflare-proxied: "true"   # or "false"
   spec:
     ingressClassName: traefik
     rules:
     - host: myservice.carlboettiger.info
       http:
         paths:
         - path: /
           pathType: Prefix
           backend: {service: {name: myservice, port: {number: 80}}}
     tls:
     - hosts: [myservice.carlboettiger.info]
       secretName: myservice-tls
   ```

   external-dns creates the DNS record, and cert-manager issues the
   certificate.
5. **Secrets** come from a setup script in the service directory and are never
   committed.
6. **GPU workloads** request `nvidia.com/gpu`, set `runtimeClassName: nvidia`,
   and use `strategy: Recreate`.

[`services/titiler/`](https://github.com/boettiger-lab/k8s/tree/main/services/titiler)
and [`examples/`](https://github.com/boettiger-lab/k8s/tree/main/examples) are
small, complete examples.
