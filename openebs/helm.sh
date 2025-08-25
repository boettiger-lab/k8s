
#!/bin/bash
helm repo add openebs https://openebs.github.io/openebs
helm repo update
helm upgrade --install openebs openebs/openebs -n openebs --create-namespace


