# PLAN: Documentation Rewrite — Category Renames, Templates, and Service Pages

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Related**: [INVESTIGATE-documentation-rewrite](INVESTIGATE-documentation-rewrite.md)
**Created**: 2026-02-27
**Status:** Completed

**Goal**: Standardize all service documentation using a consistent template, rename categories to align with cloud provider terminology, and create foundation docs (CLI reference, dependency matrix). This rewrite becomes the prototype and specification for future auto-generated documentation.

**Last Updated**: 2026-02-27

**Priority**: Medium — improves developer experience and prepares for auto-generation

---

## Problem Summary

The documentation was written before the UIS CLI existed and is inconsistent:
- Service pages vary wildly (100–600+ lines, different structures)
- ~6 files reference old `./scripts/packages/` paths instead of `./uis` commands
- No standard template — new users get different experiences per service
- Category names don't align with cloud provider terminology
- Missing: CLI reference, dependency info, deploy/undeploy commands in most docs
- 3–4 services with scripts but no documentation page (whoami, gravitee, cloudflare-tunnel, tailscale-tunnel)

### Current State

| Metric | Count |
|--------|-------|
| Documentation package folders | 11 (includes mismatches) |
| Documentation markdown files | 42 |
| Service script categories | 9 |
| Service scripts | 26 |
| Services missing doc pages | 3–4 |

### Target State: 9 Categories

| Category | Package? | Services |
|----------|:--------:|----------|
| Observability | Yes | prometheus, loki, tempo, otel-collector, grafana |
| AI | Yes | openwebui, litellm, tika |
| Analytics | Yes | jupyterhub, spark, unity-catalog |
| Identity | Yes | authentik |
| Databases | No | postgresql, mysql, mongodb, qdrant, redis, elasticsearch |
| Management | No | argocd, pgadmin, redisinsight, nginx, whoami |
| Networking | No | traefik (doc-only), tailscale-tunnel, cloudflare-tunnel |
| Storage | No | storage-class-alias, hostpath-storage (doc-only) |
| Integration | No | rabbitmq, gravitee |

---

## Phase 1: Category Renames — Code Changes — DONE

All subsequent phases depend on the new names being in place. This phase renames folders, updates scripts, and fixes the sidebar.

### Renames

| Current | New | Type |
|---------|-----|------|
| `services/datascience/` | `services/analytics/` | Folder rename |
| `services/network/` | `services/networking/` | Folder rename |
| `services/authentication/` | `services/identity/` | Folder rename |
| `services/core/` → merge into `services/management/` | Move nginx, whoami | Service move |
| `services/queues/` | `services/integration/` | Folder rename |
| `services/search/` → merge into `services/databases/` | Move elasticsearch | Service move |
| `services/monitoring/` | `services/observability/` | Folder rename |
| gravitee from `services/management/` | `services/integration/` | Service move |

### Tasks

- [x] 1.1 Rename service folders and move scripts to new locations
- [x] 1.2 Update `SCRIPT_CATEGORY` value in all 26 service scripts to match new category names
- [x] 1.3 Rename documentation folders under `website/docs/services/`:
  - `datascience/` → `analytics/`
  - `authentication/` → `identity/`
  - `monitoring/` → `observability/`
  - `queues/` → `integration/`
  - `core/` → merge into `management/`
  - `search/` → merge into `databases/`
  - `development/` → merge into `management/` (argocd, templates)
  - Create `networking/` (new — for traefik, tailscale-tunnel, cloudflare-tunnel docs)
  - Create `storage/` (new — for storage-class-alias docs)
- [x] 1.4 Update all `_category_.json` files with new labels
- [x] 1.5 Update `website/sidebars.ts` to match new folder structure and labels
- [x] 1.6 Update `categories.sh`, `stacks.sh`, `paths.ts`, JSON data files
- [x] 1.7 Fix imports/references: services.json, categories.json, stacks.json, test files

### Validation

- [x] Docusaurus site builds successfully: `cd website && npm run build`
- [ ] `./uis list` shows services under correct new category names (requires container rebuild)
- [ ] All 26 services still deploy/undeploy correctly (requires container rebuild)

---

## Phase 2: Design Validation — Prototype 3 Service Pages — DONE

Rewrite 3 service pages at different complexity levels using the standard template from the investigation. Review the results before proceeding to all services.

### Standard Service Page Template

```markdown
---
title: <Service Name>
sidebar_label: <Service Name>
---

# <Service Name>

<One-sentence description>

| | |
|---|---|
| **Category** | <category name> |
| **Deploy** | `./uis deploy <id>` |
| **Undeploy** | `./uis undeploy <id>` |
| **Depends on** | <services or "None"> |
| **Required by** | <services or "None"> |
| **Helm chart** | `<chart>` <version or "unpinned"> |
| **Default namespace** | `<namespace>` |

## What It Does
## Deploy
## Verify
## Configuration
## Undeploy
## Troubleshooting
## Learn More
```

### Tasks

- [x] 2.1 Rewrite **whoami** page (simple — no dependencies, minimal config)
- [x] 2.2 Rewrite **redis** page (medium — used as dependency, secrets, common issues)
- [x] 2.3 Rewrite **authentik** page (complex — multi-service deps, blueprints, extensive config)
- [x] 2.4 Review prototypes — template works at all complexity levels. Minor adjustment: added Image row for manifest-only services (whoami), Helm chart row for Helm services.

### Validation

- [x] All 3 pages follow the same template structure
- [x] Info table is accurate (dependencies, namespace, helm chart)
- [x] Deploy/undeploy commands match actual `./uis` commands
- [x] Docusaurus builds cleanly

---

## Phase 3: Foundation Docs — DONE

Create new reference pages that don't exist today.

### Tasks

- [x] 3.1 Create `reference/uis-cli-reference.md` — 56+ commands across 13 categories
  - Container management: `start`, `stop`, `shell`, `build`
  - Service management: `list`, `deploy`, `undeploy`, `verify`
  - Secrets: `secrets status`, `secrets generate`
  - Testing: `test-all`, `test-all --dry-run`, `test-all --clean`
  - Service-specific: `tailscale expose/unexpose/verify`
  - Initialization: `init`, `provision`
- [x] 3.2 Create `reference/service-dependencies.md` with Mermaid graph, tables, deploy order
- [x] 3.3 Add sidebar entries for new reference pages

### Validation

- [x] CLI reference covers all commands from `uis-cli.sh`
- [x] Dependency graph matches actual `SCRIPT_REQUIRES` values across all 26 scripts
- [x] Docusaurus builds cleanly

---

## Phase 4: Rewrite All Service Pages

Apply the validated template to all remaining services. Work category by category.

### Tasks

- [ ] 4.1 **Databases** (6 services): postgresql, mysql, mongodb, qdrant, redis (done in Phase 2), elasticsearch
- [ ] 4.2 **Observability** (5 services): prometheus, loki, tempo, otel-collector, grafana
- [ ] 4.3 **AI** (3 services): openwebui, litellm, tika
- [ ] 4.4 **Analytics** (3 services): jupyterhub, spark, unity-catalog
- [ ] 4.5 **Identity** (1 service): authentik (done in Phase 2)
- [ ] 4.6 **Management** (5 services): argocd, pgadmin, redisinsight, nginx, whoami (done in Phase 2)
- [ ] 4.7 **Networking** (3 services): traefik (doc-only), tailscale-tunnel, cloudflare-tunnel
- [ ] 4.8 **Storage** (2 services): storage-class-alias, hostpath-storage (doc-only)
- [ ] 4.9 **Integration** (2 services): rabbitmq, gravitee

### Rules

- Preserve additional manual pages (e.g., `authentik-sso.md`, `postgresql-container.md`) — only rewrite the primary service page
- Remove old command references (`./scripts/packages/`) as each page is rewritten
- Keep deep-dive content (PromQL examples, blueprint syntax) as separate linked pages, not in the primary template

### Validation

- [ ] Every deployable service has exactly one primary page following the template
- [ ] No remaining references to old `./scripts/packages/` paths
- [x] Docusaurus builds cleanly

---

## Phase 5: Rewrite Index Pages

Standardize all category/package index pages using the two templates from the investigation:
- **Package index** (observability, AI, analytics, identity): deployment sequence, architecture diagram, service roles
- **Category index** (databases, management, networking, storage, integration): service comparison, selection guidance

### Tasks

- [ ] 5.1 Rewrite package index pages (4): observability, AI, analytics, identity
- [ ] 5.2 Rewrite category index pages (5): databases, management, networking, storage, integration
- [ ] 5.3 Remove or archive obsolete pages (e.g., `development/templates.md` if no longer relevant)

### Validation

- [ ] Package indexes include deployment sequence with commands
- [ ] Category indexes include service comparison/selection guidance
- [ ] Docusaurus builds cleanly with correct sidebar navigation

---

## Phase 6: Clean Up

- [ ] 6.1 Verify sidebar matches the 9-category structure exactly
- [ ] 6.2 Remove empty or orphaned doc folders
- [ ] 6.3 Full Docusaurus build — zero warnings, zero broken links
- [ ] 6.4 Update `INVESTIGATE-documentation-rewrite.md` status to Complete
- [ ] 6.5 Update this plan status to Complete, move to `completed/`

---

## Acceptance Criteria

- [ ] 9 categories with correct names (matching cloud provider terminology)
- [ ] All 26 service scripts have updated `SCRIPT_CATEGORY` values
- [ ] Every deployable service has a primary doc page following the standard template
- [ ] CLI reference page exists with all `./uis` commands documented
- [ ] Service dependency matrix page exists
- [ ] Package index pages show deployment sequence
- [ ] Category index pages show service comparison/selection guidance
- [ ] No references to old paths (`./scripts/packages/`, old category names)
- [ ] Docusaurus builds with zero broken links
- [ ] Doc-only services (traefik, storage) documented but clearly marked as platform-dependent

---

## Files to Modify

### Phase 1 — Category Renames

| Area | Files | Change |
|------|-------|--------|
| Service scripts | 26 files in `provision-host/uis/services/*/` | Rename folders, update SCRIPT_CATEGORY |
| Doc folders | 11 folders in `website/docs/services/` | Rename/merge to 9 |
| Sidebar | `website/sidebars.ts` | Update structure and labels |
| Category metadata | `_category_.json` files | Update labels |
| CLI | `provision-host/uis/manage/uis-cli.sh` | Update category display if hardcoded |

### Phase 2–5 — Documentation

| Area | Files | Change |
|------|-------|--------|
| Service pages | ~28 primary pages | Rewrite using template |
| Index pages | 9 index files | Rewrite using package/category templates |
| New pages | `reference/uis-cli-reference.md`, dependency matrix | Create |
| Additional pages | ~14 existing deep-dive pages | Keep, link from primary pages |
