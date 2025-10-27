# K8s Documentation Site - Setup Complete

A comprehensive Hugo-based documentation site has been created in the `docs/` directory.

## What Was Created

### Directory Structure

```
docs/
├── hugo.toml                   # Hugo configuration
├── setup.sh                    # Automated setup script
├── README.md                   # Documentation on building the site
├── .gitignore                  # Ignore build artifacts
└── content/
    ├── _index.md              # Home page
    └── docs/
        ├── infrastructure/     # Infrastructure setup documentation
        │   ├── _index.md
        │   ├── k3s.md
        │   ├── nvidia.md
        │   ├── openebs.md
        │   ├── cert-manager.md
        │   └── external-dns.md
        ├── services/          # Service documentation
        │   ├── _index.md
        │   ├── jupyterhub.md
        │   ├── postgres.md
        │   ├── minio.md
        │   ├── github-actions.md
        │   └── vllm.md
        └── admin/             # Administration guides
            ├── _index.md
            ├── users.md
            ├── secrets.md
            └── tips-tricks.md
```

## Documentation Coverage

### Infrastructure (6 pages)
1. **K3s Installation & Configuration** - Base Kubernetes setup, remote access, security
2. **NVIDIA GPU Support** - GPU device plugin, time-slicing, troubleshooting
3. **Storage with OpenEBS** - ZFS LocalPV, disk quotas, backup/recovery
4. **Certificate Manager** - Let's Encrypt, automatic SSL/TLS, HTTP-01 challenges
5. **External DNS** - Cloudflare integration, automatic DNS records

### Services (5 pages)
1. **JupyterHub** - Multi-user notebooks, GPU profiles, storage, authentication
2. **PostgreSQL** - Database deployment, backup, connections, management
3. **MinIO** - S3-compatible storage, bucket management, integration
4. **GitHub Actions Runners** - Self-hosted runners, GPU support, resource limits
5. **vLLM** - LLM inference, model deployment, API usage

### Administration (3 pages)
1. **User Access Management** - Namespace-scoped users, RBAC, kubeconfig generation
2. **Secrets Management** - Creating/using secrets, best practices, patterns
3. **Tips & Tricks** - Kubectl commands, troubleshooting, quick reference

## Getting Started

### Option 1: Quick Setup (Automated)

```bash
cd docs
./setup.sh
```

This will:
- Install Hugo (if not present)
- Install the Hugo Book theme
- Build the site

### Option 2: Manual Setup

```bash
# Install Hugo
sudo snap install hugo
# or: sudo apt install hugo
# or: brew install hugo

# Install theme
cd docs
git clone https://github.com/alex-shpak/hugo-book themes/hugo-book

# Build and serve
hugo server -D
```

### View the Site

After running setup or `hugo server`, open http://localhost:1313 in your browser.

## Building for Production

```bash
cd docs
hugo --minify
```

The static site will be generated in `docs/public/`.

## Deployment Options

### Option 1: GitHub Pages

1. Build the site: `hugo --minify`
2. Configure GitHub Pages to serve from `docs/public` or use GitHub Actions
3. Push to repository

### Option 2: GitHub Actions (Recommended)

Create `.github/workflows/hugo.yml`:

```yaml
name: Deploy Hugo site

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
        with:
          submodules: true
          
      - name: Setup Hugo
        uses: peaceiris/actions-hugo@v2
        with:
          hugo-version: 'latest'
          
      - name: Build
        run: |
          cd docs
          hugo --minify
          
      - name: Deploy
        uses: peaceiris/actions-gh-pages@v3
        with:
          github_token: ${{ secrets.GITHUB_TOKEN }}
          publish_dir: ./docs/public
```

### Option 3: Self-Host on Cluster

Deploy as a static site in your cluster:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: k8s-docs
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: k8s-docs
  template:
    metadata:
      labels:
        app: k8s-docs
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
        volumeMounts:
        - name: docs
          mountPath: /usr/share/nginx/html
      volumes:
      - name: docs
        hostPath:
          path: /path/to/k8s/docs/public
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: k8s-docs-ingress
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
spec:
  rules:
  - host: docs.carlboettiger.info
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: k8s-docs
            port:
              number: 80
  tls:
  - hosts:
    - docs.carlboettiger.info
    secretName: k8s-docs-tls
```

## Features

### Content Features
- ✅ Comprehensive infrastructure setup guides
- ✅ Detailed service deployment instructions
- ✅ Administration and troubleshooting guides
- ✅ Code examples and configuration snippets
- ✅ Internal cross-linking between pages
- ✅ Best practices and security considerations
- ✅ Troubleshooting sections

### Site Features
- ✅ Clean, navigable structure with Hugo Book theme
- ✅ Search functionality
- ✅ Table of contents for each page
- ✅ Syntax highlighting for code blocks
- ✅ Responsive design
- ✅ GitHub integration links

## Customization

### Update Site Configuration

Edit `docs/hugo.toml`:

```toml
baseURL = 'https://your-domain.com/k8s/'
title = 'Your K8s Cluster Documentation'
```

### Add New Pages

1. Create a new `.md` file in the appropriate directory
2. Add front matter:
   ```yaml
   ---
   title: "Page Title"
   weight: 10
   bookToc: true
   ---
   ```
3. Write content in Markdown
4. Test locally with `hugo server`

### Modify Theme

The Hugo Book theme can be customized by:
- Overriding theme files in `layouts/`
- Adding custom CSS in `assets/`
- Modifying parameters in `hugo.toml`

## Next Steps

1. **Install Hugo** - Run `./setup.sh` or install manually
2. **Review Content** - Browse the documentation locally
3. **Customize** - Update configuration and content as needed
4. **Deploy** - Choose a deployment method and publish
5. **Maintain** - Keep documentation updated as cluster evolves

## Links to Source Material

The documentation was created from:
- Root README.md
- k3s/README.md
- nvidia/README.md
- openebs/README.md
- cert-manager/README.md
- external-dns/README.md
- jupyterhub/README.md
- postgres/README.md
- github-actions/README.md
- users/README.md
- k8s-notes-tricks.md

All content has been organized, expanded, and formatted for the documentation site while preserving the technical accuracy and practical guidance from the original files.

## Support

For questions or issues:
- Review the documentation locally
- Check the [Hugo Documentation](https://gohugo.io/documentation/)
- See [Hugo Book Theme docs](https://github.com/alex-shpak/hugo-book)
