# INVESTIGATE: Dev Template IngressRoute Cleanup After Platform-Managed Routing

**Status:** Completed — Ready for PLAN
**Created:** 2026-03-03
**Last Updated:** 2026-03-03
**Related to:** [PLAN-argocd-register-redesign](../completed/PLAN-argocd-register-redesign.md) (completed)
**Depends on:** Platform-managed IngressRoute (Phase 6 of the register redesign)

---

## Problem Statement

Now that `uis argocd register` creates a platform-managed IngressRoute (`HostRegexp(`<app_name>\..+`)`), repos no longer need to ship their own ingress manifests. Three things need updating:

1. **`urbalurba-dev-templates`** — 7 templates still include `ingress.yaml`
2. **`urb-dev-typescript-hello-world`** — the live test repo still has `ingress.yaml`
3. **`dev-template.sh`** — the devcontainer-toolbox script that initializes projects from templates

---

## Repos Involved

| Repo | Location | Role |
|------|----------|------|
| `urbalurba-dev-templates` | `/Users/terje.christensen/learn/projects-2026/urb-family/urbalurba-dev-templates` | Template source for all dev projects |
| `urb-dev-typescript-hello-world` | `/Users/terje.christensen/learn/projects-2026/urb-family/dev-templates/urb-dev-typescript-hello-world` | Live test repo generated from typescript template |
| `devcontainer-toolbox` | `/Users/terje.christensen/learn/projects-2026/urb-family/devcontainer-toolbox` | Dev environment with `dev-template.sh` that initializes projects from templates |

---

## Finding 1: Templates Still Ship `ingress.yaml`

All 7 templates in `urbalurba-dev-templates/templates/` have a `manifests/ingress.yaml` that creates a **standard Kubernetes Ingress** (not a Traefik IngressRoute):

```yaml
# templates/typescript-basic-webserver/manifests/ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: "{{REPO_NAME}}-ingress"
spec:
  rules:
    - host: "{{REPO_NAME}}.localhost"
      http:
        paths:
          - path: /
            backend:
              service:
                name: "{{REPO_NAME}}-service"
                port:
                  number: 80
```

And each template's `manifests/kustomization.yaml` includes it in the resources list:

```yaml
resources:
  - deployment.yaml
  - ingress.yaml
```

**Impact:** After the platform IngressRoute fix, this `ingress.yaml` is redundant. It creates a route for `<repo-name>.localhost` which duplicates (and may conflict with) the platform's `<app-name>.localhost` route.

**Templates affected:**
- `csharp-basic-webserver`
- `designsystemet-basic-react-app`
- `golang-basic-webserver`
- `java-basic-webserver`
- `php-basic-webserver`
- `python-basic-webserver`
- `typescript-basic-webserver`

---

## Finding 2: Hello-World Repo Uses Traefik IngressRoute (Not Standard Ingress)

The hello-world repo was manually changed from the template's standard Kubernetes Ingress to a Traefik IngressRoute:

```yaml
# urb-dev-typescript-hello-world/manifests/ingress.yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: "urb-dev-typescript-hello-world-ingressroute"
spec:
  entryPoints:
    - web
  routes:
    - match: HostRegexp(`urb-dev-typescript-hello-world\..+`)
      services:
        - name: "urb-dev-typescript-hello-world-service"
          port: 80
```

This routes `urb-dev-typescript-hello-world.localhost` (the repo name). The platform IngressRoute adds `hello-world.localhost` (the app name). Both coexist today, but the repo's `ingress.yaml` is no longer needed.

---

## Finding 3: `dev-template.sh` (v1.5.0) Does NOT Substitute Placeholders — Breaks Entire Deploy Chain

The current active version of `dev-template.sh` in `devcontainer-toolbox` copies template files as-is — it does **not** replace `{{REPO_NAME}}` and `{{GITHUB_USERNAME}}` placeholders.

Older versions of the script (found in `urbalurba-dev-templates/terchris/dev-template.sh` v1.1.0) have a `replace_placeholders()` function that does:

```bash
sed -e "s|{{GITHUB_USERNAME}}|$GITHUB_USERNAME|g" \
    -e "s|{{REPO_NAME}}|$REPO_NAME|g"
```

The old v1.1.0 called this function on all files in `manifests/*.yaml` and `.github/workflows/*.yaml` after copying template files.

**This breaks the entire deploy chain:**

1. **Template** has: `image: ghcr.io/{{GITHUB_USERNAME}}/{{REPO_NAME}}:latest`
2. **`dev-template.sh` v1.5.0** copies as-is — no substitution
3. **GitHub Actions workflow** runs sed to update the image tag:
   ```bash
   sed -i "s|image: ghcr.io/$GITHUB_USERNAME/$REPO_NAME:.*|...|" manifests/deployment.yaml
   ```
   At runtime this becomes `s|image: ghcr.io/terchris/urb-dev-typescript-hello-world:.*|...|` — but the file still has `ghcr.io/{{GITHUB_USERNAME}}/{{REPO_NAME}}:latest`. **The pattern doesn't match**, so the sed silently does nothing.
4. **ArgoCD** syncs from the repo → finds `{{REPO_NAME}}-deployment` as resource name → invalid Kubernetes name → **deployment fails**

Without placeholder substitution in `dev-template.sh`, neither the GitHub Actions workflow nor ArgoCD can function.

**This is a regression** from when the script was moved from `urbalurba-dev-templates` to `devcontainer-toolbox`.

---

## Finding 4: Two Registration Paths Exist

Templates ship `urbalurba-scripts/register-argocd.sh` which is the **old** registration path. It:
- Extracts `GITHUB_USERNAME` and `REPO_NAME` from git remote
- Calls a shell script inside the provision-host container
- Uses the repo name as the namespace

The **new** path is `uis argocd register <name> <repo-url>` which:
- Accepts an explicit app name (different from repo name)
- Calls the Ansible playbook
- Creates the platform IngressRoute

The old scripts should be removed or updated to call the new CLI.

---

## Finding 5: Name Duality (app_name vs repo_name)

There is a naming split in the system:

| Source | Names it controls |
|--------|-------------------|
| `app_name` (from `uis argocd register`) | Kubernetes namespace, ArgoCD app name, platform IngressRoute |
| `REPO_NAME` (baked into manifests) | Deployment name, Service name, container name, image name, labels |

This is by design — the register playbook reads the actual Service name from the namespace (task 27) rather than assuming it matches `app_name`. The platform IngressRoute then routes `<app_name>.localhost` to whatever service exists.

**This duality is acceptable** and doesn't need fixing. The user picks the access name (`hello-world`), the manifests define internal resource names (`urb-dev-typescript-hello-world-deployment`).

---

## Finding 6: README Files Reference `ingress.yaml` and `urbalurba-scripts/`

**Repo: `urbalurba-dev-templates`**

The root `README.md` has extensive references that need updating:
- References to `urbalurba-scripts/set-github-pat.sh`, `register-argocd.sh`, `check-deployment.sh`, `setup-local-dns.sh`
- A whole section "urbalurba-scripts Design and Functionality" with Mermaid diagrams describing the old registration flow
- `ingress.yaml` in the file tree listing and in the manifest description

All 7 template README files (`templates/*/README-*.md`) mention `ingress.yaml` in their file structure trees.

**Repo: `urb-dev-typescript-hello-world`**

`README-typescript-basic-webserver.md` mentions `ingress.yaml` in its file tree.

---

## Recommended Changes

### Change 1: Remove `ingress.yaml` from all 7 templates

**Repo:** `urbalurba-dev-templates`

For each template in `templates/*/manifests/`:
- Delete `ingress.yaml`
- Edit `kustomization.yaml` — remove `- ingress.yaml` from `resources:`

### Change 2: Remove `ingress.yaml` from hello-world repo

**Repo:** `urb-dev-typescript-hello-world`

- Delete `manifests/ingress.yaml`
- Edit `manifests/kustomization.yaml` — remove `- ingress.yaml` from `resources:`

### Change 3: Restore placeholder substitution in `dev-template.sh`

**Repo:** `devcontainer-toolbox`

The current v1.5.0 of `dev-template.sh` does not substitute `{{REPO_NAME}}` and `{{GITHUB_USERNAME}}` placeholders. This is a regression — v1.1.0 (in `urbalurba-dev-templates/terchris/dev-template.sh`) had a `replace_placeholders()` function that must be restored.

**Why this is critical:** Without substitution, the entire deploy chain is broken:
- `deployment.yaml` has invalid Kubernetes resource names (`{{REPO_NAME}}-deployment`)
- The GitHub Actions workflow's sed pattern expects resolved values (`ghcr.io/terchris/repo-name:*`) but finds unresolved placeholders (`ghcr.io/{{GITHUB_USERNAME}}/{{REPO_NAME}}:latest`) — the pattern doesn't match, so the image tag update silently fails
- ArgoCD cannot sync because the manifests contain invalid YAML values

**Files that need substitution** (after removing `ingress.yaml`):
- `manifests/deployment.yaml` — 8 occurrences of `{{REPO_NAME}}`, 2 of `{{GITHUB_USERNAME}}`
- `manifests/kustomization.yaml` — 2 occurrences of `{{REPO_NAME}}`, 2 of `{{GITHUB_USERNAME}}`
- `.github/workflows/urbalurba-build-and-push.yaml` — no template placeholders (uses `${{ github.repository }}` context variables at runtime)

**Implementation:** Restore the `replace_placeholders()` function from v1.1.0. Call it on `manifests/*.yaml` after `copy_template_files()` completes. The workflow file does not need substitution.

**Issue filed:** [devcontainer-toolbox#67](https://github.com/terchris/devcontainer-toolbox/issues/67) — assigned to the devcontainer-toolbox maintainer.

### Change 4: Remove `urbalurba-scripts/` entirely

The `urbalurba-scripts/` directory contains obsolete scripts that predate the `uis` CLI. All functionality is now handled by `uis argocd register/remove/list/verify`. Three places need cleanup:

**Repo: `urbalurba-dev-templates`**
- Delete `urbalurba-scripts/` directory (the source — contains `register-argocd.sh`, `register-argocd.bat`, `remove-argocd.sh`, `check-deployment.sh`, `check-deployment.bat`, `set-github-pat.sh`, `set-github-pat.bat`)

**Repo: `devcontainer-toolbox`**
- Remove the copy block in `dev-template.sh` (lines 363-368) that copies `urbalurba-scripts/` into new projects

**Repo: `urb-dev-typescript-hello-world`**
- Delete `urbalurba-scripts/` directory (already copied into this repo — contains register, remove, check-deployment, and setup-local-dns scripts)

### Change 5: Update README files

**Repo: `urbalurba-dev-templates`**
- Root `README.md` — remove the "urbalurba-scripts Design and Functionality" section, remove references to `register-argocd.sh`/`check-deployment.sh`/`set-github-pat.sh`/`setup-local-dns.sh`, remove `ingress.yaml` from file tree and manifest descriptions. Replace registration instructions with `uis argocd register`.
- All 7 template `README-*.md` files — remove `ingress.yaml` from file structure trees.

**Repo: `urb-dev-typescript-hello-world`**
- `README-typescript-basic-webserver.md` — remove `ingress.yaml` from file structure tree.

---

## Decisions Made

1. **Remove `ingress.yaml` from templates now.** No legacy to consider — system is not yet released. The platform IngressRoute handles all routing.

2. **Remove ingress entirely — do not replace with Traefik IngressRoute.** Routing is the platform's responsibility, not the repo's. The `uis argocd register` playbook creates the IngressRoute automatically. Repos should only contain their deployment and service.

3. **`dev-template.sh` placeholder substitution must be restored.** This is a regression, not a design choice. Without it, the entire deploy chain is broken: deployment.yaml has invalid resource names, the GitHub Actions sed can't match unresolved placeholders, and ArgoCD can't sync. The `replace_placeholders()` function from v1.1.0 needs to be restored in v1.5.0.

4. **Old `register-argocd.sh` scripts should be removed.** They call obsolete shell scripts that predate the Ansible playbook redesign. Developers use `uis argocd register` directly.

---

## Next Step

Create a PLAN document with implementation tasks for Changes 1, 2, and 4 (scoped to `urbalurba-dev-templates` and `urb-dev-typescript-hello-world`). Changes 3 and 4's devcontainer-toolbox part are tracked in [devcontainer-toolbox#67](https://github.com/terchris/devcontainer-toolbox/issues/67). No backward compatibility concerns — system is not yet released.
