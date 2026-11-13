---
title: "Batch jobs (Armada)"
weight: 5
---

# Batch jobs (Armada)

For work that runs unattended: parameter sweeps, model fits, simulations, many
independent jobs. Jobs are submitted to [Armada](https://armadaproject.io/),
a queueing scheduler, with `armadactl`. You don't need a kubeconfig.

## How it shares the machines

Armada runs jobs as **backfill**. Notebooks, services and models come first:

- A job starts only when its full request fits in capacity nobody else has
  claimed. It never pushes anything else out; it waits.
- When a notebook or model needs the room, Kubernetes evicts Armada jobs.
  An evicted job goes back in the queue and starts over later, so long jobs
  should checkpoint their progress to object storage.
- Any other failure, including running out of memory or a non-zero exit, fails
  the job without a retry.
- Each person has their own queue, and Armada takes turns between queues, so
  one person's thousand jobs don't block someone else's ten.

Jobs can land on any node, including the GB10s, but on a GB10 only when it
isn't serving a model (a model claims its whole machine).

## Getting started

1. **Get a queue.** Ask a cluster admin. Any current lab member can have one.
   Your queue is named after your GitHub login, in lower case, and only you
   (and the admins) can submit to, watch or cancel it.
2. **Set up armadactl.** In a lab JupyterHub notebook it's already installed
   and configured: the cluster's context is called `cirrus`, and `armadactl`
   alone still points at NRP. Elsewhere, install `armadactl` and the login
   helper as described in the
   [Armada README](https://github.com/boettiger-lab/k8s/tree/main/services/armada#setting-up-armadactl).
3. **Log in** before your first command:

   ```bash
   armada-dex-token > /dev/null
   ```

   It prints a link; open it and approve with GitHub. Run it on its own:
   `armadactl` gives each command 10 seconds, so a login started from inside a
   command makes that command fail (the login itself still works). The login
   is kept in your home directory and renews itself until you go 7 days without
   using it, or 30 days in total.

## Submitting jobs

A job file names your queue, a job set (any name you choose; it groups jobs
for watching and cancelling) and one pod spec per job:

```yaml
queue: your-github-login
jobSetId: sweep-2026a
jobs:
  - namespace: armada-jobs          # required, always this value
    priority: 1
    podSpec:
      restartPolicy: Never
      containers:
        - name: main
          image: ghcr.io/your-org/your-image:tag
          command: ["python", "run.py", "--seed", "1"]
          resources:
            requests: { cpu: "1", memory: "4Gi" }
            limits:   { cpu: "1", memory: "4Gi" }
```

```bash
armadactl -c cirrus submit jobs.yaml
armadactl -c cirrus watch your-github-login sweep-2026a    # events as they happen
armadactl -c cirrus cancel job-set your-github-login sweep-2026a
```

**Requests.** Ask for at least 1 CPU and 1Gi of memory; smaller requests are
rejected or never scheduled. Set requests and limits equal, and size memory
from a test run. A job that goes over its memory limit is killed. Asking for
far more than you use makes your jobs wait longer for a slot.

**Inputs and outputs.** Jobs can't mount notebook home directories. Read
inputs from and write results to [object storage]({{< relref "object-storage" >}}).
Finished pods are cleaned up, so anything left only on the pod's disk or
in its logs is lost. Values in the job file, environment variables included, are
visible to cluster admins.

## Choosing hardware

Without a `nodeSelector`, a job runs on whichever node has room. To pin it, add
a `nodeSelector` to the pod spec using one of these labels. These are the
only labels Armada knows: a selector on any other label never matches, and
the job waits forever.

| Label | Values |
|---|---|
| `kubernetes.io/arch` | `amd64`, or `arm64` (the GB10s) |
| `nvidia.com/gpu.product` | `Quadro-RTX-8000-SHARED`, `NVIDIA-GeForce-RTX-2080`, `NVIDIA-GB10-SHARED` |
| `kubernetes.io/hostname` | a specific node |

**Images and architecture.** The GB10s are arm64. A job whose image is
amd64-only must select `kubernetes.io/arch: amd64`, or it fails if it lands on
a GB10. Multi-arch images can go anywhere.

**GPUs.** Request GPU slices and use the `nvidia` runtime class:

```yaml
    podSpec:
      runtimeClassName: nvidia
      containers:
        - name: main
          resources:
            requests: { cpu: "1", memory: "8Gi", nvidia.com/gpu: "1" }
            limits:   { cpu: "1", memory: "8Gi", nvidia.com/gpu: "1" }
```

A slice is a scheduling slot, not a memory partition: every pod on a card sees
the whole card and shares its memory
([Compute and GPUs]({{< relref "/docs/architecture/compute" >}})). Ask for one
slice unless you need more. Several slices are not a whole card, so asking for
more doesn't buy exclusive use.
