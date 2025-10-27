# K8s Cluster Documentation

This directory contains the Hugo-based documentation site for the K8s cluster setup and services.

## Building the Documentation

### Prerequisites

Install Hugo:

```bash
# Ubuntu/Debian
sudo apt install hugo

# Or use snap for latest version
sudo snap install hugo

# macOS
brew install hugo

# Or download from https://github.com/gohugoio/hugo/releases
```

### Install Theme

This documentation uses the [Hugo Book](https://github.com/alex-shpak/hugo-book) theme:

```bash
cd docs
git submodule add https://github.com/alex-shpak/hugo-book themes/hugo-book
# Or if not using git submodules:
git clone https://github.com/alex-shpak/hugo-book themes/hugo-book
```

### Build and Serve Locally

```bash
# From the docs directory
cd docs

# Serve with live reload
hugo server -D

# Or build static site
hugo
```

The site will be available at http://localhost:1313

### Build for Production

```bash
cd docs
hugo --minify
```

The built site will be in the `docs/public` directory.

## Structure

```
docs/
├── hugo.toml              # Hugo configuration
├── content/               # Documentation content
│   ├── _index.md         # Home page
│   └── docs/
│       ├── infrastructure/    # Infrastructure setup docs
│       │   ├── k3s.md
│       │   ├── nvidia.md
│       │   ├── openebs.md
│       │   ├── cert-manager.md
│       │   └── external-dns.md
│       ├── services/          # Service documentation
│       │   ├── jupyterhub.md
│       │   ├── postgres.md
│       │   └── github-actions.md
│       └── admin/             # Administration guides
│           ├── users.md
│           └── tips-tricks.md
├── themes/                # Hugo themes
│   └── hugo-book/
└── public/               # Generated site (after build)
```

## Writing Documentation

### Front Matter

Each page should have front matter:

```yaml
---
title: "Page Title"
weight: 1              # Ordering in navigation
bookToc: true          # Show table of contents
---
```

### Internal Links

Use Hugo's `relref` for internal links:

```markdown
[Link Text]({{< relref "path/to/page" >}})
```

### Code Blocks

Use fenced code blocks with language specification:

````markdown
```bash
kubectl get pods
```

```yaml
apiVersion: v1
kind: Pod
```
````

### Admonitions

The Hugo Book theme supports admonitions:

```markdown
{{< hint info >}}
**Info**  
Informational message
{{< /hint >}}

{{< hint warning >}}
**Warning**  
Warning message
{{< /hint >}}

{{< hint danger >}}
**Danger**  
Danger message
{{< /hint >}}
```

## Deployment

### GitHub Pages (Automated) ✅

**This repository is configured for automatic deployment to GitHub Pages!**

The documentation site automatically builds and deploys when you push changes to the `main` branch.

**Site URL:** https://boettiger-lab.github.io/k8s/

**Setup required (one-time):**

1. Go to repository Settings → Pages
2. Under "Build and deployment", select:
   - Source: **GitHub Actions**
3. That's it! The workflow at `.github/workflows/hugo.yml` handles everything

**How it works:**
- Push changes to the `main` branch (or modify anything in `docs/`)
- GitHub Action automatically:
  - Installs Hugo
  - Clones the Hugo Book theme
  - Builds the site
  - Deploys to GitHub Pages
- Site is live within 1-2 minutes

**To trigger a manual build:**
- Go to Actions tab → "Deploy Hugo Documentation to GitHub Pages" → Run workflow

### Manual Deployment

If you need to build locally:

```bash
cd docs
hugo --minify
```

The built site will be in `docs/public/`.

## Customization

### Configuration

Edit `hugo.toml` to customize:
- Site title
- Base URL
- Theme parameters
- Menu items

### Styling

The Hugo Book theme can be customized by:
1. Overriding theme files in `layouts/`
2. Adding custom CSS in `assets/`
3. Modifying theme parameters in `hugo.toml`

## Contributing

When adding new documentation:

1. Create a new `.md` file in the appropriate directory
2. Add front matter with title and weight
3. Write content using Markdown
4. Use internal links for cross-references
5. Test locally with `hugo server`
6. Commit and push

## Links

- [Hugo Documentation](https://gohugo.io/documentation/)
- [Hugo Book Theme](https://github.com/alex-shpak/hugo-book)
- [Markdown Guide](https://www.markdownguide.org/)
