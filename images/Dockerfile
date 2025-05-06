FROM ghcr.io/rocker-org/ml-spatial

# Config will be populated by env vars and moved to HOME via start script: (hub-dependent)
COPY continue/config.json /opt/share/continue/config.json
COPY continue/config.ts /opt/share/continue/config.ts

RUN install2.r rsvg nimble

