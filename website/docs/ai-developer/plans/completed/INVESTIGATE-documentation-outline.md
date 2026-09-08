# INVESTIGATE: Documentation Site Restructure — Add "Developing and Deploying" Section

**Status:** Completed — PLAN implemented and verified
**Created:** 2026-03-04
**Last Updated:** 2026-03-04
**Related to:** [PLAN-dev-template-ingress-cleanup](../completed/PLAN-dev-template-ingress-cleanup.md) (completed)
**Plan:** [PLAN-documentation-outline](../completed/PLAN-documentation-outline.md)
**Depends on:** None

---

## Problem Statement

The documentation site at https://uis.sovereignsky.no has no section explaining how developers build and deploy their own applications on the platform. The current sidebar covers infrastructure setup (Getting Started, Hosts, Packages, Provision Host) and contributor guidelines, but nothing about the developer workflow: creating a project from a template, building with GitHub Actions, deploying with ArgoCD, and managing applications.

With the ArgoCD register redesign and platform-managed routing now complete, there is a clear developer workflow that needs to be documented.

---

## Current State

### Current sidebar structure

```
About UIS
Getting Started
  - Overview, Installation, Infrastructure, Services, Architecture
Hosts & Platforms
  - Rancher, Azure AKS, Azure MicroK8s, Multipass, Raspberry Pi, Cloud Init
Packages
  - Observability, AI, Analytics, Identity, Databases, Management, Networking, Storage, Integration
Provision Host
  - Rancher
Reference
  - CLI Reference, Service Dependencies, Documentation Index, Troubleshooting
Contributors
  - Rules & Standards, Architecture
```

### What's missing

There is no section for developers who want to:
1. Create a project from a dev template
2. Understand the CI/CD pipeline (GitHub Actions build, ArgoCD deploy)
3. Use `uis argocd register/remove/list` to manage their applications
4. Use the ArgoCD dashboard at `http://argocd.localhost`

The "Packages > Management > ArgoCD" page (`packages/management/argocd`) documents ArgoCD as an infrastructure package, not as a developer tool.

---

## Proposed Change

### New sidebar structure

```
About UIS
Getting Started
  - Overview, Installation, Infrastructure, Services, Architecture
Packages
  - (same subcategories)
Developing and Deploying                    ← NEW SECTION
  - Dev Templates                           ← NEW PAGE
  - Template Catalog                        ← NEW PAGE
  - ArgoCD Pipeline                         ← NEW PAGE
  - ArgoCD Commands                         ← NEW PAGE
  - ArgoCD Dashboard                        ← NEW PAGE
Advanced                                    ← RENAMED/RESTRUCTURED
  - Hosts & Platforms (moved from top-level)
  - Provision Host (moved from top-level)
Reference
Contributors
```

### Key changes

1. **New "Developing and Deploying" section** — 5 new pages for the developer workflow
2. **"Hosts & Platforms" and "Provision Host" moved under "Advanced"** — these are infrastructure-level topics, not needed by most developers
3. **"Packages" stays at top level** — developers need to browse available services

---

## Decisions

1. **Yes — move "Hosts & Platforms" and "Provision Host" under "Advanced".** These are infrastructure-level topics, not needed by most developers.

2. **Keep the ArgoCD package page (`packages/management/argocd`) as-is — it documents the software.** The new "Developing and Deploying" section documents how developers *use* ArgoCD. The package page covers deploy/undeploy/verify of ArgoCD itself (infrastructure concern). The new pages cover register/remove/list of developer apps (developer concern). Both coexist. Note: the package page command table was outdated (old `<repo>` syntax) — fixed in this session.

3. **List the templates we have with a link to the repo for the full list.** The Template Catalog page lists current templates inline (table with name, language, description) and links to `urbalurba-dev-templates` for the canonical list. This avoids documentation going stale when new templates are added.

4. **Reference section: needs minor cleanup.** Findings:
   - `factory-reset.md` exists in `website/docs/reference/` but is **not in the sidebar** — should be added
   - `documentation-index.md` is a master documentation index with links to all sections — may be redundant once the sidebar is restructured, but harmless to keep
   - `service-dependencies.md` has a useful Mermaid dependency graph — good where it is
   - `troubleshooting.md` references old scripts (`./troubleshooting/debug-cluster.sh`) that may not exist in the current structure — needs review in a separate investigation
   - Overall: add `factory-reset` to sidebar, leave the rest as-is for now

---

## Proposed Pages

### Page 1: Dev Templates

**Path:** `website/docs/developing/dev-templates.md`

**Content:** Explains the devcontainer-toolbox `dev-template.sh` command. How to initialize a new project from a template:

- Prerequisites (devcontainer-toolbox setup)
- Running `.devcontainer/dev/dev-template.sh`
- Selecting a template from the menu
- What gets created (project structure)
- Links to the devcontainer-toolbox repo

### Page 2: Template Catalog

**Path:** `website/docs/developing/template-catalog.md`

**Content:** Overview of all available templates with links to the `urbalurba-dev-templates` repo:

| Template | Language/Framework | Description |
|----------|-------------------|-------------|
| `typescript-basic-webserver` | TypeScript / Express | Simple Node.js web server |
| `python-basic-webserver` | Python / Flask | Simple Flask web server |
| `golang-basic-webserver` | Go / net/http | Simple Go web server |
| `java-basic-webserver` | Java / Spring Boot | Spring Boot web server |
| `csharp-basic-webserver` | C# / ASP.NET Core | ASP.NET Core web server |
| `php-basic-webserver` | PHP / built-in server | Simple PHP web server |
| `designsystemet-basic-react-app` | TypeScript / React + Vite | React app with Designsystemet |

Each entry links to the template's README in the `urbalurba-dev-templates` repo.

### Page 3: ArgoCD Pipeline

**Path:** `website/docs/developing/argocd-pipeline.md`

**Content:** Explains the full CI/CD pipeline with a Mermaid diagram:

1. **Developer** pushes code to GitHub
2. **GitHub Actions** (CI) builds Docker image, pushes to GHCR, updates image tag in `deployment.yaml`
3. **ArgoCD** (CD) detects the change in the repo, syncs manifests to the cluster
4. **Platform** creates IngressRoute for the app name, routing `<app-name>.localhost` to the service

Include a Mermaid sequence diagram showing:
```
Developer → GitHub → GitHub Actions → GHCR
                                     → deployment.yaml (updated tag)
                   → ArgoCD → Kubernetes cluster
                            → Platform IngressRoute
```

### Page 4: ArgoCD Commands

**Path:** `website/docs/developing/argocd-commands.md`

**Content:** How to use the `uis` CLI to manage ArgoCD applications:

- `uis argocd register <name> <repo-url>` — with examples, what happens (namespace creation, IngressRoute creation, sync)
- `uis argocd remove <name>` — what gets cleaned up
- `uis argocd list` — viewing registered apps
- `uis argocd verify` — health checks
- Common scenarios: registering a public repo, registering with a different name than the repo, re-registering after changes

### Page 5: ArgoCD Dashboard

**Path:** `website/docs/developing/argocd-dashboard.md`

**Content:** How to use the ArgoCD web UI at `http://argocd.localhost`:

- Accessing the dashboard
- Viewing application status (health, sync)
- Understanding sync states
- Manual sync and refresh
- Viewing deployment history
- Troubleshooting failed deployments from the UI

---

## Sidebar Changes

### `website/sidebars.ts` modifications

Move "Hosts & Platforms" and "Provision Host" under a new "Advanced" category. Add new "Developing and Deploying" category after "Packages".

```typescript
// After Packages section, add:
{
  type: 'category',
  label: 'Developing and Deploying',
  link: {
    type: 'generated-index',
    description: 'Create projects from templates and deploy to the cluster with ArgoCD.',
  },
  items: [
    'developing/dev-templates',
    'developing/template-catalog',
    'developing/argocd-pipeline',
    'developing/argocd-commands',
    'developing/argocd-dashboard',
  ],
},
// Rename/restructure:
{
  type: 'category',
  label: 'Advanced',
  link: {
    type: 'generated-index',
    description: 'Host configuration, platform setup, and infrastructure details.',
  },
  items: [
    // Move existing Hosts & Platforms items here
    // Move existing Provision Host items here
  ],
},
```

---

## Finding: Cross-Links Need Updating When Moving Files

17 files contain relative links to `../hosts/` or `../provision-host/`. Key pages:

- `reference/documentation-index.md` — 12 links to hosts pages
- `getting-started/infrastructure.md` — link to hosts overview
- `provision-host/rancher.md` — link to rancher-kubernetes host
- `ai-development/` — several completed plans reference hosts docs

**Not a blocker.** The site is not launched yet — no external URLs to preserve. When moving `hosts/` → `advanced/hosts/` and `provision-host/` → `advanced/provision-host/`, update all relative links in the 17 affected files.

---

## Impact Assessment

| Area | Impact |
|------|--------|
| New files | 5 markdown pages in `website/docs/developing/` |
| New directory | `website/docs/developing/` |
| Moved directories | `hosts/` → `advanced/hosts/`, `provision-host/` → `advanced/provision-host/` |
| Modified files | `website/sidebars.ts` + 17 files with cross-links to update |
| URL changes | Yes — `/docs/hosts/*` → `/docs/advanced/hosts/*`, `/docs/provision-host/*` → `/docs/advanced/provision-host/*` |
| External impact | None — site not launched yet |
| Other repos | None — all content references existing functionality |

---

## Recommendation

Proceed with creating a PLAN. The documentation gap is clear — developers have no guide for the template → build → deploy workflow. The 5 proposed pages cover the full developer journey. The sidebar restructure groups infrastructure topics under "Advanced" to keep the developer-facing sections prominent.

Start with the pages that have the most immediate value:
1. ArgoCD Commands (directly useful, references CLI we just updated)
2. ArgoCD Pipeline (explains the full flow)
3. Template Catalog (quick reference)
4. Dev Templates (how to get started)
5. ArgoCD Dashboard (supplementary)

---

## Next Step

- [x] Get user input on the proposed structure — all 4 decisions made
- [x] Create PLAN with implementation tasks for the 5 pages, sidebar restructure, and Reference section cleanup (add `factory-reset` to sidebar)
