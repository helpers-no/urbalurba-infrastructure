# Raspberry Pi MicroK8s Host Documentation

:::caution Legacy `hosts-to-be-deleted/*` path — not yet migrated to UIS CLI
This platform still runs through the legacy `hosts-to-be-deleted/raspberry-microk8s/` scripts; it has not been migrated to the `platforms/*` + `./uis platform <verb>` CLI shape that [Rancher Desktop](./rancher-kubernetes.md) and [Azure AKS](./azure-aks.md) use. Concretely, **`./uis platform list/use/init/up/status/down` do not work for this target yet** — you'll see it omitted from the platform list output. The instructions below describe the legacy flow and may be outdated.

The migration (or formal removal) of all legacy `hosts-to-be-deleted/*` platforms is tracked at [INVESTIGATE-system-migrate-hosts-to-platforms.md](../ai-developer/plans/backlog/INVESTIGATE-system-migrate-hosts-to-platforms.md). Whether to keep first-class RPi support is one of the open questions there — the current state is "still works but unmaintained".
:::
**Last Updated**: September 22, 2024

## 📋 Overview

This guide covers setting up a Raspberry Pi with Tailscale and MicroK8s for edge computing scenarios. The Raspberry Pi provides a low-power, ARM-based Kubernetes environment suitable for IoT applications and distributed computing.

### **Key Features**
- **ARM architecture** optimized for Raspberry Pi hardware
- **Low power consumption** ideal for edge deployments
- **Tailscale VPN integration** for secure remote management
- **Cloud-init automation** for consistent setup
- **Edge computing capabilities** for distributed workloads

### **Prerequisites**
- Raspberry Pi 4 (8GB+ RAM recommended)
- MicroSD card (32GB+ recommended)
- Network connectivity (WiFi or Ethernet)
- Tailscale account for VPN access

## 🚀 Setup Methods

### **Automatic Setup**
TODO: Describe automatic setup process when available

### **Manual Setup**

This manual process assumes:
- Raspberry Pi is set up with Ubuntu
- Connected to Tailscale network
- User named `ansible` is configured

Step 1: Provide the information needed to set up the raspberry in the ansible inventory.

In order to set up using ansible you need to add the raspberry to the ansible inventory. 
The information we need is stored in the file raspberry-microk8s.sh in the raspberry-microk8s folder.
This file should be created by the automatic setup, but we do it manually here.

```bash
cat << EOF > raspberry-microk8s.sh
#!/bin/bash
filename: raspberry-microk8s.sh
description: manually created created info about the raspberry
TAILSCALE_IP=100.xxx.xxx.xxx  # Replace with your actual Tailscale IP
CLUSTER_NAME=raspberry-microk8s
HOST_NAME=raspberry-microk8s
EOF

chmod +x raspberry-microk8s.sh
```

Step 2: Add the raspberry to the ansible inventory.

```bash
./02-raspberry-ansible-inventory.sh 
```



TODO: finish the rasperry setup (whare is my old notes?)
