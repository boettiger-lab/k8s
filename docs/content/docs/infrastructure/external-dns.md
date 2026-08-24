---
title: "External DNS"
weight: 5
bookToc: true
---

# External DNS

Automate DNS record management with ExternalDNS for Kubernetes services.

## Overview

[ExternalDNS](https://github.com/kubernetes-sigs/external-dns/) automatically manages DNS records based on Kubernetes Ingress resources. When you create an Ingress with a hostname, ExternalDNS creates the corresponding DNS record in your DNS provider.

**Benefits**:
- Automatic DNS provisioning for new services
- No manual DNS management
- Keeps DNS records in sync with cluster state
- Supports multiple DNS providers

## Supported DNS Providers

ExternalDNS supports many DNS providers including:
- Cloudflare
- AWS Route53
- Google Cloud DNS
- Azure DNS
- And many more

This documentation focuses on Cloudflare configuration.

## Prerequisites

### Cloudflare Setup

1. **Cloudflare Account**: You need a Cloudflare account with a domain
2. **API Token**: Create an API token with the following permissions:
   - Zone - Zone - Read
   - Zone - DNS - Edit
   - Access to all zones (or specific zones)

To create an API token:
1. Log in to Cloudflare Dashboard
2. Go to "My Profile" → "API Tokens"
3. Click "Create Token"
4. Use the "Edit zone DNS" template
5. Set appropriate zone resources
6. Copy the token (you won't see it again!)

## Installation

### Create API Token Secret

First, create a Kubernetes secret with your Cloudflare API token:

```bash
# Set your API token
export CF_API_TOKEN="your-cloudflare-api-token-here"

# Create the secret
kubectl create secret generic cloudflare-api-token \
  --from-literal=cloudflare_api_token=$CF_API_TOKEN \
  -n external-dns
```

Or use the provided script:

```bash
# Edit the script with your token
bash external-dns/set-cf-secret.sh
```

### Install ExternalDNS using Helm

Create a `values.yaml` file for ExternalDNS configuration:

```yaml
provider: cloudflare
env:
  - name: CF_API_TOKEN
    valueFrom:
      secretKeyRef:
        name: cloudflare-api-token
        key: cloudflare_api_token

# Only manage DNS for specific domain(s)
domainFilters:
  - carlboettiger.info

# Dry-run mode for testing (set to false for production)
dryRun: false

# Log level
logLevel: info

# Registry for tracking ownership
registry: txt
txtOwnerId: k3s-cluster

# Sync policy
policy: sync

# Sources to monitor
sources:
  - ingress
  - service
```

Install ExternalDNS:

```bash
# Add ExternalDNS Helm repository
helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/
helm repo update

# Install ExternalDNS
helm install external-dns external-dns/external-dns \
  -n external-dns \
  --create-namespace \
  -f external-dns/values.yaml
```

Or use the provided script:

```bash
bash external-dns/helm.sh
```

### Verify Installation

```bash
# Check ExternalDNS pod is running
kubectl get pods -n external-dns

# View logs
kubectl logs -n external-dns deployment/external-dns
```

## Usage

### Automatic DNS for Ingress Resources

Simply create an Ingress with a hostname in your managed domain:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
spec:
  rules:
  - host: myapp.carlboettiger.info
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: my-app
            port:
              number: 80
  tls:
  - hosts:
    - myapp.carlboettiger.info
    secretName: myapp-tls
```

ExternalDNS will automatically:
1. Detect the new Ingress
2. Create a DNS A record for `myapp.carlboettiger.info`
3. Point it to your cluster's external IP
4. Create a TXT record for ownership tracking

### Example: JupyterHub

```yaml
ingress:
  enabled: true
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
  hosts:
    - hub.carlboettiger.info
```

ExternalDNS automatically creates the DNS record for `hub.carlboettiger.info`.

### Example: Shiny App

See `examples/shiny/ingress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: shiny-ingress
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
    external-dns.alpha.kubernetes.io/hostname: shiny.carlboettiger.info
spec:
  rules:
  - host: shiny.carlboettiger.info
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: shiny-service
            port:
              number: 3838
```

### Custom Annotations

Control ExternalDNS behavior with annotations:

```yaml
metadata:
  annotations:
    # Specify hostname explicitly
    external-dns.alpha.kubernetes.io/hostname: myapp.example.com
    
    # Set TTL
    external-dns.alpha.kubernetes.io/ttl: "300"
    
    # Exclude from ExternalDNS
    external-dns.alpha.kubernetes.io/exclude: "true"
```

## Monitoring

### Check DNS Records Created

```bash
# View ExternalDNS logs
kubectl logs -n external-dns deployment/external-dns

# Check for DNS creation events
kubectl logs -n external-dns deployment/external-dns | grep "CREATE"
```

### Verify in Cloudflare

1. Log in to Cloudflare Dashboard
2. Select your domain
3. Go to DNS → Records
4. Look for A records created by ExternalDNS
5. You should also see TXT records for ownership tracking

### Test DNS Resolution

```bash
# Check DNS resolution
nslookup myapp.carlboettiger.info

# Or use dig
dig myapp.carlboettiger.info
```

## Testing

### Test Deployment

Deploy the test NGINX service:

```bash
kubectl apply -f external-dns/test-nginx-deploy.yaml
```

This creates:
- A Deployment running NGINX
- A Service exposing the deployment
- An Ingress with a test hostname

Check the logs to see ExternalDNS creating the DNS record:

```bash
kubectl logs -n external-dns deployment/external-dns -f
```

Clean up:

```bash
kubectl delete -f external-dns/test-nginx-deploy.yaml
```

## Troubleshooting

### DNS Records Not Created

1. **Check ExternalDNS logs**:
```bash
kubectl logs -n external-dns deployment/external-dns
```

2. **Verify API token**:
```bash
kubectl get secret cloudflare-api-token -n external-dns -o yaml
```

3. **Check domain filter**:
Ensure your Ingress hostname matches the domain filter in `values.yaml`

4. **Verify permissions**:
- Token has Zone Read and DNS Edit permissions
- Token has access to the relevant zone

### DNS Records Not Updating

1. **Check sync interval**: ExternalDNS syncs every minute by default

2. **Verify ownership**: Check TXT records in Cloudflare
   - Format: `txt-<record-name>`
   - Value should match `txtOwnerId` in values.yaml

3. **Force sync**:
```bash
kubectl rollout restart deployment/external-dns -n external-dns
```

### Multiple DNS Records

If you see duplicate records:
1. Check for multiple ExternalDNS deployments
2. Verify `txtOwnerId` is unique per cluster
3. Clean up orphaned TXT records in Cloudflare

### Rate Limiting

Cloudflare has API rate limits:
- If you hit limits, increase sync interval
- Use `--cloudflare-proxied=false` to reduce API calls

## Configuration Options

### Dry-Run Mode

Test without making changes:

```yaml
dryRun: true
```

ExternalDNS will log what it would do without actually creating/updating DNS records.

### Domain Filters

Restrict to specific domains:

```yaml
domainFilters:
  - example.com
  - test.com
```

### Exclude Domains

Exclude specific domains:

```yaml
excludeDomains:
  - internal.example.com
```

### TXT Record Ownership

Track DNS record ownership:

```yaml
registry: txt
txtOwnerId: my-cluster-name
txtPrefix: "external-dns-"
```

### Cloudflare Proxy

Enable Cloudflare CDN proxy (orange cloud):

```yaml
extraArgs:
  - --cloudflare-proxied
```

**Note**: When proxied, DNS returns Cloudflare IPs, which prevents direct access to port 6443 for kubectl.

## Security Considerations

1. **API Token Scope**: Use minimum required permissions
2. **Secret Management**: Protect the API token secret
3. **Ownership Tracking**: Use TXT records to prevent conflicts
4. **Domain Filters**: Restrict to specific domains
5. **Read-Only Mode**: Use `policy: upsert-only` to prevent deletions

## Best Practices

1. **Test in Dry-Run**: Always test with `dryRun: true` first
2. **Use Domain Filters**: Limit ExternalDNS to specific domains
3. **Monitor Logs**: Regularly check ExternalDNS logs
4. **TXT Record Tracking**: Enable ownership tracking
5. **Backup DNS**: Keep manual DNS records backed up
6. **Multiple Clusters**: Use unique `txtOwnerId` per cluster

## Integration

### With cert-manager

ExternalDNS works seamlessly with cert-manager:
1. ExternalDNS creates the DNS record
2. cert-manager requests the certificate
3. Let's Encrypt verifies via HTTP-01 challenge
4. Certificate is issued and stored

### With Traefik

K3s's built-in Traefik ingress controller works automatically with ExternalDNS:
1. Create Ingress with hostname
2. Traefik routes traffic
3. ExternalDNS creates DNS record
4. Traffic flows to your service

## Related Resources

- [ExternalDNS Documentation](https://github.com/kubernetes-sigs/external-dns/)
- [Cloudflare Tutorial](https://github.com/kubernetes-sigs/external-dns/blob/master/docs/tutorials/cloudflare.md)
- [Supported DNS Providers](https://github.com/kubernetes-sigs/external-dns#status-of-providers)
- [cert-manager Integration]({{< relref "cert-manager" >}})
