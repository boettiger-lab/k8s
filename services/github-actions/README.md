Notes for GitHub Kubernetes Actions Runner Contoller

See [official docs](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/autoscaling-with-self-hosted-runners) for details/setup.


Note: ARC doesn't seem to handle resource limits when user specifies a container, and actions can always opt into a container.  

Individual tasks can set action limits, probably the best way to go at this point.

e.g. for EFI config:

```
    runs-on: efi-cirrus
    container: 
      # IMPORTANT.  Please set a memory limit <= 45 GB.
      image: eco4cast/rocker-neon4cast:latest
      options: --memory="15g"
    steps:
```
