FROM ghcr.io/rocker-org/ml-spatial

# Config will be populated by env vars and moved to HOME via start script: (hub-dependent)
COPY continue/config.json /opt/share/continue/config.json
COPY continue/config.ts /opt/share/continue/config.ts
COPY jupyter_ai/config.json /opt/share/jupyter_ai/config.json

RUN install2.r rsvg nimble

