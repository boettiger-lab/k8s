# NVIDIA GPU Configuration

We need to set up `nvidia-device-plugin.sh` for the GPU to be visible to k3s.  It's not clear we need the timeslicing though.  This config included sets up timeslicing in 8 units.


Allow more than one user (pod) to access the GPU simultaneuously.  Based upon [NVIDIA's Improving GPU Utilization in K8S](https://developer.nvidia.com/blog/improving-gpu-utilization-in-kubernetes/).  


