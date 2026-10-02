---
title: "GitHub Actions runners"
weight: 5
---

# GitHub Actions runners

The cluster hosts self-hosted runners for a few GitHub organizations, using
[Actions Runner Controller](https://github.com/actions/actions-runner-controller)
runner scale sets. The scale set's name is the `runs-on:` label.

| `runs-on:` | Organization |
|---|---|
| `efi-cirrus` | eco4cast |
| `arc-runner-espm157` | espm-157 |
| `arc-runner-espm288` | espm-288 |

## Writing workflows for these runners

The runners use **Kubernetes container mode**: each job runs in its own pod
from the image you name. This has a few consequences:

- **Every job must set `container:`.** The image provides the job's tools.
  `rocker/ml` and similar images work well.
- **There is no Docker daemon.** Steps can't call `docker`, Dockerfile-based
  actions don't work, and `container: options:` is ignored.
- **Resources are fixed per runner set.** Memory and CPU limits are set by the
  cluster, not by the workflow.

```yaml
jobs:
  build:
    runs-on: arc-runner-espm157
    container:
      image: rocker/ml:latest
    steps:
      - uses: actions/checkout@v4
      - run: Rscript -e 'rmarkdown::render("index.Rmd")'
```

To add a runner set for another organization, ask a cluster admin. The
configuration is in
[`services/github-actions/`](https://github.com/boettiger-lab/k8s/tree/main/services/github-actions).
