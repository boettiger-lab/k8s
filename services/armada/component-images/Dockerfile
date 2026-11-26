# Upstream Armada component image with its Alpine packages upgraded (#246).
# Upstream's base (Alpine 3.21.3) ships OpenSSL 3.3.3 (critical CVE-2026-31789,
# fixed in 3.3.7), musl and zlib with fixed CVEs, and 0.22.17-0.22.19 still do.
# Same fix as the scheduler image (#224): pull the fixed packages from upstream's
# own Alpine branch, then drop back to upstream's user. Binary, config files and
# entrypoint are unchanged. Drop these images once an upstream release ships the
# fixed packages.
ARG COMPONENT
ARG ARMADA_VERSION=0.22.16
FROM gresearch/armada-${COMPONENT}:${ARMADA_VERSION}
USER root
RUN apk upgrade --no-cache
USER armada
