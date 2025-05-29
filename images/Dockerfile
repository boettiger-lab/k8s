FROM ghcr.io/rocker-org/ml-spatial

# Config will be populated by env vars and moved to HOME via start script: (hub-dependent)
COPY continue/config.json /opt/share/continue/config.json
COPY continue/config.ts /opt/share/continue/config.ts

USER root
RUN mkdir /opt/share/jupyter && chown -R jovyan:users /opt/share/jupyter
USER jovyan

# COPY jupyter_ai/config.json /opt/share/jupyter/jupyter_ai/config.json
# COPY jupyter_ai/config_schema.json /opt/share/jupyter_ai/config_schema.json


RUN install2.r rsvg nimble

