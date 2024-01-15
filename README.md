# Self-hosting JupyterHub on GPU workstations

See [blog post](https://hackmd.io/wJPNgpUETrG2F_-TthQTYw)


## With external Caddy

- Run `K3s` with `--disabled=traefik` (as Caddy will be handling the external network; otherwise this creates conflicts over the http/https ports, 80 & 443).
- For `jupyterhub`, config needs:

```
ingress:
  enabled: true
proxy:
  service:
    type: NodePort
```

nothing else is needed in `proxy` (i.e. we don't need `https` section as Caddy will handle this. (ClusterIP may be a more natural choice but I think will be an internal node IP either way). 

- Then, in Caddyfile, just map to the Cluster-IP shown for the proxy service (i.e. by `kubectrl -n testjupyter get services proxy-public`), e.g. something like:

```
<insert-domain-name> {
  tls <insert-email-address>
  reverse_proxy <insert-cluster-ip> {
    header_up Host {host}
  }
}
```



