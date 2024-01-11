https://github.com/NVIDIA/k8s-device-plugin?tab=readme-ov-file#configure-containerd


# Additional GPU setup

- follow steps in [k3s docs](https://docs.k3s.io/advanced#nvidia-container-runtime-support)

(Ensure cuda runtime installed.  

Copy `/var/lib/rancher/k3s/agent/etc/containerd/config.toml` to `/var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl`

Edit the latter to include the following:


```
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

Restart:

```
sudo systemctl restart k3.service
```

[Apply helm config](https://github.com/NVIDIA/k8s-device-plugin/?tab=readme-ov-file#deployment-via-helm)


May be necessary to stop any running things.


## Additional notes:

Latest cuda-toolkit config:
- adjust apt pin on popOS to prefer nvidia

