---
title: Traefik
sidebar_label: Traefik
---

# Traefik

Cluster ingress controller and reverse proxy. UIS uses Traefik for `IngressRoute` CRDs, the routing primitive every UIS service relies on for `*.localhost` and external-domain access.

## How it ships per platform

| Platform | How Traefik is installed | UIS responsibility |
|---|---|---|
| **rancher-desktop** | Bundled by k3s. The cluster comes up with a `HelmChart.helm.cattle.io/traefik` resource that k3s reconciles automatically. | None — `./uis deploy traefik` detects the k3s `HelmChart` CR and skips. |
| **AKS** | Installed by the shared playbook during `02-post-apply.sh`. | The playbook does helm install/upgrade with a pinned chart. |
| **GCP / AWS / bare k8s** *(future)* | Same shared playbook, invoked the same way. No platform-specific install logic — that's the whole point of the refactor in #149. | Same. |

The single source of truth is **`ansible/playbooks/003-setup-traefik.yml`**. Every cloud-platform `02-post-apply.sh` should call this playbook (see `platforms/azure-aks/scripts/02-post-apply.sh:99` for the AKS example) instead of re-implementing helm install logic per platform.

## Pinned versions

| Component | Version | Source |
|---|---|---|
| Helm chart | **`traefik/traefik` 39.0.7** | `ansible/playbooks/003-setup-traefik.yml` (`traefik_chart_version`) |
| Proxy image | **`traefik:v3.6.13`** | `manifests/003-traefik-config.yaml` (`image.tag`) |

### Why these versions

Both pins match what rancher-desktop's bundled k3s ships today (`traefik-39.0.701+up39.0.7` chart, `rancher/mirrored-library-traefik:3.6.13` image). The decision is **rancher-desktop k3s parity**, not "absolute latest upstream":

- A successful test on rancher-desktop maps directly to a successful test on AKS — same chart, same proxy, same values schema. No drift between local-dev and cloud.
- Both ecosystems migrate to the next major (chart v40 / proxy v3.7+) **together** as a single coordinated upgrade — when rancher-desktop's k3s catches up. We don't lead the rancher-desktop upgrade cadence.
- v40 introduces breaking values-schema changes (`globalArguments` location, `tls under ports/websecure`, `Service` spec aligned to Kubernetes syntax, `kubernetesIngressNginx` → `kubernetesIngressNGINX`). Adopting v40 ahead of rancher-desktop means re-doing the chart values rewrite twice — once now for cloud-only, once again when local-dev catches up.

When rancher-desktop's k3s ships v40 (typically 2–4 months after upstream), file an INVESTIGATE to migrate both pins together.

## Architectural decision: Traefik is a UIS service, not platform-script logic

Earlier versions of `platforms/azure-aks/scripts/02-post-apply.sh` ran `helm install traefik …` inline. That works for one platform, but creates a fork-and-fix problem the moment a second cloud platform is added:

> Three copies of the same install logic. Three places to bump the chart version. Three places to fix any helm-install bug. Three opportunities for drift between local-dev (rancher-desktop) and the cloud targets.

The refactor in PR #149 makes Traefik a regular UIS service:

- **`provision-host/uis/services/networking/service-traefik.sh`** — service catalog metadata.
- **`ansible/playbooks/003-setup-traefik.yml`** — install/upgrade logic, idempotent, k3s-aware.
- **`ansible/playbooks/003-remove-traefik.yml`** — uninstall (refuses on k3s-managed clusters).
- **`manifests/003-traefik-config.yaml`** — Helm values, single file shared across platforms.

Each platform's post-apply script is now a one-liner that invokes the playbook. Adding GCP or AWS support means writing a `platforms/<cloud>/scripts/02-post-apply.sh` that ends with the same `ansible-playbook 003-setup-traefik.yml` call — no Traefik-install code in the new platform's tree.

## Verifying

```bash
# What got installed on the current cluster
kubectl get pods -n kube-system -l app.kubernetes.io/name=traefik
kubectl get svc traefik -n kube-system           # Type + external IP

# On rancher-desktop, the chart manifest is owned by k3s:
kubectl get helmcharts.helm.cattle.io traefik -n kube-system

# On AKS / cloud, helm owns it:
helm list -n kube-system | grep traefik
```

## See also

- [Networking services overview](./index.md)
- [Cloudflare tunnel](/docs/networking/cloudflare) — outbound tunnel that complements Traefik for external HTTPS access.
- [Tailscale Tunnel](../../networking/tailscale-setup.md) — Tailscale Funnel for protected services.
