


I have recently deployed a series of upgrades on the test server, thelio:

- SSL certs for https are automatically handled now by `cert-manager` + k3s traefik ingress (instead of the previous solution of using Caddy directly on the node itself).
- Services can automatically register their domain names via `external-dns`.  

This required migrating DNS from Netlify to Cloudflare, which `external-dns` can access via API.  Cloudflare likes to proxy entries for added protection, but note this works only on subdomains (shiny-thelio.carlboettiger.info) and not sub.sub domains.  Currently the cloudflare proxy is turned off for existing sub.sub domains.   

- I've implemented `openebs` to allow k8s to enforce quotas on volume sizes for the locally-backed volumes (i.e. enforcing storage limits for JupyterHub users on these platforms). 

I used the zpool mechanism for this, currently by putting the 4 HDD drives in striped mirror setup. The default 'local-hostpath' mechanism for openebs doesn't support quotas for the same reason the default hostpath mechanism doesn't -- k8s needs some mechanism to enforce this abstraction, like ZFS or other alternatives (xfs, lvm).  

This makes the HDDs visible to the k8s system, and the zpool setup provides some redunancy to disk failure.  Of course these will be much slower than NVMe drive, but maybe suitable for HOME storage and matches the setup typical in commercial cloud jupyterhubs, where HOME's persistent storage is also much slower.  Temporary storage (`/tmp`) should still be useful for I/O-heavy operations, as well as the S3-based access to the local MINIO instance.


Other services previously deployed directly on docker are also now migrated to kubernetes-based hosting.  The `examples` repo shows a demo shiny app deployment, service, and ingress, using cert-manager and externalDNS integration.  

Example deployment for an LLM with convenient settings: embedding vs generation, support for sleep/wake, tool use, and RoPE settings for longer context window, deploying with cert-manager, now implemented as well.  

JupyterHub deployment for thelio is updated, using traefik and cert-manager. Have not yet auto-registered external-DNS.  

JupyterHub images are also lightly revised.  `cline` vscode extension is included, though auto-populating the API key is not supported there. Images no longer set `XDG_DATA_HOME`, so these configurations should persist now. 


MINIO tenant/operator deployment not yet implemented, will still need to revisit. Need to work out possible auth issues.


Will hopefully deploy these changes to the main Cirrus server soon.  





