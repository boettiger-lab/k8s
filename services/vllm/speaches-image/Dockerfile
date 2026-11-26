# speaches with its vulnerable Python deps patched in place (#242).
#
# Upstream's last release is 0.9.0-rc.3 (2025-12-27), and `latest-cuda` is still 0.8.3,
# which cannot serve parakeet. 0.9.0-rc.3 ships h11 0.14.0 (CVE-2025-43859, HTTP request
# smuggling in the parser uvicorn uses) plus old anyio, Brotli, certifi, starlette, urllib3
# and others. Drop this image once upstream publishes a fixed release.
#
# gradio and pillow are REMOVED, not upgraded. They serve only the optional web UI: speaches
# imports gradio only when ENABLE_UI is true (speaches/main.py), and nothing else needs
# pillow. Fixing pillow's criticals needs pillow 13, which needs gradio 6.32, which needs
# huggingface-hub >=1.16, and tokenizers (faster-whisper) caps that at <1. So this image
# cannot run the UI, and ENABLE_UI defaults to false here, as in services/vllm/stt-cirrus.yaml.
ARG BASE=ghcr.io/speaches-ai/speaches:0.9.0-rc.3-cuda-12.6.3@sha256:67fed8de534ca76a3e64b0c3f674e8719c5d9eda4481c28dcb1b55b11e140ade
FROM ${BASE}

ENV ENABLE_UI=false

# Ubuntu security updates (openssl, gnupg, apt, libbrotli). Ubuntu's sources only: with the
# NVIDIA repo enabled, apt would also move the CUDA config packages to 13.x, and CUDA has to
# stay as upstream built it. Upstream runs as `ubuntu`.
USER root
RUN mv /etc/apt/sources.list.d/cuda.list /tmp/cuda.list \
 && apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y --no-install-recommends \
 && mv /tmp/cuda.list /etc/apt/sources.list.d/cuda.list \
 && rm -rf /var/lib/apt/lists/*
USER ubuntu

# The venv was built by uv and has no pip; upstream's image ships /usr/bin/uv.
#
# No --upgrade: uv moves only what these floors require, so the rest of the venv (numpy,
# ctranslate2, onnx, huggingface-hub) stays as upstream tested it. `uv pip install` does
# not honour the requirements of packages already in the venv, so keep.txt restates the
# two it would otherwise break: tokenizers needs huggingface-hub <1, and opentelemetry-sdk
# pins opentelemetry-api to 1.29.0.
#
# pip check gate: upstream already fails `uv pip check` five times (onnxruntime-gpu stands
# in for onnxruntime), so the build fails on any incompatibility upstream did not have,
# apart from speaches' own declared gradio requirement, which is dropped on purpose.
#
# Upstream also left its uv download cache in the image (~/.cache/uv, 1.5 GB), holding the
# OLD wheels, which scanners report. The venv does not link into it (only the interpreter
# symlinks to ~/.local/share/uv/python), so it is deleted.
RUN set -eu; \
    PY=/home/ubuntu/speaches/.venv/bin/python; \
    uv pip check --python "$PY" 2>&1 | grep '^The package' | sort > /tmp/check-before || true; \
    uv pip uninstall --python "$PY" gradio gradio-client pillow; \
    printf '%s\n' 'huggingface-hub<1.0' 'opentelemetry-api==1.29.0' > /tmp/keep.txt; \
    uv pip install --no-cache --python "$PY" --constraint /tmp/keep.txt \
      'h11>=0.16.0' 'httpcore>=1.0.9' 'anyio>=4.14.2' 'brotli>=1.2.1' 'certifi>=2026.10.18' \
      'starlette>=1.3.1' 'fastapi>=0.121.1' 'python-multipart>=0.0.30' 'urllib3>=2.8.0' \
      'cryptography>=50.0.0' 'pyopenssl>=26.0.0' 'dnspython>=2.9.2' 'fsspec>=2026.6.0' \
      'lxml>=6.1.0' 'orjson>=3.11.6' 'protobuf>=5.29.6,<6' 'jaraco.context>=6.1.0' \
      'setuptools>=78.1.1' 'wheel>=0.46.2'; \
    uv pip check --python "$PY" 2>&1 | grep '^The package' \
      | grep -v '^The package `speaches` requires `gradio' | sort > /tmp/check-after || true; \
    echo '--- pip check failures not in upstream (must be empty):'; \
    if comm -13 /tmp/check-before /tmp/check-after | grep .; then exit 1; fi; \
    echo '(none)'; \
    rm -f /tmp/check-before /tmp/check-after /tmp/keep.txt; \
    rm -rf /home/ubuntu/.cache/uv; \
    "$PY" -c 'import h11, starlette, fastapi, speaches.main; print("h11", h11.__version__, "starlette", starlette.__version__, "fastapi", fastapi.__version__)'
