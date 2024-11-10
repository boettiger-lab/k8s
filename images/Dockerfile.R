FROM ghcr.io/boettiger-lab/k8s-gpu

USER root
RUN curl -s https://raw.githubusercontent.com/boettiger-lab/repo2docker-r/refs/heads/main/install_r.sh | bash
RUN curl -s https://raw.githubusercontent.com/boettiger-lab/repo2docker-r/refs/heads/main/install_rstudio.sh | bash

# When run as root, install.r automagically handles any necessary apt-gets
COPY install.r install.r
RUN Rscript install.r


USER ${NB_USER}
