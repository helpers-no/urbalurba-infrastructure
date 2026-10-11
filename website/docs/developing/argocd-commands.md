---
title: ArgoCD Commands
sidebar_label: ArgoCD Commands
sidebar_position: 4
---

# ArgoCD Commands

The `uis` CLI manages ArgoCD applications on the cluster. You register a GitHub repository, and the platform creates a namespace, deploys your manifests, and sets up routing automatically.

## Register an application

```bash
uis argocd register <name> <repo-url>
```

**Arguments:**
- `<name>` — Application name. Used as the Kubernetes namespace and ArgoCD app name. Must be DNS-compatible (lowercase, alphanumeric, hyphens, max 63 characters).
- `<repo-url>` — Full GitHub repository URL. Must start with `https://`.

**Example:**

```bash
uis argocd register hello-world https://github.com/helpers-no/urb-dev-typescript-hello-world
```

### What happens during registration

1. **Validates inputs** — checks that the name is DNS-compatible, not already in use, and the URL is valid HTTPS
2. **Checks prerequisites** — verifies ArgoCD is running, the repo exists on GitHub, and it has a `uis/` directory (the standard layout) or, for repositories that predate that standard, a `manifests/` directory
3. **Creates namespace** — `hello-world` namespace in the cluster
4. **Creates ArgoCD Application** — points at the repo's `uis/` directory (or `manifests/` as a fallback), enables auto-sync
5. **Waits for sync** — monitors until ArgoCD syncs manifests and pods are running
6. **Creates IngressRoute** — platform-managed Traefik route for `hello-world.localhost` (and any other domain pointing to the cluster)
7. **Displays summary** — shows health status, service info, and the URL to access the app

### The name doesn't have to match the repo

The app name is independent of the repository name. This lets you use short, meaningful names:

```bash
# Repo has a long name, but you access it as "hello-world"
uis argocd register hello-world https://github.com/helpers-no/urb-dev-typescript-hello-world

# Access at: http://hello-world.localhost
```

### Public vs private repos

Public repositories work without any configuration. For private repositories, configure a GitHub Personal Access Token in secrets:

```bash
uis secrets edit
# Add your GitHub token, then:
uis secrets generate
uis secrets apply
```

## Remove an application

```bash
uis argocd remove <name>
```

Removes the ArgoCD Application, the GitHub credentials secret, and the entire namespace (including all pods, services, and the platform IngressRoute).

**Example:**

```bash
uis argocd remove hello-world
```

## List registered applications

```bash
uis argocd list
```

Shows all registered ArgoCD applications with their health and sync status:

```plaintext
===============================================
ArgoCD Applications (2 registered)
===============================================
Name:   hello-world
Repo:   https://github.com/helpers-no/urb-dev-typescript-hello-world
Health: Healthy
Sync:   Synced
---
Name:   my-api
Repo:   https://github.com/myorg/my-api
Health: Healthy
Sync:   Synced
===============================================
```

## Verify ArgoCD health

```bash
uis argocd verify
```

Runs end-to-end health checks on the ArgoCD server deployment. Use this to confirm ArgoCD itself is running correctly before registering applications.

## Common scenarios

### Re-register after changes

If you need to re-register an app (e.g., after changing the repo URL), remove it first:

```bash
uis argocd remove hello-world
uis argocd register hello-world https://github.com/owner/new-repo
```

### Check why an app isn't working

1. Check the app status: `uis argocd list`
2. Look at the ArgoCD dashboard: `http://argocd.localhost`
3. Check pod status: `kubectl get pods -n <name>`
4. Check pod logs: `kubectl logs -n <name> -l app=<deployment-label>`

### Name already in use

If you get "Name is already in use as a Kubernetes namespace", either choose a different name or remove the existing app first:

```bash
uis argocd remove existing-name
```
