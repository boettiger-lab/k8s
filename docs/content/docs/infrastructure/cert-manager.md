---
title: "Certificate Manager"
weight: 4
bookToc: true
---

# Certificate Manager

Automate SSL/TLS certificate management using cert-manager and Let's Encrypt.

## Overview

[cert-manager](https://cert-manager.io/) automates the management and issuance of TLS certificates from various sources, including Let's Encrypt. It ensures certificates are valid and up-to-date, and attempts to renew certificates before expiration.

## Installation

### Install cert-manager using Helm

```bash
# Add the Jetstack Helm repository
helm repo add jetstack https://charts.jetstack.io
helm repo update

# Install cert-manager with CRDs
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set installCRDs=true
```

Or use the provided script:

```bash
bash cert-manager/helm.sh
```

### Verify Installation

```bash
# Check cert-manager pods are running
kubectl get pods -n cert-manager

# Verify CRDs are installed
kubectl get crd | grep cert-manager
```

You should see three pods running:
- `cert-manager`
- `cert-manager-cainjector`
- `cert-manager-webhook`

## Configuration

### Create ClusterIssuer

A ClusterIssuer is a cluster-wide resource that represents a certificate authority. We use Let's Encrypt for production certificates.

Create a ClusterIssuer for Let's Encrypt production:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: your-email@example.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: traefik
```

**Important**: Replace `your-email@example.com` with your actual email address. Let's Encrypt will use this for certificate expiration notifications.

Apply the configuration:

```bash
kubectl apply -f cert-manager/cluster-issuer-prod.yaml
```

### Verify ClusterIssuer

```bash
# Check ClusterIssuer status
kubectl get clusterissuer

# Describe the issuer
kubectl describe clusterissuer letsencrypt-prod
```

## Usage

### Request Certificates in Ingress Resources

To request a certificate for your service, add annotations to your Ingress resource:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-service
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
spec:
  tls:
  - hosts:
    - myapp.example.com
    secretName: myapp-tls
  rules:
  - host: myapp.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: my-service
            port:
              number: 80
```

**Key Points**:
- `cert-manager.io/cluster-issuer`: Specifies which issuer to use
- `tls` section: Lists hosts and the secret name where the certificate will be stored
- `secretName`: cert-manager will create this secret with the TLS certificate

### Example: JupyterHub with HTTPS

```yaml
ingress:
  enabled: true
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
  hosts:
    - hub.example.com
  tls:
    - hosts:
        - hub.example.com
      secretName: jupyterhub-tls
```

### Certificate Verification

After creating an Ingress, cert-manager will:
1. Detect the certificate request
2. Create a Certificate resource
3. Perform ACME challenge (HTTP-01)
4. Store the certificate in the specified secret

Check the status:

```bash
# View certificates
kubectl get certificates

# Describe a certificate
kubectl describe certificate myapp-tls

# Check certificate orders
kubectl get certificaterequest

# View challenges
kubectl get challenges
```

## Monitoring

### Certificate Status

```bash
# List all certificates
kubectl get certificates --all-namespaces

# Check certificate details
kubectl describe certificate <cert-name> -n <namespace>

# View certificate secret
kubectl get secret <secret-name> -n <namespace> -o yaml
```

### Certificate Renewal

cert-manager automatically renews certificates before expiration (typically 30 days before). Monitor renewal:

```bash
# Check certificate renewal status
kubectl describe certificate <cert-name>

# View cert-manager logs
kubectl logs -n cert-manager deployment/cert-manager
```

## Troubleshooting

### Certificate Stuck in Pending

1. **Check Certificate resource**:
```bash
kubectl describe certificate <cert-name>
```

2. **Check CertificateRequest**:
```bash
kubectl get certificaterequest
kubectl describe certificaterequest <request-name>
```

3. **Check Challenges**:
```bash
kubectl get challenges
kubectl describe challenge <challenge-name>
```

Common issues:
- DNS not pointing to your cluster
- Firewall blocking HTTP/HTTPS
- Incorrect ingress class
- Let's Encrypt rate limits

### HTTP-01 Challenge Failing

The HTTP-01 challenge requires:
- Domain resolves to your cluster's public IP
- Port 80 accessible from the internet
- Ingress controller properly configured

Verify:

```bash
# Check if domain resolves correctly
nslookup myapp.example.com

# Test HTTP access
curl http://myapp.example.com/.well-known/acme-challenge/test

# Check Traefik ingress
kubectl get svc -n kube-system traefik
```

### Rate Limiting

Let's Encrypt has [rate limits](https://letsencrypt.org/docs/rate-limits/):
- 50 certificates per registered domain per week
- 5 duplicate certificates per week

For testing, use the staging environment:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: your-email@example.com
    privateKeySecretRef:
      name: letsencrypt-staging
    solvers:
    - http01:
        ingress:
          class: traefik
```

### Certificate Errors in Browser

1. **Check certificate validity**:
```bash
echo | openssl s_client -connect myapp.example.com:443 2>/dev/null | openssl x509 -noout -dates
```

2. **Verify certificate chain**:
```bash
echo | openssl s_client -connect myapp.example.com:443 -showcerts
```

3. **Check if using staging certificate**: Staging certificates are not trusted by browsers

## DNS-01 Challenge (Alternative)

For wildcard certificates or when HTTP-01 is not feasible, use DNS-01 challenge:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-dns
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: your-email@example.com
    privateKeySecretRef:
      name: letsencrypt-dns
    solvers:
    - dns01:
        cloudflare:
          email: your-cloudflare-email@example.com
          apiTokenSecretRef:
            name: cloudflare-api-token
            key: api-token
```

This requires setting up DNS provider credentials. See [cert-manager DNS-01 docs](https://cert-manager.io/docs/configuration/acme/dns01/) for provider-specific setup.

## Best Practices

1. **Use Production Issuer**: Only use `letsencrypt-prod` for production services
2. **Test with Staging**: Test certificate issuance with `letsencrypt-staging` first
3. **Monitor Expiration**: Set up alerts for certificate expiration
4. **Backup Secrets**: Back up certificate secrets regularly
5. **Rate Limits**: Be aware of Let's Encrypt rate limits
6. **Email Notifications**: Use a monitored email address for Let's Encrypt notifications

## Integration with Traefik

K3s includes Traefik as the default ingress controller. Ensure Traefik is configured for HTTPS:

```bash
# Check Traefik deployment
kubectl get svc -n kube-system traefik

# Verify HTTPS entrypoint
kubectl get svc -n kube-system traefik -o yaml
```

Traefik should expose ports:
- 80 (HTTP)
- 443 (HTTPS)

## Related Resources

- [cert-manager Documentation](https://cert-manager.io/docs/)
- [Let's Encrypt Documentation](https://letsencrypt.org/docs/)
- [Traefik Documentation](https://doc.traefik.io/traefik/)
- [Example Ingress Configuration]({{< relref "../services/jupyterhub#https-configuration" >}})
