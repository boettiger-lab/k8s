# For details, see blog post


# Install K3s
# ============================
#
# (Don't really curl ... | sh without inspecting source!)
# If we are use K8s's default ingress controller (traefik) and use k8s  cert-manager.io for https:
curl -sfL https://get.k3s.io | sh


#  set up default config to a location we can write and will be recognized by helm
mkdir .kube
cp /etc/rancher/k3s/k3s.yaml ~/.kube/config


# Otherwise, to use jupyter's cert manager, or manual caddy, do:
# curl -sfL https://get.k3s.io | sh -s - --disable=traefik 

## Not needed if we place config in ~/.kube/config.  
## If using /etc/rancher/k3s/k3s.yaml location, user will need write access.
#echo "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml" >> ~/.bashrc
#source ~/.bashrc

# Install Helm (Not needed, already installed in k3s?)
# ============================
# curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Enable GPU + timeslicing
# ============================

# (see nvidia/ directory)

bash nvidia/nvidia-device-plugin.sh


