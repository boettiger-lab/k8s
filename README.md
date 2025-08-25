# K3S Deployments for local servers

This respository contains all the configuration files (modulo appropriate secrets) for deploying the computational environment of our research team across our local (i.e. campus-based) workstations.  

We now use a kubernetes-based approach, replacing the pure-docker approach we used across our platforms previously (see [servers repo](https://github.com/boettiger-lab/servers)). This retains the same containerized abstractions for the software stack (often the very same docker containers), but provides additional abstractions around the hardware, orchestration, and resource management.


## JupyterHub on GPU workstations

Home to the configuration files for our lab jupyterhub.

See [Zero to JupyterHub](https://z2jh.jupyter.org/en/stable/) for excellent official documentation on everything.  

See [blog post](https://hackmd.io/wJPNgpUETrG2F_-TthQTYw) for some notes on this setup, specifically for k3s and GPU. 



Nvidia container toolkit setup

(not strictly necessary?  install nvidia-container-toolkit and simply enable nvidia runtime in Jupyter)

<https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html>


# Tricks

RAM use (etc) of active container (cgroup)

```
cat /sys/fs/cgroup/memory.max | awk '{printf "%.2f GB\n", $1/1024/1024/1024}'
cat /sys/fs/cgroup/memory.current | awk '{printf "%.2f GB\n", $1/1024/1024/1024}'
```




