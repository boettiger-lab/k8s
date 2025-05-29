# For details, see blog post


# Install K3s
# ============================
#
# (Don't really curl ... | sh without inspecting source!)
# If we are use K8s's default ingress controller (traefik) and use k8s  cert-manager.io for https:
curl -sfL https://get.k3s.io | sh -

# Otherwise, to use jupyter's cert manager, or manual caddy, do:
# curl -sfL https://get.k3s.io | sh -s - --disable=traefik 

echo "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml" >> ~/.bashrc
source ~/.bashrc
sudo chown $(id -u) /etc/rancher/k3s/k3s.yaml

# Install Helm (Not needed, already installed in k3s)
# ============================
# curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Enable GPU + timeslicing
# ============================

bash nvidia/nvidia-device-plugin.sh



# Launch JupyterHub
# ==========================

# edit config files appropriately and:
helm upgrade --cleanup-on-fail \
  --install testjuypterhelm jupyterhub/jupyterhub \
  --namespace testjupyter \
  --create-namespace \
  --version=3.2.1 \
  --values public-config.yaml \
  --values private-config.yaml

# identically:
# bash jupyterhub/jupyterhub.sh


# Additional setup 
# ==========================
## if using a cert-manager
helm install \
  cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.13.3 \
  --set installCRDs=true



