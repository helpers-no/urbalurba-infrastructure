# Investigate: DCT One-Command ArgoCD Deployment

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

**Goal**: Enable a developer to deploy their current project to the UIS Kubernetes cluster from inside the DCT devcontainer with a single command.

**Priority**: Medium

**Last Updated**: 2026-04-04

**Related**:
- `helpers-no/dev-templates` → `INVESTIGATE-unified-template-system.md` — unified template system with `uis-bridge.sh` pattern (3UIS)
- [argocd-commands.md](../../../developing/argocd-commands.md) — existing UIS ArgoCD command documentation
- [PLAN-argocd-migration.md](../completed/PLAN-argocd-migration.md) — migration of ArgoCD commands to UIS CLI (completed)

---

## Current State

### What works today (inside UIS provision-host)

The UIS CLI has full ArgoCD app lifecycle commands:

```bash
uis argocd register <name> <repo-url>   # Register repo, deploy, create IngressRoute
uis argocd remove <name>                # Remove app, namespace, secrets
uis argocd list                         # List registered apps with health/sync status
uis argocd verify                       # Health check ArgoCD server
```

The register command is robust:
- Pre-flight: validates inputs, checks ArgoCD is running, verifies repo exists on GitHub, checks for `manifests/` directory
- Creates: namespace, GitHub credentials secret (if private), ArgoCD Application with auto-sync
- Waits: for sync + healthy status, verifies pods are running
- Creates: Traefik IngressRoute for `<name>.localhost` (and any other domain)
- Cleans up: auto-removes all resources on failure

**Documentation**: `website/docs/developing/argocd-commands.md` — complete.

**Testing**: `220-test-argocd.yml` tests ArgoCD server health. No integration test for register/remove cycle.

### What's missing

A developer working in the DCT devcontainer cannot deploy their current project without:
1. Switching to the provision-host terminal
2. Knowing the full GitHub repo URL
3. Choosing a name manually

### Old scripts (cleanup needed)

`scripts/argocd/argocd-register-app.sh` and `scripts/argocd/argocd-remove-app.sh` are pre-CLI wrapper scripts. They use the old interface (env vars: `GITHUB_USERNAME`, `REPO_NAME`, `GITHUB_PAT`) and call the same Ansible playbooks. These are **redundant** — the UIS CLI (`uis argocd register/remove`) replaces them entirely.

**Action**: Move to `scripts/argocd/not-in-use/` or delete.

---

## Proposed: DCT `dev-deploy` Command

### User experience

From inside the DCT devcontainer, a developer runs:

```bash
dev-deploy
```

That's it. The command:
1. Detects the current repo (from git remote)
2. Derives a sensible app name (from repo name)
3. Calls UIS via the bridge to register with ArgoCD
4. Shows the URL where the app is running

### How it works

```bash
# dev-deploy internally does:

# 1. Get repo info from git
REPO_URL=$(git remote get-url origin)        # https://github.com/owner/my-app
APP_NAME=$(basename "$REPO_URL" .git)        # my-app

# 2. Call UIS via the bridge (see 3UIS in unified-template-system investigation)
uis-bridge argocd register "$APP_NAME" "$REPO_URL"

# 3. Output
# → "Your app is running at http://my-app.localhost"
```

### The bridge pattern

Following the 3UIS decision from the unified template system investigation, DCT should use `uis-bridge.sh` to communicate with UIS — never `docker exec` directly:

```bash
# uis-bridge.sh (in DCT lib/)
# Today: docker exec uis-provision-host uis "$@"
# Tomorrow: could be REST API, Unix socket, etc.

uis-bridge argocd register my-app https://github.com/owner/my-app
uis-bridge argocd remove my-app
uis-bridge argocd list
```

This is the same bridge used by `dev-template configure` for `uis configure` and `uis expose`. One abstraction layer for all DCT→UIS communication.

### Prerequisites

| Prerequisite | Status |
|-------------|--------|
| UIS ArgoCD commands (`uis argocd register/remove/list`) | **Done** — working in UIS CLI |
| `uis` symlink inside container (`/usr/local/bin/uis`) | Not done — see 3UIS internal note |
| Docker CLI in DCT | Not done — needed for `docker exec` |
| `uis-bridge.sh` in DCT | Not done — defined in unified template system investigation |
| ArgoCD deployed on cluster | Depends on `uis deploy argocd` |

### Edge cases to handle

1. **No git remote** — error: "No git remote found. Push your repo to GitHub first."
2. **App name already in use** — UIS already catches this and suggests `uis argocd remove`
3. **No `manifests/` directory** — UIS pre-flight already catches this with helpful error
4. **ArgoCD not deployed** — UIS pre-flight already catches this
5. **UIS not running** — `uis-bridge.sh` should detect this and show: "UIS is not running. Start it with: ./uis start"
6. **Private repo** — UIS handles this if `GITHUB_ACCESS_TOKEN` is configured in secrets
7. **Re-deploy** — `dev-deploy` should detect if already registered and offer to re-register (remove + register)

### Optional flags

```bash
dev-deploy                          # Deploy current repo with auto-detected name
dev-deploy --name custom-name       # Override the app name
dev-deploy --remove                 # Remove the deployment
dev-deploy --status                 # Show deployment status (calls uis argocd list)
```

---

## Testing Gap

The register/remove cycle has no integration test in the UIS test suite. The Ansible playbook has built-in pre-flight checks and auto-cleanup, but we should add a test to `uis test-all` that:

1. Registers a known public test repo
2. Verifies it syncs and is healthy
3. Verifies the IngressRoute is created
4. Removes it
5. Verifies cleanup is complete

This would use the existing test repo: `helpers-no/urb-dev-typescript-hello-world`.

---

## Decisions Needed

1. **Command name**: `dev-deploy`? `dev-argocd`? Something else? Should align with DCT naming conventions.
2. **App name derivation**: Use repo name? Prompt the user? Allow override?
3. **Should `dev-deploy` check for `manifests/` locally before calling UIS?** UIS already checks via GitHub API, but a local check would be faster and work offline.

## Next Steps

- [ ] Clean up old `scripts/argocd/` scripts (move to not-in-use or delete)
- [ ] Add ArgoCD register/remove integration test to `uis test-all`
- [ ] Add `/usr/local/bin/uis` symlink to Dockerfile (prerequisite for bridge)
- [ ] Coordinate with DCT on `uis-bridge.sh` and `dev-deploy` command
- [ ] Create PLAN when prerequisites are ready
