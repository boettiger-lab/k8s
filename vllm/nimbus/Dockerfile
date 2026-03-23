FROM nvcr.io/nvidia/pytorch:26.01-py3

# Install prebuilt vLLM 0.17.2rc1 wheel for DGX Spark (aarch64, cu131).
# Built by eugr/spark-vllm-docker against nvcr.io/nvidia/pytorch:26.01-py3,
# matching the PyTorch/CUDA versions in this base image.
# Also install Ray (required for --distributed-executor-backend ray) and
# fastsafetensors (required for --load-format fastsafetensors).
RUN pip install --no-cache-dir \
    "https://github.com/eugr/spark-vllm-docker/releases/download/prebuilt-vllm-current/vllm-0.17.2rc1.dev7%2Bg9c7cab5eb.d20260317.cu131-cp312-cp312-linux_aarch64.whl" \
    ray \
    fastsafetensors
