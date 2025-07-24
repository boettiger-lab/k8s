FROM ghcr.io/rocker-org/ml-spatial

COPY continue/config.json /opt/share/continue/config.json
COPY continue/config.ts /opt/share/continue/config.ts

USER root
RUN mkdir -p /opt/share/jupyter/jupyter_ai && chown -R jovyan:users /opt/share/jupyter
USER jovyan

RUN install2.r rsvg nimble jqr av

