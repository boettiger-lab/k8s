#!/bin/bash

docker run --rm -ti -v $(pwd)/encodings/:/etc/encodings/:ro -e TIKTOKEN_ENCODINGS_BASE=/etc/encodings   --gpus all --ipc=host --ulimit memlock=-1 --ulimit stack=67108864 -p 127.0.0.1:8000:8000 nvcr.io/nvidia/vllm:25.09-py3 vllm serve openai/gpt-oss-120b --served-model-name nimbus --api-key $NIMBUS_KEY --gpu-memory-utilization 0.7

