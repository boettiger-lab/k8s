
#!/bin/bash

# Delete resources from the vllm namespace
kubectl delete deployment vllm-deployment -n vllm
kubectl delete svc vllm-svc -n vllm
kubectl delete ingress vllm-ingress -n vllm

# Optionally delete secrets (uncomment if you want to remove secrets too)
# kubectl delete secret vllm-huggingface-token -n vllm
# kubectl delete secret vllm-api-key -n vllm

# Optionally delete the entire namespace (uncomment if you want to remove the namespace)
# kubectl delete namespace vllm

echo "vLLM resources deleted from vllm namespace"
