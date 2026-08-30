---
title: Creating Plans
sidebar_position: 3
---

# Implementation Plans

How we plan, track, and implement features and fixes.

**Related:** [WORKFLOW.md](WORKFLOW.md) - End-to-end flow from idea to implementation

---

## Before you write a real address into a plan

This repository is **public**, and plans are where working notes accumulate most easily.

Existing plans contain private-range addresses from the reference installation. Those were reviewed
and **deliberately accepted** on 2026-08-30 — see
[Secrets Management](../contributors/rules/secrets-management.md#decision-internal-addresses-already-in-this-repo-are-accepted)
for the decision and the reasoning.

**That acceptance covers what is already there. It is not a reason to add more.** Prefer a
placeholder such as `<postgres-host>`; keep real values in the private `home` repository and
reference them from here. A publicly routable address or anything credential-shaped is outside the
accepted boundary entirely and is the platform owner's call, not a plan author's.

## Folder Structure

```
website/docs/ai-developer/plans/
├── backlog/      # Approved plans waiting for implementation
├── active/       # Currently being worked on (max 1-2 at a time)
└── completed/    # Done - kept for reference
```

### Flow

```
Idea/Problem → PLAN file in backlog/ → active/ → completed/
                       ↓
              (or INVESTIGATE file first if unclear)
```

---

## File Types

### PLAN-*.md

For work that is **ready to implement**. The scope is clear, the approach is known.

**When to create:**
- Bug fix with known solution
- Feature request with clear requirements
- Infrastructure change with defined scope

**Naming Conventions:**

| Format | Use Case | Example |
|--------|----------|---------|
| `PLAN-<area>-<topic>.md` | Standalone plan, no specific order | `PLAN-service-postgresql-backup-cronjob.md` |
| `PLAN-<area>-<nnn>-<topic>.md` | Ordered sequence, indicates execution order | `PLAN-system-monitoring-001-foundation.md` |

See [Topical Area Prefix](#topical-area-prefix) below for the full naming convention (areas, sub-areas, topic rules).

#### Ordered Plans (PLAN-nnn-*)

When an investigation produces multiple related plans that should be executed in a specific order, use **three-digit numbering** to indicate the sequence:

```
PLAN-system-monitoring-001-foundation.md      # Must be done first (critical foundation)
PLAN-system-monitoring-002-prometheus-config.md   # Can start after 001
PLAN-system-monitoring-003-grafana-dashboards.md  # Depends on 002
PLAN-system-monitoring-004-alerting-rules.md      # Depends on 003
```

**Benefits of ordered numbering:**
- Clear execution sequence at a glance
- Dependencies are implicit in the number order
- Easy to track progress through a large initiative
- Files sort naturally in file explorers

**When to use ordered numbering:**
- Investigation produces 3+ related plans
- Plans have sequential dependencies
- Work is part of a larger initiative (e.g., monitoring stack overhaul)

**When NOT to use ordered numbering:**
- Standalone bug fix or small feature
- Plans can be executed in any order
- Single plan from an investigation

### Splitting Investigations into Multiple Plans

When an investigation covers a large initiative (e.g., deploying a new platform service with multiple phases), split it into separate ordered plans rather than one monolithic plan. Each plan should be independently completable and deliverable.

**How to split:**

1. **Group by dependency and risk** — phases that need different prerequisites (e.g., "no cluster needed" vs "requires running cluster") should be separate plans
2. **Group by completeness** — each plan should deliver something useful on its own, even if later plans aren't started yet
3. **Keep optional/deferred work separate** — don't mix required work with nice-to-haves in the same plan

**Example: Deploying a new service with catalog generation**

```
INVESTIGATE-service-backstage.md                    ← Research and decisions
  ↓ produces:
PLAN-service-backstage-001-metadata-and-generator.md  ← No cluster needed, low risk
PLAN-service-backstage-002-deployment.md              ← Cluster needed, medium risk
PLAN-service-backstage-003-auth-and-plugins.md        ← Optional, after deployment works
```

- **PLAN-001** adds metadata fields and builds the generator — pure code, no cluster, can be tested locally
- **PLAN-002** deploys Backstage following the adding-a-service guide — requires a running cluster
- **PLAN-003** adds Authentik SSO and extra plugins — optional, only if Authentik is deployed

Each plan references the investigation and the previous plan in its header:

```markdown
**Investigation**: [INVESTIGATE-service-backstage.md](./INVESTIGATE-service-backstage.md)
**Prerequisites**: PLAN-service-backstage-001-metadata-and-generator.md must be complete first
```

**Benefits:**
- Earlier plans can be completed and merged while later plans are still being refined
- Risk is isolated — a deployment failure in PLAN-002 doesn't block the metadata/generator work in PLAN-001
- Optional work (auth, plugins) can stay in backlog indefinitely without blocking core functionality
- Each plan is small enough to review and validate in one session

### INVESTIGATE-*.md

For work that **needs research first**. The problem exists but the solution is unclear.

**When to create:**
- Complex infrastructure where options need evaluation
- Bug with unknown root cause
- Feature requiring architectural decisions

**Naming:** see [Topical Area Prefix](#topical-area-prefix) below — same convention as `PLAN-*.md`.

**After investigation:** Create one or more PLAN files with the chosen approach.

---

## Topical Area Prefix

Both `INVESTIGATE-*.md` and `PLAN-*.md` follow the same naming shape:

```
<TYPE>-<AREA>[-<SUBAREA>]-<topic>.md
```

The **AREA** prefix is mandatory. It clusters related work together in alphabetical directory listings and makes it possible to see at a glance which surface a plan touches.

### Areas

| Area | What goes here | Sub-area shape |
|---|---|---|
| **service** | A specific named service (authentik, backstage, dagster, metabase, etc.) | `service-<name>` |
| **platform** | A specific cloud platform (AKS, GKE, EKS, microk8s on a VM) | `platform-<cloud>` |
| **network** | A specific networking provider (cloudflare, tailscale) | `network-<provider>` |
| **cli** | The `./uis <verb>` surface — anything that changes a UIS CLI command or its semantics | `cli-<verb>` (e.g., `cli-deploy`, `cli-status`) |
| **docs** | Documentation system, page hygiene, cross-doc consistency, doc generation | none |
| **secrets** | Secret templating + lifecycle (`.uis.secrets/*`, `00-master-secrets.yml.template`, etc.) | none |
| **templates** | UIS Template (stacks) — the user-facing application-template system | none |
| **system** | Cross-cutting infra (version pinning, host→platform migration, provisioning layer, remote targets) | none |

If a file genuinely touches multiple areas, **pick the area where the implementation work would land**. A docs-restructure of the AKS guide is `platform-aks`, not `docs`, because the file being edited lives under `platforms/`.

### Topic ("what it is")

After the area/sub-area prefix, describe the topic in kebab-case. Two soft rules:

1. **Lead with the distinctive thing**, not a generic word. Prefer `auto-regen-secrets` over `secrets-auto-regen`; prefer `multi-instance` over `status-gap`.
2. **End with a verb only when the action is non-obvious.** Useful suffixes: `-add`, `-fix`, `-audit`, `-restructure`, `-rename`. Don't add a verb just to add one.

Total filename length stays under ~60 characters so listings remain readable.

### Examples

```
INVESTIGATE-service-authentik-user-config.md
INVESTIGATE-service-backstage-auth.md
INVESTIGATE-service-dagster.md
INVESTIGATE-platform-aks-novice-onboarding.md
INVESTIGATE-network-tailscale-cross-cluster-backbone.md
INVESTIGATE-network-cloudflare-in-cluster-restructure.md
INVESTIGATE-cli-deploy-auto-regen-secrets.md
INVESTIGATE-cli-status-multi-instance.md
INVESTIGATE-cli-top-level-doc.md
INVESTIGATE-docs-services-in-cluster-port.md
INVESTIGATE-secrets-template-defaults-clarity.md
INVESTIGATE-templates-first-uis-template.md
INVESTIGATE-system-version-pinning.md
INVESTIGATE-system-remote-deployment-targets.md
PLAN-platform-aks-destroy-kubeconfig-cleanup.md
PLAN-network-cloudflare-port-and-docs-lift-up.md
```

For **ordered plan series**, the number goes *after* the area so related plans cluster in alphabetical sort:

```
PLAN-platform-aks-001-bootstrap.md
PLAN-platform-aks-002-secrets-apply-parity.md
PLAN-platform-aks-003-post-apply.md
```

This supersedes the older `PLAN-001-<area>-<topic>.md` shape — the area-first form keeps a plan series clustered with the rest of its area's work in a directory listing.

---

## Plan Structure

Every plan has these sections:

### 1. Header (Required)

```markdown
# Plan Title

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog | Active | Blocked | Completed

**Goal**: One sentence describing what this achieves.

**Last Updated**: 2026-01-18

**GitHub Issue**: #42 (optional - if tracking with issues)
```

The **IMPLEMENTATION RULES** blockquote ensures Claude Code reads the workflow and plan guidelines before starting work.

### 2. Dependencies (If applicable)

```markdown
**Prerequisites**: PLAN-001 must be complete first
**Blocks**: PLAN-003 cannot start until this is done
**Priority**: High | Medium | Low
```

For ordered plans (PLAN-nnn-*), dependencies are often implicit in the number order. Only add explicit dependency notes when the relationship is non-obvious.

### 3. Problem Summary (Required)

What's wrong or what's needed. Be specific.

### 4. Phases with Tasks (Required)

Break work into phases. Each phase has:
- Numbered tasks
- A validation step at the end (usually user confirmation)

```markdown
## Phase 1: Setup

### Tasks

- [ ] 1.1 Create the ConfigMap
- [ ] 1.2 Add validation rules
- [ ] 1.3 Test with dry-run

### Validation

User confirms phase is complete.

---

## Phase 2: Implementation

### Tasks

- [ ] 2.1 Create the deployment manifest
- [ ] 2.2 Add the service manifest
- [ ] 2.3 Apply and verify deployment

### Validation

User confirms deployment works correctly.
```

### 5. Acceptance Criteria (Required)

```markdown
## Acceptance Criteria

- [ ] Manifests apply without errors
- [ ] Pods are running and healthy
- [ ] Service is accessible
- [ ] Documentation is updated
```

### 6. Implementation Notes (Optional)

Technical details, gotchas, code patterns to follow.

### 7. Files to Modify (Optional but helpful)

```markdown
## Files to Modify

- `manifests/250-new-service.yaml`
- `docs/services/new-service.md`
```

---

## Status Values

| Status | Meaning | Location |
|--------|---------|----------|
| `Backlog` | Approved, waiting to start | `plans/backlog/` |
| `Active` | Currently being worked on | `plans/active/` |
| `Blocked` | Waiting on something else | `plans/backlog/` or `plans/active/` |
| `Completed` | Done | `plans/completed/` |

---

## Updating Plans During Implementation

**Critical:** Plans are living documents. Update them as you work.

### When starting a phase:

```markdown
## Phase 2: Implementation — IN PROGRESS
```

### When completing a task:

```markdown
- [x] 2.1 Update the manifest ✓
- [ ] 2.2 Add the service
```

### When a phase is done:

```markdown
## Phase 2: Implementation — ✅ DONE
```

### When blocked:

```markdown
## Status: Blocked

**Blocked by**: Waiting for decision on approach
```

### When complete:

1. Update status: `## Status: Completed`
2. Add completion date: `**Completed**: 2026-01-18`
3. Move file: `mv website/docs/ai-developer/plans/active/PLAN-xyz.md website/docs/ai-developer/plans/completed/`
4. (Optional) Close GitHub issue if using issue tracking

---

## Validation

Every phase ends with validation. The simplest form is asking the user to confirm.

### Default: User Confirmation

Claude asks: "Phase 1 complete. Does this look good to continue?"

In the plan, this can be written as:

```markdown
### Validation

User confirms phase is complete.
```

### Optional: Automated Check

When a command can verify the work, include it:

```markdown
### Validation

```bash
kubectl apply --dry-run=client -f manifests/xxx-new-service.yaml
kubectl get pods -n namespace -l app=new-service
```

User confirms output is correct.
```

### Key Point

Don't force automated validation when it's impractical. User confirmation is valid and often the best approach.

---

## Plan Templates

### Simple Bug Fix

```markdown
# Fix: [Bug Description]

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

**Goal**: [One sentence]

**GitHub Issue**: #XX (optional)

**Last Updated**: YYYY-MM-DD

---

## Problem

[What's broken]

## Solution

[How to fix it]

---

## Phase 1: Fix

### Tasks

- [ ] 1.1 [Specific change]
- [ ] 1.2 [Another change]

### Validation

User confirms fix is correct.

---

## Acceptance Criteria

- [ ] Bug is fixed
- [ ] No regressions
- [ ] Manifests apply cleanly
```

### Feature Implementation

```markdown
# Feature: [Feature Name]

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

**Goal**: [One sentence]

**GitHub Issue**: #XX (optional)

**Last Updated**: YYYY-MM-DD

---

## Overview

[What this feature does and why]

---

## Phase 1: [Setup/Preparation]

### Tasks

- [ ] 1.1 [Task]
- [ ] 1.2 [Task]

### Validation

User confirms phase is complete.

---

## Phase 2: [Core Implementation]

### Tasks

- [ ] 2.1 [Task]
- [ ] 2.2 [Task]

### Validation

User confirms phase is complete.

---

## Acceptance Criteria

- [ ] [Criterion]
- [ ] Deployment succeeds
- [ ] Services are accessible
- [ ] Documentation updated

---

## Files to Modify

- `manifests/xxx-new-feature.yaml`
```

### Investigation

```markdown
# Investigate: [Topic]

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

**Goal**: Determine the best approach for [topic]

**Last Updated**: YYYY-MM-DD

---

## Questions to Answer

1. [Question 1]
2. [Question 2]

---

## Current State

[What exists now]

---

## Options

### Option A: [Name]

**Pros:**
-

**Cons:**
-

### Option B: [Name]

**Pros:**
-

**Cons:**
-

---

## Recommendation

[After investigation, what do we do?]

---

## Next Steps

- [ ] Create PLAN-xyz.md with chosen approach
  - For multiple related plans, use ordered naming: PLAN-001-*, PLAN-002-*, etc.
```

---

## Working with Claude Code

See [WORKFLOW.md](WORKFLOW.md) for the complete flow from idea to implementation.

---

## Best Practices

1. **One active plan at a time** - finish before starting another
2. **Small phases** - easier to validate and recover from errors
3. **Specific tasks** - "Update line 42 in manifests/xyz.yaml" not "Fix the thing"
4. **Runnable validation** - commands, not descriptions
5. **Update as you go** - the plan is the source of truth
6. **Keep completed plans** - they're documentation
7. **Check existing lib/ before creating new code** - see [Library Reuse Rules](#library-reuse-rules) below

---

## Library Reuse Rules

**CRITICAL:** Before writing any new code in `provision-host/uis/lib/`, you MUST:

### 1. Check Existing Libraries

Review these files for existing functionality:

| Library | Purpose |
|---------|---------|
| `paths.sh` | **All path detection** - TEMPLATES_DIR, EXTEND_DIR, SECRETS_DIR, etc. |
| `utilities.sh` | Base utilities - get_base_path(), die(), config_* functions |
| `logging.sh` | All logging - log_info(), log_error(), print_section() |
| `first-run.sh` | Initialization - check_first_run(), generate_ssh_keys() |

### 2. Use Existing Functions

**DO NOT** create duplicate path functions. Use `paths.sh`:

```bash
# Good - use paths.sh functions
source "$LIB_DIR/paths.sh"
templates_dir=$(get_templates_dir)
secrets_dir=$(get_secrets_dir)

# Bad - creating your own path detection
_my_detect_templates_dir() { ... }  # WRONG!
```

### 3. If New Functionality is Needed

Ask these questions before creating new functions:

1. Does this already exist in another library?
2. Should this be added to an existing library instead?
3. Will multiple libraries need this? → Add to shared library
4. Is this truly specific to this feature? → OK to add locally

### 4. Centralized Path Functions

All paths are managed by `paths.sh`. Available functions:

```bash
get_templates_dir()           # provision-host/uis/templates/
get_extend_dir()              # .uis.extend/
get_secrets_dir()             # .uis.secrets/
get_services_dir()            # provision-host/uis/services/
get_tools_dir()               # provision-host/uis/tools/
get_hosts_templates_dir()     # templates/uis.extend/hosts/
get_secrets_templates_dir()   # templates/uis.secrets/
get_cloud_init_templates_dir() # templates/ubuntu-cloud-init/
```

### Why This Matters

Code duplication leads to:
- Inconsistent behavior (different functions return different values)
- Maintenance burden (fix bugs in multiple places)
- Confusion (which function should I use?)
