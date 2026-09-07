# PLAN: "How Deployment Works" Documentation Page

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Created**: 2026-03-17
**Status:** Completed (2026-03-17)
**Parent**: [INVESTIGATE: Old System Cleanup & Documentation Gaps](../completed/INVESTIGATE-old-system-cleanup.md)

## Goal

Write a user-facing "How Deployment Works" page in `docs/advanced/` that explains the full execution flow from `./uis deploy` to running pods — bridging the gap between the high-level overview in `contributors/architecture/deploy-system.md` and the contributor-level rules in `contributors/rules/kubernetes-deployment.md`.

---

## Why

Users who want to understand what happens when they run `./uis deploy` have no single page that explains the flow end-to-end. The contributor docs cover the rules and conventions, but a user who just wants to understand the system (without contributing) has to piece it together from multiple files. This page gives them one place to read.

---

## What Exists Today

| Document | Audience | What it covers |
|----------|----------|---------------|
| `contributors/architecture/deploy-system.md` | Users | High-level overview: commands, categories, dependencies, debugging. No internals. |
| `contributors/rules/kubernetes-deployment.md` | Contributors | Full technical spec: metadata fields, scanner, deploy flow diagram, stacks, autostart. |
| `contributors/guides/adding-a-service.md` | Contributors | 11-step guide for adding a service. |

**The gap:** No user-facing page explains the execution flow, priority ordering, dependency resolution, health checks, or how stacks work under the hood.

---

## What the New Page Will Cover

The page goes in `website/docs/advanced/how-deployment-works.md` and covers:

1. **The execution flow** — what happens step-by-step when you run `./uis deploy <service>`:
   - Service scanner discovers `provision-host/uis/services/` and locates the service definition
   - Metadata file is sourced to load all `SCRIPT_*` variables
   - Dependencies checked via `SCRIPT_REQUIRES` (each dependency verified with its `SCRIPT_CHECK_COMMAND`)
   - Deployment executed: `SCRIPT_PLAYBOOK` → `ansible-playbook` or `SCRIPT_MANIFEST` → `kubectl apply`
   - Post-deploy health check via `SCRIPT_CHECK_COMMAND`
   - Service auto-enabled in `enabled-services.conf`

2. **Deploy-all flow** — what `./uis deploy` (no argument) does:
   - Reads `enabled-services.conf`
   - Deploys each service in listed order
   - Stops on first failure

3. **Priority ordering** — how `SCRIPT_PRIORITY` controls deployment order (lower = earlier, default 50)

4. **Dependency resolution** — how `SCRIPT_REQUIRES` works:
   - Space-separated list of service IDs
   - Each dependency is verified by running its `SCRIPT_CHECK_COMMAND`
   - Deployment fails fast if any dependency is missing

5. **Health checks** — how `SCRIPT_CHECK_COMMAND` verifies deployment:
   - Runs after a 2-second delay post-deploy
   - Failure is a warning, not a hard error
   - Typically checks for Running pods via kubectl

6. **Stacks** — how stacks group services:
   - Defined in `lib/stacks.sh`
   - Install deploys left-to-right (dependencies first)
   - Remove undeploys in reverse order
   - `--skip-optional` flag for optional services
   - Available stacks: observability, ai-local, analytics

7. **Undeploy flow** — three-tier removal strategy:
   - `SCRIPT_REMOVE_PLAYBOOK` if set
   - `SCRIPT_MANIFEST` kubectl delete if set
   - Warning if no removal method found

8. **Autostart** — how `enabled-services.conf` works with `enable`, `disable`, `sync`

9. **Service metadata field reference** — brief explanation of the key deployment fields (`SCRIPT_ID`, `SCRIPT_PLAYBOOK`, `SCRIPT_REQUIRES`, `SCRIPT_PRIORITY`, `SCRIPT_CHECK_COMMAND`) with a prominent link to the complete field reference in `contributors/rules/kubernetes-deployment.md` (which has the full table of all metadata fields, constraints, and groups)

10. **Cross-references** to:
    - `contributors/rules/kubernetes-deployment.md` for the complete service metadata specification
    - `contributors/guides/adding-a-service.md` for creating new services
    - `reference/uis-cli-reference.md` for command details

---

## Scope

### What changes

| Area | What |
|------|------|
| New file | `website/docs/advanced/how-deployment-works.md` |
| Sidebar | Add entry in `advanced/` section (via `_category_.json` or `sidebars.ts`) |
| Cross-links | Add link from `contributors/architecture/deploy-system.md` "Related Documentation" section |
| Cross-links | Add link from `getting-started/overview.md` if appropriate |

### What does NOT change

- No code changes — this is pure documentation
- No changes to contributor docs (they stay as the authoritative reference)
- No changes to CLI or deployment system

---

## Phases

### Phase 1: Write the documentation page

#### Tasks

- [x] 1.1 Create `website/docs/advanced/how-deployment-works.md` with all sections listed above
- [x] 1.2 Include a flow diagram (text-based, using code blocks) showing the deploy sequence
- [x] 1.3 Include a table of current stacks with their services
- [x] 1.4 Include examples showing real service metadata (e.g., PostgreSQL) to illustrate concepts

#### Validation

`cd website && npm run build` passes with no broken links. User confirms content is accurate and complete.

---

### Phase 2: Add cross-references

#### Tasks

- [x] 2.1 Add sidebar entry for the new page in `docs/advanced/` (check `_category_.json` or `sidebars.ts`)
- [x] 2.2 Add link to the new page from `contributors/architecture/deploy-system.md` "Related Documentation" section
- [x] 2.3 Check if `getting-started/overview.md` or `getting-started/architecture.md` should link to this page — architecture.md has no Related section and is high-level; left as-is

#### Validation

`cd website && npm run build` passes. All cross-links work. User confirms.

---

### Phase 3: Update investigation and roadmap

#### Tasks

- [x] 3.1 Mark "Plan area: How Deployment Works documentation" as COMPLETED in `INVESTIGATE-old-system-cleanup.md` with link to this plan
- [x] 3.2 Update `STATUS-platform-roadmap.md` — added strikethrough, plan link in Priority 0, and entry in Completed table

#### Validation

User confirms updates are correct.

---

## Acceptance Criteria

- [x] `website/docs/advanced/how-deployment-works.md` exists and covers all 10 topics listed above
- [x] Page is accessible in the docs sidebar under "Advanced"
- [x] `npm run build` passes with zero broken links
- [x] Cross-references added from at least `deploy-system.md`
- [x] Investigation file updated with completion link

---

## Files to Create

```
website/docs/advanced/how-deployment-works.md
```

## Files to Modify

```
website/docs/contributors/architecture/deploy-system.md    # Add cross-link
website/docs/ai-developer/plans/backlog/INVESTIGATE-old-system-cleanup.md  # Mark plan area complete
website/docs/ai-developer/plans/backlog/STATUS-platform-roadmap.md         # Update if needed
```
