

Setup for ExternalDNS, <https://github.com/kubernetes-sigs/external-dns/>, allowing k8s to automatically provision subdomains.

See docs for list of supported DNS providers.  This appears to rely simply on API access to the DNS dashboard. 
Currently using Cloudflare DNS, follow tutorial: <https://github.com/kubernetes-sigs/external-dns/blob/master/docs/tutorials/cloudflare.md>


- Implemented using `CF_API_TOKEN`, note privileges: Zone-Zone-Read, Zone-DNS-Edit, access: All zones.  
- deployed via helm chart, see `helm.sh` and values.yaml here.  
- nginx test case here, but see better example in examples/shiny





