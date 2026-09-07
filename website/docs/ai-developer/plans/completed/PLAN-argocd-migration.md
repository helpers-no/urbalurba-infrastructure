# PLAN: ArgoCD Migration Completion

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed

**Goal**: Complete ArgoCD migration to the UIS system — fix metadata, verify deployment with E2E tests, and document the devcontainer-toolbox integration path.

**Completed**: 2026-02-18

**Related to**: [INVESTIGATE-argocd-migration](./INVESTIGATE-argocd-migration.md), [STATUS-service-migration](STATUS-service-migration.md)

---

## Overview

ArgoCD was 95% migrated when this plan started. The deploy and remove playbooks worked, the Helm config and IngressRoute were in place. What remained was fixing metadata, verifying deployment, and adding E2E tests. During Phase 4 testing, the admin password setup required a complete rework (9 rounds of iteration), which also uncovered and fixed issues in the secrets framework and container dependencies.

### Testing Process

Deployment verification (Phase 2) requires a running cluster. The contributor (Claude Code) writes test instructions to `talk/talk.md` in the testing directory, and the tester executes them and reports results back in the same file. The contributor then reads `talk.md` to check results and iterates if needed.

**Talk file location**: The testing directory's `talk/talk.md` (e.g., `/Users/terje.christensen/learn/projects-2026/testing/uis1/talk/talk.md`)

---

## Phase 1: Metadata Fixes — ✅ DONE

### Tasks

- [x] 1.1 Set `SCRIPT_REMOVE_PLAYBOOK="220-remove-argocd.yml"` in `provision-host/uis/services/management/service-argocd.sh` ✓
- [x] 1.2 Fix `SCRIPT_DOCS` from `/docs/services/management/argocd` to `/docs/services/development/argocd` in the same file ✓

### Validation

User confirmed.

---

## Phase 2: Deployment Verification — ✅ DONE

Performed by the tester via `talk/talk.md` (Round 1).

### Tasks

- [x] 2.1 Write test instructions to `talk/talk.md` with deploy/verify/undeploy steps ✓
- [x] 2.2 Tester deploys ArgoCD: `./uis deploy argocd` ✓ (21 ok, 0 failed)
- [x] 2.3 Tester verifies ArgoCD server pod is running ✓ (all pods Running)
- [x] 2.4 Tester verifies ArgoCD UI is accessible at `argocd.localhost` ✓ (login page visible)
- [x] 2.5 Tester verifies admin login works — SKIPPED (tester recommends automated API test instead of manual browser login, valid feedback for future enhancement)
- [x] 2.6 Tester removes ArgoCD: `./uis undeploy argocd` ✓ (10 ok, 0 failed)
- [x] 2.7 Tester verifies clean removal ✓ ("No resources found in argocd namespace")
- [x] 2.8 Read `talk/talk.md` for tester results ✓

### Validation

Tester reported PASS on all steps (1 skipped). Deploy and undeploy both work correctly.

---

## Phase 3: Update Migration Status — ✅ DONE

### Tasks

- [x] 3.1 Update [STATUS-service-migration.md](STATUS-service-migration.md) — mark ArgoCD as fully migrated and verified ✓
- [x] 3.2 Check task 1.1 in Phase 1 of STATUS-service-migration.md ✓

### Validation

Status document updated: ArgoCD row shows ✅ across all columns, summary count 21/24.

---

## Phase 4: E2E Test Playbook — ✅ DONE

Following the pattern from Authentik (`070-test-authentik-auth.yml`), add an automated test playbook that verifies ArgoCD is working correctly.

### Tasks

- [x] 4.1 Create `ansible/playbooks/220-test-argocd.yml` with 4 test groups ✓
- [x] 4.2 Add call to test playbook from `220-setup-argocd.yml` ✓
- [x] 4.3 Rebuild container with new playbook ✓
- [x] 4.4 Write test instructions to `talk/talk.md` ✓
- [x] 4.5 Tester deploys ArgoCD and verifies E2E tests pass ✓ (Round 9 — all 4 tests passed)
- [x] 4.6 Read `talk/talk.md` for results. Iterated through Rounds 2-9. ✓

### Test Groups

| Test | What it verifies |
|------|-----------------|
| A — API Health Check | `/api/version` returns 200 with version info |
| B — Admin Login | `POST /api/v1/session` returns JWT token with correct credentials |
| C — UI via Traefik | `argocd.localhost` routes correctly through IngressRoute |
| D — Wrong Credentials | Bad password is rejected (no token returned) |

### Bugs fixed and changes made across Rounds 2-9

1. Echo newline in bcrypt hash — `echo` → `printf` (Round 2)
2. Helm overwriting pre-created `argocd-secret` (Round 4) — changed `manifests/220-argocd-config.yaml` from `createSecret: false` to `createSecret: true`, pass bcrypt hash via Helm values
3. `argocd-secret` in secrets framework conflicting with Helm (Round 5) — removed `argocd-secret` definition from `00-master-secrets.yml.template` (both `provision-host/uis/templates/` and `topsecret/` copies). Helm owns `argocd-secret` entirely.
4. Stale `.uis.secrets/` templates on tester host (Round 6) — manual re-copy from container
5. Ansible Jinja2/shell quoting conflict in debug lines (Round 7) — removed debug lines
6. Missing `htpasswd` in container (Round 8) — replaced with Python bcrypt, added `python3-bcrypt` to `Dockerfile.uis-provision-host`
7. Added fail-fast assertions for missing secrets and empty hash (Round 8)
8. Complete rework of password handling in `220-setup-argocd.yml` tasks 7-10: read plaintext from `urbalurba-secrets`, generate bcrypt hash via Python, write to temp values file, pass to Helm with `-f`

### Validation

Tester reports all 4 E2E tests pass in Round 9 of `talk/talk.md`. Deploy, login, and undeploy all work correctly.

---

## Acceptance Criteria

- [x] `service-argocd.sh` has correct `SCRIPT_REMOVE_PLAYBOOK` and `SCRIPT_DOCS` ✓
- [x] ArgoCD deploys successfully with `./uis deploy argocd` ✓
- [x] ArgoCD removes cleanly with `./uis undeploy argocd` ✓
- [x] E2E test playbook passes all 4 tests automatically during deploy ✓
- [x] Admin password works correctly (bcrypt hash via Python, passed to Helm) ✓
- [x] No conflicts between secrets framework and Helm (`argocd-secret` owned by Helm only) ✓
- [x] `python3-bcrypt` pinned in Dockerfile for reliable bcrypt hashing ✓
- [x] Unused numbered secrets template files (01-13) removed ✓
- [x] Secrets documentation (`how-secrets-works.md`) updated with ArgoCD flow ✓
- [x] STATUS-service-migration.md reflects ArgoCD as fully migrated ✓

---

## Out of Scope

- **`dev-argocd` command in devcontainer-toolbox** — documented in [INVESTIGATE-argocd-migration.md](./INVESTIGATE-argocd-migration.md) issue 6, separate repo
- **Secret artifacts in topsecret/** — partially addressed (numbered files removed), remaining cleanup deferred to PLAN-004
- **Old boot scripts in not-in-use/** — part of previous deployment system, no action needed

---

## Files Modified

| File | Change |
|------|--------|
| `provision-host/uis/services/management/service-argocd.sh` | Set `SCRIPT_REMOVE_PLAYBOOK`, fix `SCRIPT_DOCS` |
| `ansible/playbooks/220-setup-argocd.yml` | Reworked password handling (tasks 7-10: fail-fast assertions, Python bcrypt, temp values file), added E2E test invocation (tasks 19-20) |
| `manifests/220-argocd-config.yaml` | Changed `createSecret: false` to `createSecret: true` so Helm creates and owns `argocd-secret` |
| `provision-host/uis/templates/secrets-templates/00-master-secrets.yml.template` | Removed `argocd-secret` definition — Helm owns it, not the secrets framework |
| `topsecret/secrets-templates/00-master-secrets.yml.template` | Same `argocd-secret` removal as above (legacy copy) |
| `Dockerfile.uis-provision-host` | Added `python3-bcrypt` to apt package list |
| `provision-host/uis/templates/how-secrets-works.md` | Updated ArgoCD bcrypt flow documentation |
| `website/docs/ai-developer/plans/backlog/STATUS-service-migration.md` | Updated ArgoCD status to fully migrated |

## Files Created

| File | Purpose |
|------|---------|
| `ansible/playbooks/220-test-argocd.yml` | E2E test playbook — API health, login, Traefik routing, credential rejection |

## Files Deleted

| File | Reason |
|------|--------|
| `topsecret/secrets-templates/01-core-secrets.yml.template` | Unused dead code — `generate_kubernetes_secrets()` only reads `00-master-secrets.yml.template` |
| `topsecret/secrets-templates/02-database-secrets.yml.template` | Same |
| `topsecret/secrets-templates/04-search-secrets.yml.template` | Same |
| `topsecret/secrets-templates/05-apim-secrets.yml.template` | Same |
| `topsecret/secrets-templates/06-management-secrets.yml.template` | Same |
| `topsecret/secrets-templates/07-ai-secrets.yml.template` | Same |
| `topsecret/secrets-templates/08-development-secrets.yml.template` | Same — also contained hardcoded `argocd-secret` that conflicted with Helm |
| `topsecret/secrets-templates/09-network-secrets.yml.template` | Same |
| `topsecret/secrets-templates/10-datascience-secrets.yml.template` | Same |
| `topsecret/secrets-templates/11-monitoring-secrets.yml.template` | Same |
| `topsecret/secrets-templates/12-auth-secrets.yml.template` | Same |
| `topsecret/secrets-templates/13-github-secrets.yml.template` | Same |
