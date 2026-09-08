# PLAN: Delete Old Deployment System

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Created**: 2026-03-17
**Status:** Completed (2026-03-17)
**Parent**: [INVESTIGATE: Old System Cleanup & Documentation Gaps](../completed/INVESTIGATE-old-system-cleanup.md)
**Prerequisites**: [PLAN-rename-packages-to-services](../completed/PLAN-rename-packages-to-services.md) (completed)

## Goal

Delete the dead `provision-host/kubernetes/` folder (60 scripts, 6,149 lines), the legacy `provision` command, and `scripts/packages/` — removing all traces of the old deployment system that was replaced by the UIS CLI.

---

## Why

The migration to UIS CLI is complete — all 30 services deploy through `./uis deploy`. But the old system is still in the repo: 60 scripts in `provision-host/kubernetes/`, a `provision` command in both CLI wrappers, and 2 legacy scripts in `scripts/packages/`. Anyone reading the repo can't tell which system is real. Dead code undermines trust in documentation.

---

## Scope

### What gets deleted

| Area | Files | Lines |
|------|:-----:|:-----:|
| `provision-host/kubernetes/` | 60 scripts + orchestrator | ~6,149 |
| `scripts/packages/` | 2 scripts (`ai.sh`, `auth.sh`) | ~100 |
| `provision` command in `uis` | 4 lines (bash wrapper) | 4 |
| `provision` command in `uis.ps1` | 4 lines (PowerShell wrapper) | 4 |

### What gets updated

| Area | What |
|------|------|
| 6 doc files | Remove references to `provision-host/kubernetes/` paths |
| `docs/services/ai/environment-management.md` | Replace `./scripts/packages/ai.sh` references with `./uis` commands |
| `docs/services/identity/developer-guide.md` | Replace `./scripts/packages/auth.sh` references with `./uis` commands |

### What does NOT change

- UIS CLI (`provision-host/uis/`) — the active system, untouched
- Ansible playbooks (`ansible/playbooks/`) — still used by UIS
- Manifests (`manifests/`) — still used by UIS
- Container image build — Dockerfile does not execute `provision-kubernetes.sh`
- CI/CD workflows — none reference the old system

### Known breakage (accepted)

- `hosts/install-azure-microk8s-v2.sh` calls `provision-kubernetes.sh`. This script is already non-functional without a configured Azure VM. Tracked in [INVESTIGATE: Remote Deployment Targets](../backlog/INVESTIGATE-system-remote-deployment-targets.md) which will rewrite it to use UIS CLI.

---

## Phases

### Phase 1: Remove `provision` command from CLI wrappers

#### Tasks

- [x] 1.1 Remove the `provision)` case block from `uis` bash wrapper (~line 243)
- [x] 1.2 Remove the `"provision"` case block from `uis.ps1` PowerShell wrapper (~line 174)
- [x] 1.3 Remove `provision` from any help text or usage output in both wrappers

#### Validation

Verify `./uis --help` (or equivalent) no longer shows `provision`. User confirms.

---

### Phase 2: Delete `scripts/packages/` folder

#### Tasks

- [x] 2.1 Delete `scripts/packages/ai.sh`
- [x] 2.2 Delete `scripts/packages/auth.sh`
- [x] 2.3 Delete `scripts/packages/` directory
- [x] 2.4 Update `docs/services/ai/environment-management.md` — replace `./scripts/packages/ai.sh` references with equivalent `./uis` commands
- [x] 2.5 Update `docs/services/identity/developer-guide.md` — replace `./scripts/packages/auth.sh` references with equivalent `./uis` commands

#### Validation

Grep confirms no remaining references to `scripts/packages/` in active code or docs. User confirms.

---

### Phase 3: Delete `provision-host/kubernetes/` folder

#### Tasks

- [x] 3.1 Delete `provision-host/kubernetes/` entirely (all 13 category folders + `provision-kubernetes.sh`)
- [x] 3.2 Update `docs/reference/troubleshooting.md` — remove references to old paths
- [x] 3.3 Update `docs/advanced/hosts/azure-aks.md` — remove references to old paths
- [x] 3.4 Update `docs/advanced/hosts/index.md` — remove references to old paths
- [x] 3.5 Update `docs/contributors/rules/kubernetes-deployment.md` — remove references to old paths
- [x] 3.6 Update `docs/networking/tailscale-internal-ingress.md` — remove references to old paths
- [x] 3.7 Add a note to `hosts/install-azure-microk8s-v2.sh` that it is broken pending remote deployment target migration

#### Validation

`npm run build` passes. Grep confirms no remaining references to `provision-host/kubernetes/` in docs (except completed plan/investigation files). User confirms.

---

## Acceptance Criteria

- [x] `provision-host/kubernetes/` folder is deleted
- [x] `scripts/packages/` folder is deleted
- [x] `./uis provision` command no longer exists in either wrapper
- [x] No active documentation references `provision-host/kubernetes/` or `scripts/packages/` paths
- [x] `npm run build` passes with zero broken links
- [x] CI/CD pipelines pass (test-uis, build-container, deploy-docs)
- [x] `hosts/install-azure-microk8s-v2.sh` has a clear note about being broken pending migration

---

## Risks

- **Azure VM deployment breaks**: `hosts/install-azure-microk8s-v2.sh` calls `provision-kubernetes.sh`. Accepted — script was already non-functional without configured infrastructure. Tracked in separate investigation.
- **Someone relies on `./uis provision`**: Low risk — the command just ran the same playbooks that `./uis deploy` runs, and UIS has been the primary system for months. All documentation points to UIS commands.
- **Git history**: All deleted files remain in git history. No data is lost.

---

## Files to Delete

```
provision-host/kubernetes/                  # Entire folder (~60 files)
scripts/packages/ai.sh
scripts/packages/auth.sh
```

## Files to Modify

```
uis                                         # Remove provision command
uis.ps1                                     # Remove provision command
hosts/install-azure-microk8s-v2.sh          # Add broken/deprecated note
docs/reference/troubleshooting.md
docs/advanced/hosts/azure-aks.md
docs/advanced/hosts/index.md
docs/contributors/rules/kubernetes-deployment.md
docs/networking/tailscale-internal-ingress.md
docs/services/ai/environment-management.md
docs/services/identity/developer-guide.md
```
