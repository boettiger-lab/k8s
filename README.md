# Self-hosting JupyterHub on GPU workstations

## K3s

First, we must up [k3s](https://k3s.io/)  on one or more nodes.  Importantly, we'll disable `traefik` on K3s, since Z2JH will be handling our HTTPS certificates using `letsencrypt`.  The [K3S docs](https://docs.k3s.io/) are quite solid, but this comes down to: 

```bash
curl -sfL https://get.k3s.io | sh -s - --disable=traefik 
```

(also in `install-reset-K3s.sh` script in this repo). Useful things to know: 

- Scripts `k3s-killall.sh` or `k3s-uninstall.sh` are installed and added to path when using the K3s installation method above, does what it says.  (This is great -- nuking everything and getting a fresh start is not always easy on other K8s setups)
- Use `systemctrl restart k3.service` to restart the thing without re-installing. (Good when we update configuations later on.)


### Helm

Helm is already installed with K3S, just set the env var:

```
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
```

e.g. in your `.bashrc`  

## Z2JH

The [Zero To JupyterHub for Kubernetes](https://z2jh.jupyter.org/en/stable/) docs are excellent.  They cover some Kubernetes and Helm setup in various contexts, but we're already good to go there and can jump right in to [Setup JupyterHub](https://z2jh.jupyter.org/en/stable/jupyterhub/installation.html).  Run the default helm command in the tutorial to get a demo instance deployed, then see the customizations we use here.

### https

My config involves three customizations (see [jupyterhub/TEMPLATE-config.yaml](jupyterhub/TEMPLATE-config.yaml).  First, we enable `letsencrypt` for HTTPS ingress:

```yaml
ingress:
  enabled: true
proxy:
  service:
    loadBalancerIP: {your-IP-here} 
  https:
    enabled: true
    hosts:
      - {your-hostname-here} 
    letsencrypt:
      contactEmail: {your-email-here}

```  

Launch/re-launch jupyterhub with this configuration (also in `jupyterhub/launch.sh` script here) by upgrading the helm chart:

```bash
helm upgrade --cleanup-on-fail \
  --install testjuypterhelm jupyterhub/jupyterhub \
  --namespace testjupyter \
  --create-namespace \
  --version=3.2.1 \
  --values config.yaml
```

where `config.yaml` is your config.yaml file with the above block.  You should now have https access at your domain name.

### GitHub-based Authentication

The default authentication is for testing purposes only! any user can log in with any name and password.  Let's set up an authenticator to allow only users who are members of my GitHub Org.  The [official Z2JH docs](https://z2jh.jupyter.org/en/stable/administrator/authentication.html) are once again a great guide, but here's the quick go. You'll need to create an OAuth application for your org on GitHub, and then add the block below to config.yaml and run the `helm upgrade` command from above.  

```yaml
hub:
  config:
    GitHubOAuthenticator:
      allowed_organizations:
        - {github-org} 
      scope:
        - read:org
      client_id: {oath_id} 
      client_secret: {oath_secret}
      oauth_callback_url: https://{your-hostname-here}/hub/oauth_callback
    JupyterHub:
      authenticator_class: github
```

Now, only users who are members of the given GitHub org can authenticate.  


## Working with the GPU

### GPU support for K3s 

Our first step is to enable GPU support for K3s itself before we worry about JupyterHub. The official K3s documents describe [NVIDIA Container Runtime Support](https://docs.k3s.io/advanced#nvidia-container-runtime-support).  These docs are pretty solid but fell short for me.  

- I already had `nvidia-container-runtime` installed, but not the `cuda-drivers-fabricmanager-<VERSION>` and `nvidia-headless-<VERSION>-server`. My driver version is 545 and the repos don't have these packages for anything after 535 right now.  However, it seems these are not necessary anyway (maybe they are rolled into a package I already have in the 545 drivers -- NVIDIA frequently re-organizes things like that...)   Follow the [official nvidia-container-runtime](https://nvidia.github.io/libnvidia-container/) instructions, install these if they exist for your drivers, otherwise you may be fine already.  

- I already had the `nvidia` entries showing up in my `/var/lib/rancher/k3s/agent/etc/containerd/config.toml` as the docs discuss, but the example pod spec shown in the docs would not enter running mode for me. (see `gputest` dir). The docs note:

> Note that the NVIDIA Container Runtime is also frequently used with the NVIDIA Device Plugin and GPU Feature Discovery, which must be installed separately, with modifications to ensure that pod specs include runtimeClassName: nvidia, as mentioned above.

I found I needed the former to get GPU working at all, and I needed the latter to be able to share GPU. I was unable to manage the modifications regarding runtime class, instead, I folowed the instructions on [NVIDIA Device Plugin README](https://github.com/NVIDIA/k8s-device-plugin/) to simply make the nvidia-runtime the default runtime.  (This does not appear to make the GPU available by default on all nodes).  Doing this was ticky, because you don't edit the `/etc/containerd/config.toml`, (not the path K3S uses) or even `/var/lib/rancher/k3s/agent/etc/containerd/config.toml`.  Rather, copy the latter to `/var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl`, and then edit that as described in the README to make nvidia `default_runtime_name`: 

```yaml
version = 2
[plugins]
  [plugins."io.containerd.grpc.v1.cri"]
    [plugins."io.containerd.grpc.v1.cri".containerd]
      default_runtime_name = "nvidia"

      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes]
        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia]
          privileged_without_host_devices = false
          runtime_engine = ""
          runtime_root = ""
          runtime_type = "io.containerd.runc.v2"
          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia.options]
            BinaryName = "/usr/bin/nvidia-container-runtime"
```

Restart K3s service:

```bash
sudo systemctl restart k3.service
```

Now we can use [deploy k8s-device-plugin using helm](https://github.com/NVIDIA/k8s-device-plugin/?tab=readme-ov-file#deployment-via-helm)

```bash
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm repo update
helm upgrade -i nvdp nvdp/nvidia-device-plugin \
  --namespace nvidia-device-plugin \
  --create-namespace \
  --version 0.14.3
```

(It is possible that if we configured this appropriately we could have avoided editing the containerd default runtime, but I didn't succeed in that route).  


GPU should now work on k8s.  Check that `kubectl apply -f gputest/gpu-pod.yaml` reaches the status "Complete" instead of being stuck "Pending":

```bash
kubectl apply -f gputest/gpu-pod.yaml
kubectl get pod gpu-pod

## clean up
kubectl delete pod gpu-pod
```

If so, yay!  K8s is now able to talk to the NVIDIA GPU.  


### Enabling GPU on JupyterHub


You can customize the resources available on a given node and also offer users a menu of possible configurations so they can select what best fits their needs.  As always, see the official docs on [customizing user resources](https://z2jh.jupyter.org/en/stable/jupyterhub/customizing/user-resources.html) for details. The dfeault settings grant access to the node's CPU and RAM, but not the GPU.  A simple configuration here will give options for either CPU or GPU-based pod:

```yaml
singleuser:
  profileList:
    - display_name: "Default server"
      description: "Your code will run on a shared machine with CPU only."
      default: True
    - display_name: "GPU Server"
      description: "Spawns a notebook server with access to a GPU"
      kubespawner_override:
        extra_resource_limits:
          nvidia.com/gpu: "1"
```

This GPU configuration will reserve the entire GPU for this instance.  If the machine has only one GPU, other users will not be able to launch a GPU pod while this pod is active.  As many ML tasks do not consume all the resources of a modern GPU, this can be needlessly restrictive.  Unfortunately, getting Kubernetes instances to share a GPU requires further configuration.  


## GPU Timeslicing

NVIDIA describes techniques for [improving GPU utilization in kubernetes](https://developer.nvidia.com/blog/improving-gpu-utilization-in-kubernetes/) which allow multiple pods to access a single physical GPU.  I believe that timeslicing, the ability to share the GPU across multiple pods, requires the aforementioned [GPU Feature Discovery](https://github.com/NVIDIA/gpu-feature-discovery/).  If we've made it this far we can probably deploy this with helm:

```
helm repo add nvgfd https://nvidia.github.io/gpu-feature-discovery
helm repo update
helm upgrade -i nvgfd nvgfd/gpu-feature-discovery \
  --version 0.8.2 \
  --namespace gpu-feature-discovery \
  --create-namespace
```

As always there's a lot of possible configuration options regarding different features and strategies.  I've used the defaults but certainly reivew the docs.  

Then following the instructions in the post, we can for instance convince Kubernetes to treat our GPU as 8 virtual GPUs with a simple helm command (commands below or just run `timeslicing.sh`) from the `nvidia` directory here.

timeslicing.yaml:

```yaml
version: v1
flags:
  migStrategy: "none"
  failOnInitError: true
  nvidiaDriverRoot: "/"
  plugin:
    passDeviceSpecs: false
    deviceListStrategy: "envvar"
    deviceIDStrategy: "uuid"
  gfd:
    oneshot: false
    noTimestamp: false
    outputFile: /etc/kubernetes/node-feature-discovery/features.d/gfd
    sleepInterval: 60s
sharing:
  timeSlicing:
    resources:
    - name: nvidia.com/gpu
      replicas: 8
```


```bash
helm upgrade nvdp nvdp/nvidia-device-plugin \
   --version=0.14.3 \
   --namespace nvidia-device-plugin \
   --create-namespace \
   --set gfd.enabled=true \
   --set-file config.map.config=timeslicing.yaml
```

