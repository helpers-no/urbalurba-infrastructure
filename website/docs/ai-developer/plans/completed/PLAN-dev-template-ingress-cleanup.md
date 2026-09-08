# PLAN: Dev Template Ingress Cleanup After Platform-Managed Routing

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed

**Goal**: Remove redundant `ingress.yaml` and obsolete `urbalurba-scripts/` from dev templates — routing is now the platform's responsibility.

**Last Updated**: 2026-03-04

**Investigation**: [INVESTIGATE-dev-template-ingress-cleanup](INVESTIGATE-dev-template-ingress-cleanup.md)

---

**Prerequisites**: Platform-managed IngressRoute (Phase 6 of [PLAN-argocd-register-redesign](../completed/PLAN-argocd-register-redesign.md)) — deployed and tested

---

## Problem Summary

Now that `uis argocd register` creates a platform-managed IngressRoute (`HostRegexp(`<app_name>\..+`)`), repos no longer need to ship their own ingress manifests. But:

1. All 7 templates in `urbalurba-dev-templates` still include `ingress.yaml`
2. The live test repo `urb-dev-typescript-hello-world` still has `ingress.yaml`
3. Both repos still ship `urbalurba-scripts/` with obsolete registration scripts replaced by `uis argocd register/remove/list/verify`
4. README files reference both `ingress.yaml` and `urbalurba-scripts/`

Repos should only contain `deployment.yaml` and `kustomization.yaml` in their manifests.

---

## Phase 1: Clean up hello-world repo (test first) — ✅ DONE

**Repo:** `urb-dev-typescript-hello-world` (`/Users/terje.christensen/learn/projects-2026/urb-family/dev-templates/urb-dev-typescript-hello-world`)

Do this first so we can push, register, and verify the platform IngressRoute works without any repo-level ingress.

### Tasks

- [x] 1.1 Delete `manifests/ingress.yaml` (Traefik IngressRoute routing `urb-dev-typescript-hello-world.localhost` — redundant now that the platform routes `hello-world.localhost`)
- [x] 1.2 Edit `manifests/kustomization.yaml` — remove `- ingress.yaml` from the `resources:` list
- [x] 1.3 Delete `urbalurba-scripts/` directory (contains obsolete `register-argocd.sh`, `remove-argocd.sh`, `check-deployment.sh`, `setup-local-dns.sh` and `.bat` equivalents)
- [x] 1.4 Edit `README-typescript-basic-webserver.md` — remove `ingress.yaml` from the file structure tree
- [x] 1.5 Commit and push to GitHub (commit 223cef6)

### Validation

After pushing:

```bash
uis argocd remove hello-world
uis argocd register hello-world https://github.com/terchris/urb-dev-typescript-hello-world
# Wait for ArgoCD sync
kubectl get ingressroute -n hello-world
# Should show only hello-world-ingressroute (platform-managed), no repo-level IngressRoute
curl http://hello-world.localhost
# Should return app response via platform IngressRoute
```

User confirms ArgoCD shows app as healthy and synced (no missing `ingress.yaml` errors).

---

## Phase 2: Clean up all 7 templates — ✅ DONE

**Repo:** `urbalurba-dev-templates` (`/Users/terje.christensen/learn/projects-2026/urb-family/urbalurba-dev-templates`)

Only proceed after Phase 1 verification passes.

### Tasks

- [x] 2.1 Delete `ingress.yaml` from all 7 templates
- [x] 2.2 Edit `kustomization.yaml` in all 7 templates — remove `- ingress.yaml` from the `resources:` list
- [x] 2.3 Delete `urbalurba-scripts/` directory at repo root
- [x] 2.4 Edit all 7 template README files — remove `ingress.yaml` from file structure trees
- [x] 2.5 Edit root `README.md` — removed urbalurba-scripts section, updated registration instructions
- [x] 2.6 Commit and push to GitHub (commit 56c96d9)

### Validation

User confirms changes look correct and README accurately reflects the new workflow.

---

## Acceptance Criteria

- [x] `urb-dev-typescript-hello-world` deploys and routes correctly with only `deployment.yaml` and `kustomization.yaml` (no `ingress.yaml`) — verified Round 7/8
- [x] ArgoCD syncs the hello-world app without errors — verified Round 7
- [x] `curl http://hello-world.localhost` returns app response via platform IngressRoute — verified Round 8
- [x] No `ingress.yaml` in any of the 7 templates — commit 56c96d9
- [x] No `urbalurba-scripts/` directory in either repo — commits 223cef6 and 56c96d9
- [x] All README files updated — no references to removed files or obsolete scripts

---

## Out of Scope (tracked elsewhere)

| Item | Where tracked |
|------|---------------|
| Restore `replace_placeholders()` in `dev-template.sh` | [devcontainer-toolbox#67](https://github.com/terchris/devcontainer-toolbox/issues/67) |
| Remove `urbalurba-scripts/` copy block in `dev-template.sh` | [devcontainer-toolbox#67](https://github.com/terchris/devcontainer-toolbox/issues/67) |

---

## Files to Modify

### Phase 1 — `urb-dev-typescript-hello-world`

| File | Action |
|------|--------|
| `manifests/ingress.yaml` | Delete |
| `manifests/kustomization.yaml` | Edit — remove ingress.yaml from resources |
| `urbalurba-scripts/` | Delete directory |
| `README-typescript-basic-webserver.md` | Edit — remove ingress from file tree |

### Phase 2 — `urbalurba-dev-templates`

| File | Action |
|------|--------|
| `templates/*/manifests/ingress.yaml` (7 files) | Delete |
| `templates/*/manifests/kustomization.yaml` (7 files) | Edit — remove ingress.yaml from resources |
| `urbalurba-scripts/` | Delete directory |
| `templates/*/README-*.md` (7 files) | Edit — remove ingress from file tree |
| `README.md` | Edit — remove urbalurba-scripts section, update registration instructions |
