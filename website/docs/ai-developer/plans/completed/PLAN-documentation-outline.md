# PLAN: Documentation Site Restructure — Add "Developing and Deploying" Section

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed

**Goal**: Add a "Developing and Deploying" section to the documentation site with 5 new pages covering the developer workflow from template to deployment, and restructure the sidebar to group infrastructure topics under "Advanced".

**Last Updated**: 2026-03-04

**Investigation**: [INVESTIGATE-documentation-outline](INVESTIGATE-documentation-outline.md)

---

## Problem Summary

The documentation site has no section explaining how developers build and deploy their own applications. Developers need to know how to:
1. Create a project from a dev template
2. Understand the CI/CD pipeline (GitHub Actions → GHCR → ArgoCD → cluster)
3. Use `uis argocd register/remove/list` commands
4. Use the ArgoCD dashboard

Additionally, "Hosts & Platforms" and "Provision Host" are top-level sections that are infrastructure-level topics — they should be grouped under "Advanced" to keep the sidebar developer-focused.

---

## Phase 1: Create the 5 new pages — ✅ DONE

Create `website/docs/developing/` directory and write the 5 new pages.

### Tasks

- [x] 1.1 Create `website/docs/developing/dev-templates.md`
- [x] 1.2 Create `website/docs/developing/template-catalog.md`
- [x] 1.3 Create `website/docs/developing/argocd-pipeline.md` (includes Mermaid sequence diagram)
- [x] 1.4 Create `website/docs/developing/argocd-commands.md`
- [x] 1.5 Create `website/docs/developing/argocd-dashboard.md`

### Validation

User confirms page content is accurate and complete.

---

## Phase 2: Move files and restructure sidebar — ✅ DONE

Move `hosts/` and `provision-host/` under `advanced/`, update `sidebars.ts`, and fix all cross-links.

### Tasks

- [x] 2.1 Create `website/docs/advanced/` directory
- [x] 2.2 Move `website/docs/hosts/` → `website/docs/advanced/hosts/`
- [x] 2.3 Move `website/docs/provision-host/` → `website/docs/advanced/provision-host/`
- [x] 2.4 Update relative links in all affected files (12 files updated)
- [x] 2.5 Update `website/sidebars.ts` — added "Developing and Deploying", created "Advanced", added factory-reset to Reference
- [x] 2.6 Update `docusaurus.config.ts` footer link from `/docs/hosts` to `/docs/advanced/hosts`
- [x] 2.7 Update `src/components/HomepageFeatures/index.tsx` link
- [x] 2.8 Fix stale plan reference in `INVESTIGATE-argocd-register-url-parsing.md`

### Validation

```bash
cd website && npm run build
```

Docusaurus build succeeds with no broken link warnings. User confirms sidebar structure looks correct.

---

## Phase 3: Verify and commit — ✅ DONE

### Tasks

- [x] 3.1 Verify all 5 new pages render correctly in the sidebar
- [x] 3.2 Verify "Advanced" section contains Hosts & Platforms and Provision Host
- [x] 3.3 Verify "Reference" section includes Factory Reset
- [x] 3.4 Verify no broken links in the build output
- [x] 3.5 Commit and push

### Validation

User confirms the site looks correct.

---

## Acceptance Criteria

- [x] 5 new pages exist in `website/docs/developing/`
- [x] "Developing and Deploying" section appears in sidebar after "Packages"
- [x] "Hosts & Platforms" and "Provision Host" appear under "Advanced"
- [x] "Factory Reset" appears in the "Reference" section
- [x] `npm run build` succeeds with no broken link errors
- [x] ArgoCD pipeline page has a Mermaid diagram showing the full CI/CD flow
- [x] Template catalog lists all 7 current templates with links to the repo
- [x] No cross-link breakage — all relative links updated

---

## Files to Modify

### New files

| File | Content |
|------|---------|
| `website/docs/developing/dev-templates.md` | Dev template usage guide |
| `website/docs/developing/template-catalog.md` | Template catalog with repo links |
| `website/docs/developing/argocd-pipeline.md` | CI/CD pipeline with Mermaid diagram |
| `website/docs/developing/argocd-commands.md` | UIS ArgoCD CLI usage guide |
| `website/docs/developing/argocd-dashboard.md` | ArgoCD web UI guide |

### Moved directories

| From | To |
|------|----|
| `website/docs/hosts/` | `website/docs/advanced/hosts/` |
| `website/docs/provision-host/` | `website/docs/advanced/provision-host/` |

### Modified files

| File | Change |
|------|--------|
| `website/sidebars.ts` | Add "Developing and Deploying", create "Advanced", add factory-reset to Reference |
| 17 files with cross-links | Update relative paths from `../hosts/` to `../advanced/hosts/` etc. |
