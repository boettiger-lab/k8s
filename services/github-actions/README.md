Self-hosted GitHub Actions runners (ARC runner scale sets) on cirrus.

See [official docs](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/autoscaling-with-self-hosted-runners) for details/setup.

| Values file | Scale set (`runs-on:`) | Job pod template |
|---|---|---|
| `cirrus-efi-values.yaml` | `efi-cirrus` | `cirrus-efi-hook-template.yaml` |
| `cirrus-espm157-values.yaml` | `arc-runner-espm157` | `cirrus-espm-hook-template.yaml` |
| `cirrus-espm288-values.yaml` | `arc-runner-espm288` | `cirrus-espm-hook-template.yaml` |

All three use `containerMode: kubernetes`: a workflow's `container:` runs as its own
**sibling pod**, created by actions/runner-container-hooks, not by a Docker daemon.
Consequences for workflow authors:

- **`container: options:` is not supported** (no `--memory`, `--user`, ...). Resource
  limits and the security context come from the scale set's hook template, which is
  merged into every job pod. A limit there is enforced by the kubelet *and* accounted
  for by the scheduler, which the old Docker `--memory` flag never was.
- The limit is per scale set, not per workflow. To change it, edit the hook template
  ConfigMap and re-apply it.

```yaml
jobs:
  forecast:
    runs-on: efi-cirrus
    container:
      image: eco4cast/rocker-neon4cast:latest   # memory ceiling set by the hook template
    steps:
      - uses: actions/checkout@v4
```
