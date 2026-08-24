---
title: "Infrastructure"
weight: 1
bookCollapseSection: false
---

# Infrastructure

Documentation for setting up and configuring the Kubernetes cluster infrastructure.

This section covers the core components that need to be configured before deploying services:

## Core Components

- [**K3s Installation & Configuration**](k3s) - Base Kubernetes setup
- [**NVIDIA GPU Support**](nvidia) - GPU device plugin and time-slicing
- [**Storage with OpenEBS**](openebs) - Persistent storage with disk quotas
- [**Certificate Manager**](cert-manager) - Automatic SSL/TLS certificates
- [**External DNS**](external-dns) - Automatic DNS record management

## Setup Order

For a new cluster, configure components in this order:

1. **K3s** - Install and configure the base Kubernetes cluster
2. **OpenEBS** - Set up persistent storage (if using disk quotas)
3. **cert-manager** - Configure automatic certificate management
4. **ExternalDNS** - Set up automatic DNS provisioning
5. **NVIDIA GPU** - Enable GPU support (if using GPUs)

Once these components are configured, you can deploy [services]({{< relref "../services" >}}).
