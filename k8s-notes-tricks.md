
# Notes & Tricks

Brief k8s commands that can be hard to look up.

- Most common k8s tasks are easy to look up, and LLMs know k8s basics reasonably well now. 
- There are lots of nice tutorials in [NRP docs](https://nrp.ai/documentation/)


### Purge namespace stuck in terminating state.

```
NAMESPACE=mynamespace
kubectl get namespace $NAMESPACE -o json | sed 's/"kubernetes"//' | kubectl replace --raw "/api/v1/namespaces/$NAMESPACE/finalize" -f -
```

https://stackoverflow.com/questions/52369247/namespace-stuck-as-terminating-how-i-removed-it
