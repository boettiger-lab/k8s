---
title: "vLLM"
weight: 4
bookToc: true
---

# vLLM

Deploy vLLM for high-throughput LLM inference with GPU acceleration.

## Overview

[vLLM](https://github.com/vllm-project/vllm) is a fast and easy-to-use library for LLM inference and serving. It features:
- State-of-the-art serving throughput
- Efficient memory management with PagedAttention
- Continuous batching of requests
- Optimized CUDA kernels
- Support for popular models (Llama, Mistral, GPT, etc.)

## Prerequisites

1. [K3s installed]({{< relref "../infrastructure/k3s" >}})
2. [NVIDIA GPU support configured]({{< relref "../infrastructure/nvidia" >}})
3. Sufficient GPU memory for your chosen model

## Deployment

The `vllm/` directory contains Kubernetes manifests for deploying vLLM.

### Quick Start

```bash
cd vllm

# Deploy vLLM
./up.sh

# Check status
kubectl get pods -n vllm

# View logs
kubectl logs -n vllm deployment/vllm

# Access the service
kubectl get ingress -n vllm
```

### Configuration Files

- `deployment.yaml` - vLLM deployment with GPU
- `service.yaml` - Service for cluster access
- `ingress.yaml` - External HTTPS access
- `up.sh` - Deploy script
- `down.sh` - Cleanup script

### Deployment Configuration

The deployment is configured to:
- Request 1 GPU
- Mount model cache volume
- Expose OpenAI-compatible API
- Auto-download models on first run

Example `deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm
  namespace: vllm
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vllm
  template:
    metadata:
      labels:
        app: vllm
    spec:
      containers:
      - name: vllm
        image: vllm/vllm-openai:latest
        args:
          - --model
          - meta-llama/Llama-2-7b-chat-hf
          - --dtype
          - float16
        resources:
          limits:
            nvidia.com/gpu: 1
        ports:
        - containerPort: 8000
        volumeMounts:
        - name: cache
          mountPath: /root/.cache
      volumes:
      - name: cache
        emptyDir: {}
```

## Usage

### Access the API

Once deployed, vLLM provides an OpenAI-compatible API:

```bash
# Get the ingress URL
kubectl get ingress -n vllm

# Example: https://vllm.carlboettiger.info
```

### API Examples

Using curl:

```bash
curl -X POST https://vllm.carlboettiger.info/v1/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "meta-llama/Llama-2-7b-chat-hf",
    "prompt": "San Francisco is a",
    "max_tokens": 50,
    "temperature": 0.7
  }'
```

Using Python with OpenAI client:

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://vllm.carlboettiger.info/v1",
    api_key="not-needed"  # vLLM doesn't require API key by default
)

response = client.completions.create(
    model="meta-llama/Llama-2-7b-chat-hf",
    prompt="San Francisco is a",
    max_tokens=50,
    temperature=0.7
)

print(response.choices[0].text)
```

Chat completion:

```python
response = client.chat.completions.create(
    model="meta-llama/Llama-2-7b-chat-hf",
    messages=[
        {"role": "user", "content": "What is the capital of France?"}
    ],
    max_tokens=100
)

print(response.choices[0].message.content)
```

### Streaming Responses

```python
response = client.chat.completions.create(
    model="meta-llama/Llama-2-7b-chat-hf",
    messages=[
        {"role": "user", "content": "Tell me a story"}
    ],
    max_tokens=200,
    stream=True
)

for chunk in response:
    if chunk.choices[0].delta.content:
        print(chunk.choices[0].delta.content, end="")
```

## Configuration

### Change Model

Edit `deployment.yaml` to use a different model:

```yaml
args:
  - --model
  - mistralai/Mistral-7B-Instruct-v0.2  # Change this
  - --dtype
  - float16
```

Popular models:
- `meta-llama/Llama-2-7b-chat-hf`
- `meta-llama/Llama-2-13b-chat-hf`
- `mistralai/Mistral-7B-Instruct-v0.2`
- `tiiuae/falcon-7b-instruct`

**Note**: Ensure your GPU has sufficient memory for the model.

### Persistent Model Cache

Use a PersistentVolumeClaim to cache models:

```yaml
volumes:
- name: cache
  persistentVolumeClaim:
    claimName: vllm-cache
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: vllm-cache
  namespace: vllm
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: openebs-zfs
  resources:
    requests:
      storage: 50Gi
```

### Quantization

Use quantization for larger models:

```yaml
args:
  - --model
  - meta-llama/Llama-2-13b-chat-hf
  - --quantization
  - awq  # or 'gptq', 'squeezellm'
  - --dtype
  - float16
```

### Tensor Parallelism

For multi-GPU setups:

```yaml
args:
  - --model
  - meta-llama/Llama-2-70b-chat-hf
  - --tensor-parallel-size
  - "4"
resources:
  limits:
    nvidia.com/gpu: 4
```

## Monitoring

### Check Logs

```bash
kubectl logs -n vllm deployment/vllm -f
```

### GPU Usage

```bash
# On the host
nvidia-smi

# Or from the pod
kubectl exec -n vllm deployment/vllm -- nvidia-smi
```

### Metrics

vLLM exposes metrics at `/metrics`:

```bash
curl https://vllm.carlboettiger.info/metrics
```

## Troubleshooting

### Pod Not Starting

```bash
# Check pod status
kubectl describe pod -n vllm <pod-name>

# Common issues:
# - GPU not available
# - Insufficient GPU memory
# - Model download failure
```

### Out of Memory

1. **Use smaller model**: Switch to 7B instead of 13B
2. **Enable quantization**: Use AWQ or GPTQ
3. **Adjust max tokens**: Limit `max_model_len`

```yaml
args:
  - --model
  - meta-llama/Llama-2-7b-chat-hf
  - --max-model-len
  - "2048"
```

### Model Download Issues

1. **Check internet connectivity**:
```bash
kubectl exec -n vllm deployment/vllm -- ping huggingface.co
```

2. **Use Hugging Face token** for gated models:
```yaml
env:
- name: HF_TOKEN
  valueFrom:
    secretKeyRef:
      name: hf-token
      key: token
```

3. **Pre-download models**: Download models to persistent volume first

### API Not Responding

1. **Check service**:
```bash
kubectl get svc -n vllm
kubectl describe svc vllm-service -n vllm
```

2. **Check ingress**:
```bash
kubectl get ingress -n vllm
kubectl describe ingress vllm-ingress -n vllm
```

3. **Test internally**:
```bash
kubectl run -it --rm test --image=curlimages/curl --restart=Never -- \
  curl http://vllm-service.vllm.svc.cluster.local:8000/health
```

## Advanced Configuration

### Enable Authentication

Add API key authentication:

```yaml
args:
  - --model
  - meta-llama/Llama-2-7b-chat-hf
  - --api-key
  - $(API_KEY)
env:
- name: API_KEY
  valueFrom:
    secretKeyRef:
      name: vllm-secret
      key: api-key
```

### Custom Ingress Rules

Restrict access by IP:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: vllm-ingress
  annotations:
    traefik.ingress.kubernetes.io/router.middlewares: default-ipwhitelist@kubernetescrd
```

### Resource Limits

Adjust CPU and memory:

```yaml
resources:
  limits:
    nvidia.com/gpu: 1
    memory: "16Gi"
    cpu: "4"
  requests:
    nvidia.com/gpu: 1
    memory: "8Gi"
    cpu: "2"
```

## Performance Tuning

### Batch Size

```yaml
args:
  - --max-num-batched-tokens
  - "4096"
  - --max-num-seqs
  - "256"
```

### GPU Memory Utilization

```yaml
args:
  - --gpu-memory-utilization
  - "0.9"  # Use 90% of GPU memory
```

### Speculative Decoding

```yaml
args:
  - --model
  - meta-llama/Llama-2-70b-chat-hf
  - --speculative-model
  - meta-llama/Llama-2-7b-chat-hf
  - --num-speculative-tokens
  - "5"
```

## Cleanup

```bash
cd vllm
./down.sh
```

Or manually:

```bash
kubectl delete namespace vllm
```

## Related Resources

- [vLLM Documentation](https://docs.vllm.ai/)
- [vLLM GitHub](https://github.com/vllm-project/vllm)
- [OpenAI API Reference](https://platform.openai.com/docs/api-reference)
- [NVIDIA GPU Support]({{< relref "../infrastructure/nvidia" >}})
