# PLAN: Documentation Gap Filling

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Created**: 2026-03-17
**Status:** Completed (2026-03-17)
**Parent**: [INVESTIGATE: Old System Cleanup & Documentation Gaps](../completed/INVESTIGATE-old-system-cleanup.md)

## Goal

Fill the remaining documentation gaps identified in investigation #20: CI/CD pipeline reference, integration testing guide, service override customization, stack creation, and getting-started path improvements.

---

## Why

Contributors working on the platform need to know:
- What CI/CD workflows exist and which files are auto-generated (so they don't manually edit them)
- How to run the full test suite and add verify tests for new services
- How service overrides work for customization

Users need to know:
- How to customize services without modifying core files
- How to create and use custom stacks

Both audiences benefit from a more complete getting-started path.

---

## What Exists Today

| Topic | Current State |
|-------|--------------|
| **CI/CD workflows** | 5 workflows in `.github/workflows/`, not documented anywhere. Contributors don't know what triggers auto-generation or which files are auto-generated. |
| **Integration testing** | `./uis test-all` works, `integration-testing.sh` orchestrates it. Only mentioned in CLI reference (4-line table) and one line in adding-a-service guide. No dedicated page. |
| **Service overrides** | `.uis.extend/service-overrides/` directory exists (empty, `.gitkeep`). Template README mentions "Place custom configuration files in `service-overrides/`" — no examples, no explanation of what can be overridden. |
| **Stack creation** | 3 stacks defined in `stacks.sh`. CLI commands documented. No guide on adding a custom stack. |
| **Getting-started path** | 5 pages: overview, installation, architecture, infrastructure, services. Good flow but `infrastructure.md` overlaps with `architecture.md`, and no "next steps after first deploy" guidance. |

---

## Phases

### Phase 1: CI/CD Pipeline and Generator Reference (contributor-facing)

Write a new page documenting the repo's own GitHub Actions workflows and generator scripts.

**Location**: `website/docs/contributors/guides/ci-cd-and-generators.md`

#### Tasks

- [x] 1.1 Create the page with sections for each workflow
- [x] 1.2 Add a section documenting the 4 generator scripts
- [x] 1.3 Add a clear list of auto-generated files that contributors should NOT manually edit
- [x] 1.4 Add sidebar entry in the Contributors section
- [x] 1.5 Add cross-link from `contributors/rules/kubernetes-deployment.md`

#### Validation

`npm run build` passes. User confirms content is accurate.

---

### Phase 2: Integration Testing Guide (contributor-facing)

Write a new page documenting how `./uis test-all` works and how to add tests for new services.

**Location**: `website/docs/contributors/guides/integration-testing.md`

#### Tasks

- [x] 2.1 Create the page covering test-all, integration-testing.sh, verify playbooks, flags, and how to add tests
- [x] 2.2 Add sidebar entry in the Contributors section
- [x] 2.3 Add cross-link from `contributors/guides/adding-a-service.md` Step 5b

#### Validation

`npm run build` passes. User confirms content is accurate.

---

### Phase 3: Service Override Customization (user-facing)

Document how users can customize service deployments without modifying core files.

**Location**: `website/docs/guides/customizing-services.md` (or appropriate user-facing location — check existing `docs/guides/` structure)

#### Tasks

- [x] 3.1 Investigate how overrides actually work — **finding: not implemented**. No Ansible playbook reads from `service-overrides/`. The directory was a placeholder.
- [x] 3.2 Removed the unused `service-overrides/` directory and `.gitkeep` from `templates/uis.extend/`
- [x] 3.3 Updated `provision-host/uis/templates/uis.extend/README.md` — removed service-overrides reference
- [x] 3.4 Updated `getting-started/overview.md`, `installation.md`, and `architecture.md` — removed "service configuration overrides" wording

#### Validation

`npm run build` passes. User confirms content is accurate and examples work.

---

### Phase 4: Stack Creation Guide (contributor-facing)

Document how to define custom stacks in `stacks.sh`.

**Location**: Add a section to `contributors/rules/kubernetes-deployment.md` or create a separate guide if the content is substantial.

#### Tasks

- [x] 4.1 Document the stack definition format (pipe-delimited fields, all 11 positions)
- [x] 4.2 Show a step-by-step example of adding a new stack
- [x] 4.3 Explain service order, optional services, STACK_ORDER array, and testing
- [x] 4.4 Add cross-link from the stacks section in `advanced/how-deployment-works.md`

#### Validation

`npm run build` passes. User confirms content is accurate.

---

### Phase 5: Getting-Started Path Improvements

Review and improve the flow from install → first deploy → understanding the system.

#### Tasks

- [x] 5.1 Review overlap between `infrastructure.md` and `architecture.md` — `infrastructure.md` is older/redundant but left as-is to avoid breaking links. Architecture is the primary reference.
- [x] 5.2 Enhanced "Next Steps" in `overview.md` — added "Deploy something useful" with database, observability, and AI stack suggestions
- [x] 5.3 Added "Learn More" section to `architecture.md` linking to `how-deployment-works.md`
- [x] 5.4 `npm run build` passes — all links verified

#### Validation

`npm run build` passes. User confirms the getting-started flow reads well end-to-end.

---

### Phase 6: Update investigation and roadmap

#### Tasks

- [x] 6.1 Mark "Plan area: Documentation gap filling" as COMPLETED in `INVESTIGATE-old-system-cleanup.md` with link to this plan
- [x] 6.2 Update `STATUS-platform-roadmap.md` — investigation #20 is now fully complete
- [x] 6.3 Move investigation #20 from "Open Investigations" to "Completed" in the roadmap

#### Validation

User confirms updates are correct.

---

## Acceptance Criteria

- [x] CI/CD and generator reference page exists in contributors section
- [x] Integration testing guide exists in contributors section
- [x] Service override customization is documented (or limitations clearly noted)
- [x] Stack creation is documented
- [x] Getting-started path has no dead ends or confusing overlaps
- [x] `npm run build` passes with zero broken links throughout
- [x] Investigation #20 is fully completed in the roadmap

---

## Files to Create

```
website/docs/contributors/guides/ci-cd-and-generators.md
website/docs/contributors/guides/integration-testing.md
website/docs/guides/customizing-services.md          # Location TBD based on Phase 3 investigation
```

## Files to Modify

```
website/sidebars.ts                                    # Add new pages to sidebar
website/docs/contributors/rules/kubernetes-deployment.md  # Stack creation section + cross-links
website/docs/contributors/guides/adding-a-service.md      # Cross-link to testing guide
website/docs/advanced/how-deployment-works.md              # Cross-link to stack creation
website/docs/getting-started/overview.md                   # Next steps section
website/docs/getting-started/architecture.md               # Link to how-deployment-works
website/docs/getting-started/infrastructure.md             # Consolidate/distinguish from architecture
provision-host/uis/templates/uis.extend/README.md          # Better override docs
website/docs/ai-developer/plans/backlog/INVESTIGATE-old-system-cleanup.md  # Mark complete
website/docs/ai-developer/plans/backlog/STATUS-platform-roadmap.md         # Update roadmap
```
