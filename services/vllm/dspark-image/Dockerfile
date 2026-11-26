# anemll's dspark-vllm-gx10 with its vulnerable Python deps upgraded in place (#242).
#
# Upstream's last release is v0.1.1 (2026-07-15). It runs DeepSeek-V4-Flash across the
# GB10 pair (services/vllm/deepseek-v4-flash-gb10pair.yaml). This image upgrades the
# Python packages with a fixed release (pillow, PyJWT, certifi, uv, aiohttp, cryptography,
# dnspython, filelock, mcp, pyasn1, urllib3) and Ubuntu's own packages, and changes
# nothing else: no --upgrade, so pip moves only what these floors require, and vLLM,
# torch, flashinfer, CUDA and the deadsnakes Python stay exactly as anemll built them.
# vLLM's own HIGHs (fixed in 0.31/0.32) remain: this is anemll's vLLM fork.
# Drop this image if upstream ships a fixed release.
#
# arm64 only (GB10, sm_121). Python is the system /usr/bin/python3 with pip.
ARG BASE=ghcr.io/anemll/dspark-vllm-gx10:0.1.1@sha256:a83948492cf13df455170fb42885f5ef4db54fefe0feff0f841ecbff464ac9d8
FROM ${BASE}

# Ubuntu security updates (openssl, gnupg, apt, libbrotli) from Ubuntu's sources only: the
# CUDA and deadsnakes lists are set aside so CUDA and Python do not move.
RUN mkdir /tmp/apt-off \
 && mv /etc/apt/sources.list.d/cuda-*.list /etc/apt/sources.list.d/deadsnakes-*.list /tmp/apt-off/ \
 && apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y --no-install-recommends \
 && mv /tmp/apt-off/* /etc/apt/sources.list.d/ && rmdir /tmp/apt-off \
 && rm -rf /var/lib/apt/lists/*

# pip check gate: upstream already fails `pip check` six times (flashinfer, torch's nccl
# pin, pygobject, cusparselt), so the build fails on any incompatibility upstream did
# not already have. The import line is a smoke test that vLLM still loads against the
# upgraded packages (no GPU on the runner; vLLM imports without one).
RUN set -eu; \
    python3 -m pip check 2>&1 | sort > /tmp/check-before || true; \
    python3 -m pip install --no-cache-dir \
      'pillow>=13.0.0' 'PyJWT>=2.14.0' 'certifi>=2026.10.18' 'uv>=0.13.4' \
      'aiohttp>=3.14.4' 'cryptography>=50.0.0' 'dnspython>=2.9.2' 'filelock>=4.2.1' \
      'mcp>=1.30.0,<2' 'pyasn1>=0.6.5' 'urllib3>=2.8.0'; \
    python3 -m pip check 2>&1 | sort > /tmp/check-after || true; \
    echo '--- pip check failures not in upstream (must be empty):'; \
    if comm -13 /tmp/check-before /tmp/check-after | grep .; then exit 1; fi; \
    echo '(none)'; \
    rm -f /tmp/check-before /tmp/check-after; \
    python3 -c 'import PIL, jwt, certifi, vllm; print("pillow", PIL.__version__, "PyJWT", jwt.__version__, "certifi", certifi.__version__, "vllm", vllm.__version__)'; \
    uv --version
