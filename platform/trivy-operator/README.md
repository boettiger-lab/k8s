# trivy-operator

CVE reports for the images **running** in the cluster ([k8s#221](https://github.com/boettiger-lab/k8s/issues/221)).
Our own images are also scanned at build time by
[`image-scan.yml`](../../.github/workflows/image-scan.yml), which reports to
the repo's Security tab.

```sh
./install.sh                                        # install / upgrade
kubectl get vulnerabilityreports -A -o wide         # one report per workload container
kubectl -n NS get vulnerabilityreport NAME -o yaml  # the CVEs, with fixed versions
```

Prometheus scrapes `trivy_image_vulnerabilities{severity=...}` through the
existing annotation-based service-endpoints job.

## What it does, and what it doesn't

- **HIGH/CRITICAL with a fix available**, the same filter as the CI scans.
- **Weekly.** Reports expire after 7 days, which triggers a rescan. A new
  workload revision is scanned when it appears.
- **Skips** `jupyter`, `arc-runners` and `armada-jobs`. Their pods are
  short-lived, so each would trigger a 10 GB scan, and the notebook images are
  scanned in CI.
- **Vulnerabilities only.** Config audit, RBAC, node infra (a job on every
  node), compliance, secret scanning and SBOMs are off. See `values.yaml`.

## Footprint

All jobs run on **thelio**, two at a time, never on cirrus or the GB10s. The
operator has **no cluster-wide Secret access** (`accessGlobalSecretsAndServiceAccount: false`).
That only matters for private images, and nothing outside `jupyter` uses a pull
secret. The operator and trivy images are pinned by digest.
