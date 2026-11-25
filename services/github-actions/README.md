Self-hosted GitHub Actions runners (ARC runner scale sets) on cirrus.

See [official docs](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/autoscaling-with-self-hosted-runners) for details/setup.

| Values file | Scale set (`runs-on:`) | Job pod template |
|---|---|---|
| `cirrus-efi-values.yaml` | `efi-cirrus` | `cirrus-efi-hook-template.yaml` |
| `cirrus-espm157-values.yaml` | `arc-runner-espm157` | `cirrus-espm-hook-template.yaml` |
| `cirrus-espm288-values.yaml` | `arc-runner-espm288` | `cirrus-espm-hook-template.yaml` |

**Interruptible.** Runner and job pods use PriorityClass `ci-backfill` (`ci-backfill.yaml`, -800, never preempts), like Armada jobs. A notebook, service or model that needs the space evicts them, and the GitHub job fails; re-run it. All three prefer thelio and fall back to cirrus. efi runs one runner at a time, reserving 32Gi for its job.

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

## Install and upgrade

`install.sh` pins the chart version and installs the controller plus all three scale
sets. Rerunning it within one version is safe.

**Moving to a new chart version** needs more, because Helm never upgrades the CRDs in the
controller chart's `crds/` directory. Pick a time with no running or queued jobs
(`kubectl -n arc-runners get ephemeralrunners`), then:

```bash
helm -n arc-runners uninstall arc-runner-espm157 arc-runner-espm288 efi-cirrus --wait
kubectl -n arc-runners get autoscalingrunnersets       # wait until empty (finalizers deregister from GitHub)
helm -n arc-systems uninstall arc --wait
kubectl get crd -o name | grep actions.github.com | xargs kubectl delete
bash install.sh                                        # after bumping VERSION
```

An uninstall's finalizer hangs if the token in `github-runner-token` is invalid,
because it can't deregister. Fix the token and the uninstall finishes by itself. Jobs
already queued against the old scale sets don't move to the new ones, so re-run them.
