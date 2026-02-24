FROM ghcr.io/rocker-org/ml-spatial

# If XDG_CONFIG_DIR is set only

USER root
COPY install-kubectl-tools.sh /tmp/install-kubectl-tools.sh
RUN bash /tmp/install-kubectl-tools.sh && rm /tmp/install-kubectl-tools.sh
USER ${NB_USER} 

RUN install2.r rsvg nimble jqr av

