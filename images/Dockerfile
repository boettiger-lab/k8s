FROM ghcr.io/rocker-org/ml-spatial

# If XDG_CONFIG_DIR is set only

USER root
COPY install-kubectl-tools.sh /tmp/install-kubectl-tools.sh
RUN bash /tmp/install-kubectl-tools.sh && rm /tmp/install-kubectl-tools.sh

# Ship the nautilus OIDC kubeconfig in the image so a standalone `docker run`
# gets the same cluster access a fresh hub user would. kubectl + kubelogin were
# just installed above. On JupyterHub this file is shadowed by the PVC mounted
# over /home/${NB_USER} and is repopulated separately by the hub, so it only
# takes effect for independent (non-hub) use of the image.
#
# Also drop the base image's leftover installer scripts (install_llms.sh,
# install.r) from the home dir; they were build-time helpers, not runtime files.
COPY config /tmp/kubeconfig
RUN install -d -o "${NB_USER}" -g "${NB_USER}" -m 0700 "${HOME}/.kube" && \
    install -o "${NB_USER}" -g "${NB_USER}" -m 0600 /tmp/kubeconfig "${HOME}/.kube/config" && \
    rm /tmp/kubeconfig && \
    rm -f "${HOME}/install_llms.sh" "${HOME}/install.r"

COPY install-claude.sh /tmp/install-claude.sh
RUN bash /tmp/install-claude.sh && rm /tmp/install-claude.sh

COPY install-jupyter-ai.sh /tmp/install-jupyter-ai.sh
RUN bash /tmp/install-jupyter-ai.sh && rm /tmp/install-jupyter-ai.sh

USER ${NB_USER}

RUN install2.r rsvg nimble jqr av

