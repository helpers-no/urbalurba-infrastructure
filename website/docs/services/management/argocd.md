---
title: ArgoCD
sidebar_label: ArgoCD
---

# ArgoCD

GitOps continuous delivery tool for Kubernetes.

| | |
|---|---|
| **Category** | Management |
| **Deploy** | `./uis deploy argocd` |
| **Undeploy** | `./uis undeploy argocd` |
| **Depends on** | None |
| **Required by** | None |
| **Helm chart** | `argo/argo-cd` `7.8.26` |
| **Default namespace** | `argocd` |

## What It Does

ArgoCD watches Git repositories and automatically deploys changes to the Kubernetes cluster. When you push code, ArgoCD detects the change and syncs your manifests to the cluster.

Key capabilities:
- **GitOps workflow** — Git is the source of truth for cluster state
- **Auto-sync** — changes in Git are automatically applied
- **Application registration** — register GitHub repos via CLI
- **Health monitoring** — tracks sync status and application health
- **Web UI** — visual dashboard for all managed applications

## Deploy

```bash
./uis deploy argocd
```

No dependencies.

## Verify

```bash
# Quick check
./uis verify argocd

# Manual check
kubectl get pods -n argocd

# Test the UI
curl -s -o /dev/null -w "%{http_code}" http://argocd.localhost
# Expected: 200 or 302
```

Access the dashboard at [http://argocd.localhost](http://argocd.localhost).

## Configuration

### ArgoCD-Specific Commands

| Command | Description |
|---------|-------------|
| `./uis argocd register <name> <repo-url>` | Register a GitHub repo as ArgoCD application |
| `./uis argocd remove <name>` | Remove an ArgoCD application and its namespace |
| `./uis argocd list` | List registered applications — **refuses** if ArgoCD is not running |
| `./uis argocd verify` | Run health checks |

:::info `list` will not report an empty inventory it could not take
If ArgoCD is not running, `./uis argocd list` **fails with a non-zero status** and names the remedy, rather than printing `(0 registered)`.

🔴 The two read the same and mean opposite things. An `argocd` namespace left behind by a removal is empty but present, so *"no applications registered"* was previously indistinguishable from *"ArgoCD is not here"* — on the command people run first to see where they stand (`urb-agents#1575`).
:::

### Key Files

| File | Purpose |
|------|---------|
| `ansible/playbooks/220-setup-argocd.yml` | Deployment playbook |
| `ansible/playbooks/220-remove-argocd.yml` | Removal playbook |

## Undeploy

```bash
./uis undeploy argocd
```

Managed applications will continue running but will no longer auto-sync from Git.

## Troubleshooting

**Pod won't start:**
```bash
kubectl describe pod -n argocd -l app.kubernetes.io/name=argocd-server
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server
```

**Application stuck in "OutOfSync":**
```bash
kubectl get applications -n argocd
./uis argocd verify
```

**Cannot register repository:**
Check that the repo URL is accessible and the GitHub token is configured:
```bash
./uis secrets status
```

## Learn More

- [Official ArgoCD documentation](https://argo-cd.readthedocs.io/)
