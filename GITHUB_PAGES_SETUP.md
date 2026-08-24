# GitHub Pages Deployment - Quick Setup Guide

## ✅ GitHub Actions Workflow Created

A GitHub Actions workflow has been created at `.github/workflows/hugo.yml` that will automatically build and deploy your Hugo documentation site to GitHub Pages.

## 🚀 One-Time Setup Required

To enable GitHub Pages deployment, you need to configure your repository settings:

### Step 1: Enable GitHub Pages

1. Go to your GitHub repository: https://github.com/boettiger-lab/k8s
2. Click **Settings** (top menu)
3. Click **Pages** (left sidebar)
4. Under "Build and deployment":
   - **Source:** Select **GitHub Actions** (not "Deploy from a branch")
5. Save (if needed)

That's it! No other configuration needed.

## 📝 How It Works

### Automatic Deployment

The workflow automatically triggers when:
- You push changes to the `main` branch
- Any file in the `docs/` directory changes
- The workflow file itself (`.github/workflows/hugo.yml`) changes

### Manual Deployment

You can also trigger a build manually:
1. Go to the **Actions** tab in your repository
2. Select "Deploy Hugo Documentation to GitHub Pages"
3. Click **Run workflow** → **Run workflow**

## 🌐 Your Documentation Site

Once deployed, your documentation will be available at:

**https://boettiger-lab.github.io/k8s/**

## 📦 What the Workflow Does

1. **Checks out** the repository code
2. **Installs Hugo** (version 0.128.0)
3. **Clones** the Hugo Book theme into `docs/themes/hugo-book`
4. **Builds** the site with `hugo --minify`
5. **Uploads** the built site
6. **Deploys** to GitHub Pages

## 🔍 Monitoring Deployments

View deployment status:
1. Go to the **Actions** tab
2. Look for workflow runs named "Deploy Hugo Documentation to GitHub Pages"
3. Click on a run to see detailed logs

Green checkmark ✅ = Successfully deployed  
Red X ❌ = Build failed (check logs for errors)

## 🛠️ Troubleshooting

### Deployment Fails

1. Check the Actions tab for error messages
2. Common issues:
   - Invalid YAML in front matter
   - Broken internal links
   - Missing Hugo configuration

### Site Not Updating

1. Check that GitHub Pages source is set to "GitHub Actions"
2. Verify the workflow ran successfully (Actions tab)
3. Clear your browser cache
4. Wait 1-2 minutes for CDN propagation

### 404 Errors

If you get 404s on the site:
1. Verify `baseURL` in `docs/hugo.toml` is correct:
   ```toml
   baseURL = 'https://boettiger-lab.github.io/k8s/'
   ```
2. Ensure `canonifyURLs = true` is set

## 📄 Workflow Configuration

The workflow file is located at:
```
.github/workflows/hugo.yml
```

Key features:
- Runs on: Ubuntu latest
- Hugo version: 0.128.0 (extended)
- Triggers: Push to main, manual dispatch
- Permissions: Read contents, write pages

## 🎯 Next Steps

1. **Enable GitHub Pages** (see Step 1 above)
2. **Push this commit** to the main branch
3. **Watch the deployment** in the Actions tab
4. **Visit your site** at https://boettiger-lab.github.io/k8s/

## 💡 Tips

- The theme is automatically cloned during build (not committed to repo)
- Build artifacts (`public/`, `.hugo_build.lock`) are gitignored
- Each push to main triggers a new deployment
- Use draft mode (`draft: true` in front matter) for unpublished pages

## 📚 Documentation

- [GitHub Pages with Actions](https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site#publishing-with-a-custom-github-actions-workflow)
- [Hugo Documentation](https://gohugo.io/documentation/)
- [Hugo Book Theme](https://github.com/alex-shpak/hugo-book)
