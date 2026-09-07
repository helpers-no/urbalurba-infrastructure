# PLAN-008: Service Migration Status & Remaining Work

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed

**Goal**: Track migration status of all 26 UIS services and complete remaining work for services that are not fully migrated.

**Last Updated**: 2026-02-27 (password architecture fixed: orphaned defaults connected, email validation added)

**Priority**: Medium — core services work, remaining items are edge cases

**Blocks**: [PLAN-004-secrets-cleanup](../completed/PLAN-004-secrets-cleanup.md) — old path references in playbooks must be fixed before backwards compatibility code can be removed

---

## Service Migration Status

All 26 services have service scripts (`provision-host/uis/services/*/service-*.sh`) and deploy playbooks. The table below tracks full migration status including remove playbooks, verified deployment, and legacy path dependencies.

### Legend

- **Service script**: `provision-host/uis/services/<category>/service-<id>.sh` — metadata for `./uis list`, `./uis deploy`, etc.
- **Deploy playbook**: Ansible playbook for `./uis deploy <service>`
- **Remove playbook**: Ansible playbook for `./uis undeploy <service>`
- **Verified**: Service has been deployed and tested in the new UIS system
- **Old paths**: ⚠️ = playbook still references `topsecret/`, `secrets/`, or `cloud-init/`

### Core (000-029)

| Service | Service Script | Deploy | Remove | Verified | Notes |
|---------|:---:|:---:|:---:|:---:|-------|
| **whoami** | ✅ | ✅ `025-setup-whoami-testpod.yml` | ✅ via `-e operation=delete` | ✅ | Same playbook handles both deploy and remove via operation parameter |
| **nginx** | ✅ | ✅ `020-setup-nginx.yml` | ✅ `020-remove-nginx.yml` | ✅ | Verified in talk9.md |

### Monitoring (030-039)

| Service | Service Script | Deploy | Remove | Verified | Notes |
|---------|:---:|:---:|:---:|:---:|-------|
| **prometheus** | ✅ | ✅ `030-setup-prometheus.yml` | ✅ `030-remove-prometheus.yml` | ✅ | Verified in talk9.md |
| **tempo** | ✅ | ✅ `031-setup-tempo.yml` | ✅ `031-remove-tempo.yml` | ✅ | Verified in talk9.md |
| **loki** | ✅ | ✅ `032-setup-loki.yml` | ✅ `032-remove-loki.yml` | ✅ | Verified in talk9.md |
| **otel-collector** | ✅ | ✅ `033-setup-otel-collector.yml` | ✅ `033-remove-otel-collector.yml` | ✅ | Verified in talk9.md |
| **grafana** | ✅ | ✅ `034-setup-grafana.yml` | ✅ `034-remove-grafana.yml` | ✅ | Verified in talk9.md |

### Databases (040-059)

| Service | Service Script | Deploy | Remove | Verified | Notes |
|---------|:---:|:---:|:---:|:---:|-------|
| **postgresql** | ✅ | ✅ `040-database-postgresql.yml` | ✅ `040-remove-database-postgresql.yml` | ✅ | Required by authentik |
| **mysql** | ✅ | ✅ `040-database-mysql.yml` | ✅ `040-remove-database-mysql.yml` | ✅ | Verified in talk9.md |
| **mongodb** | ✅ | ✅ `040-setup-mongodb.yml` | ✅ `040-remove-database-mongodb.yml` | ✅ | Verified in talk9.md |
| **qdrant** | ✅ | ✅ `044-setup-qdrant.yml` | ✅ `044-remove-qdrant.yml` | ✅ | Verified in talk9.md |
| **redis** | ✅ | ✅ `050-setup-redis.yml` | ✅ `050-remove-redis.yml` | ✅ | Required by authentik |

### Search (060-069)

| Service | Service Script | Deploy | Remove | Verified | Notes |
|---------|:---:|:---:|:---:|:---:|-------|
| **elasticsearch** | ✅ | ✅ `060-setup-elasticsearch.yml` | ✅ `060-remove-elasticsearch.yml` | ✅ | Verified in talk9.md |

### Authentication (070-079)

| Service | Service Script | Deploy | Remove | Verified | Notes |
|---------|:---:|:---:|:---:|:---:|-------|
| **authentik** | ✅ | ✅ `070-setup-authentik.yml` | ✅ `070-remove-authentik.yml` | ✅ | Fully tested with 5 E2E auth tests (PLAN-007) |

### Queues (080-089)

| Service | Service Script | Deploy | Remove | Verified | Notes |
|---------|:---:|:---:|:---:|:---:|-------|
| **rabbitmq** | ✅ | ✅ `080-setup-rabbitmq.yml` | ✅ `080-remove-rabbitmq.yml` | ✅ | Verified in talk9.md |

### Management (090, 220+)

| Service | Service Script | Deploy | Remove | Verified | Notes |
|---------|:---:|:---:|:---:|:---:|-------|
| **gravitee** | ✅ | ✅ `090-setup-gravitee.yml` | ❌ Missing | ❌ | **Was not working before migration.** Needs new setup — deploy playbook may need rewrite |
| **argocd** | ✅ | ✅ `220-setup-argocd.yml` | ✅ `220-remove-argocd.yml` | ✅ | Verified in talk9.md |
| **pgadmin** | ✅ | ✅ `641-adm-pgadmin.yml` | ✅ `641-remove-pgadmin.yml` | ✅ | Verified in talk10.md. Auto-login TODO (pgpass works but pgAdmin ignores it) |
| **redisinsight** | ✅ | ✅ `651-adm-redisinsight.yml` | ✅ `651-remove-redisinsight.yml` | ✅ | Verified in talk10.md |

### AI (200-219)

| Service | Service Script | Deploy | Remove | Verified | Notes |
|---------|:---:|:---:|:---:|:---:|-------|
| **openwebui** | ✅ | ✅ `200-setup-open-webui.yml` | ✅ `200-remove-open-webui.yml` | ✅ | Verified in talk9.md |
| **litellm** | ✅ | ✅ `210-setup-litellm.yml` | ✅ `210-remove-litellm.yml` | ✅ | Verified in talk9.md |

### Data Science (320-350)

| Service | Service Script | Deploy | Remove | Verified | Notes |
|---------|:---:|:---:|:---:|:---:|-------|
| **unity-catalog** | ✅ | ✅ `320-setup-unity-catalog.yml` | ✅ `320-remove-unity-catalog.yml` | ✅ | Verified in talk9.md. Fixed: wrong image, security context, API version, no curl |
| **spark** | ✅ | ✅ `330-setup-spark.yml` | ✅ `330-remove-spark.yml` | ✅ | Verified in talk9.md |
| **jupyterhub** | ✅ | ✅ `350-setup-jupyterhub.yml` | ✅ `350-remove-jupyterhub.yml` | ✅ | Verified in talk9.md |

### Network (800+)

| Service | Service Script | Deploy | Remove | Verified | Notes |
|---------|:---:|:---:|:---:|:---:|-------|
| **tailscale-tunnel** | ✅ | ✅ `802-deploy-network-tailscale-tunnel.yml` | ✅ `801-remove-network-tailscale-tunnel.yml` | ✅ | Fully verified in PLAN-009/010/011. CLI: `uis tailscale expose/unexpose/verify` |
| **cloudflare-tunnel** | ✅ | ✅ `820-deploy-network-cloudflare-tunnel.yml` | ✅ `821-remove-network-cloudflare-tunnel.yml` | ✅ | Fully verified: deploy, undeploy, E2E connectivity (PLAN-cloudflare-tunnel-undeploy) |

---

## Summary

| Category | Total | Verified | Issues |
|----------|:-----:|:--------:|--------|
| Core | 2 | 2 | None |
| Monitoring | 5 | 5 | None |
| Databases | 5 | 5 | None |
| Search | 1 | 1 | None |
| Authentication | 1 | 1 | None |
| Queues | 1 | 1 | None |
| Management | 4 | 3 | gravitee broken before migration |
| AI | 2 | 2 | None |
| Data Science | 3 | 3 | None |
| Network | 2 | 2 | None |
| **Total** | **26** | **25** | **1 not verified** (gravitee broken before migration) |

### Automated Integration Test (PLAN-013)

`./uis test-all` automates deploy/undeploy for all 23 testable services (47 operations). First run: **47/47 PASS** in 38m 40s. Also supports `--dry-run` and `--clean`.

### Playbooks with Old Path References (2026-02-18 scan)

Scanned all playbooks in `ansible/playbooks/` for references to `topsecret/`, `secrets/`, and `cloud-init/`:

| Playbook | Line | Reference | Impact | Fixed |
|----------|------|-----------|--------|:-----:|
| `01-configure_provision-host.yml` | 30 | `ansible/secrets/id_rsa_ansible.secret-key` | Hardcoded old SSH key path | ✅ PR #35 |
| `350-setup-jupyterhub.yml` | 65 | `topsecret/kubernetes/kubernetes-secrets.yml` | **Breaks if topsecret/ removed** | ✅ PR #35 |
| `802-deploy-network-tailscale-tunnel.yml` | 193-194 | `topsecret/kubernetes/kubernetes-secrets.yml` | Error message text only | ✅ PR #35 |

All old path references in playbooks are now fixed. Also fixed: `ansible/ansible.cfg` and `provision-host/provision-host-vm-create.sh` (PR #35).

### Topsecret Cleanup Beyond Playbooks (talk11)

In addition to the playbook fixes above (PR #35), a full topsecret cleanup was completed across the codebase:

| Category | Files Changed | What Changed |
|----------|:---:|--------|
| Legacy scripts | 7 | Removed `topsecret/` and `secrets/` fallback paths from networking scripts and provision-host container creation |
| Config files | 3 | `.github/workflows/build-uis-container.yml`, `.dockerignore`, `manifests/220-litellm-config.yaml` |
| Documentation | 17 | All docs updated from `topsecret/kubernetes/kubernetes-secrets.yml` to `.uis.secrets/generated/kubernetes/kubernetes-secrets.yml` |
| Deleted obsolete scripts | 2 | `install-rancher.sh` and `copy2provisionhost.sh` — fully replaced by `./uis` CLI |
| Docs updated for script removal | 15+ | All references to deleted scripts replaced with `./uis start`, `./uis provision`, `./uis shell` |

**Remaining topsecret references**: Only in 7 remote deployment target scripts (`provision-host/provision-host-vm-create.sh`, `hosts/azure-aks/` scripts). These are deferred until remote deployment targets are tested with real infrastructure.

### New Reference Documentation (talk11)

- Created `website/docs/reference/factory-reset.md` — user-facing runbook for factory reset, recovery, service deployment order, and verification checklist. Extracted from INVESTIGATE-rancher-reset findings.

### Completed Investigations Closed (talk11)

- `INVESTIGATE-rancher-reset-and-full-verification.md` → moved to `completed/`
- `INVESTIGATE-unity-catalog-crashloop.md` → moved to `completed/`

### Password Architecture Fix (PR #44)

Fixed `default-secrets.env` single-source-of-truth pattern — 8 of 11 DEFAULT_ variables were orphaned (never applied to templates). See [PLAN-fix-password-architecture](../completed/PLAN-fix-password-architecture.md).

| What | Change |
|------|--------|
| Removed redundant variables | 4 removed from `default-secrets.env` (`DEFAULT_DATABASE_ROOT_PASSWORD`, `DEFAULT_POSTGRES_PASSWORD`, `DEFAULT_MONGODB_ROOT_PASSWORD`, `DEFAULT_AUTHENTIK_BOOTSTRAP_EMAIL`) |
| Connected orphaned defaults | Extended sed replacements from 5→8 in `first-run.sh` |
| Removed hardcoded credentials | Replaced in `00-common-values.env.template` and `00-master-secrets.yml.template` |
| Email consolidation | Removed 2 orphaned email variables, kept single `DEFAULT_ADMIN_EMAIL` |
| Validation | Extended from 3→7 variables, added email format check, weak-password detection |
| Self-healing init | Fixed bug where fresh `.uis.secrets/` didn't get templates when `.uis.extend/` already existed |

Tested: postgresql, redis, pgadmin, authentik, openwebui — all deploy/undeploy clean with correct credentials.

---

## Phase 1: Quick Fixes (metadata)

### Tasks

- [x] 1.1 Fix ArgoCD: set `SCRIPT_REMOVE_PLAYBOOK="220-remove-argocd.yml"` in `service-argocd.sh` ✓ (PLAN-argocd-migration)

---

## Phase 2: Fix Old Path References in Playbooks

These must be fixed before PLAN-004-secrets-cleanup can remove backwards compatibility.

### Tasks

- [x] 2.1 Fix `350-setup-jupyterhub.yml` line 65: replace `topsecret/kubernetes/kubernetes-secrets.yml` with new `.uis.secrets/` path ✓ (PR #35)
- [x] 2.2 Fix `01-configure_provision-host.yml` line 30: replace `ansible/secrets/id_rsa_ansible.secret-key` with new path ✓ (PR #35)
- [x] 2.3 Fix `802-deploy-network-tailscale-tunnel.yml` lines 193-194: update error message text to reference `.uis.secrets/` ✓ (PR #35)
- [x] 2.4 Fix `ansible/ansible.cfg`: update `private_key_file` to new `.uis.secrets/` path ✓ (PR #35)
- [x] 2.5 Fix `provision-host/provision-host-vm-create.sh`: update SSH key copy destination, remove legacy fallback ✓ (PR #35)

---

## Phase 3: Missing Remove Playbooks

### Tasks

- [x] 3.1 Create `801-remove-network-tailscale-tunnel.yml` — tear down Tailscale tunnel deployment and namespace ✓ (PLAN-009)
- [x] 3.2 Create `821-remove-network-cloudflare-tunnel.yml` — tear down Cloudflare tunnel deployment ✓ (PLAN-cloudflare-tunnel-undeploy, PR #43)
- [x] 3.3 Update `service-tailscale-tunnel.sh` with `SCRIPT_REMOVE_PLAYBOOK` ✓ (PLAN-009)
- [x] 3.4 `service-cloudflare-tunnel.sh` already had `SCRIPT_REMOVE_PLAYBOOK` set ✓

---

## Phase 4: Gravitee (New Setup)

Gravitee was not working before the migration. This is effectively a fresh setup, not a migration.

### Tasks

- [ ] 4.1 Investigate current state of `090-setup-gravitee.yml` — does it work at all?
- [ ] 4.2 If broken, rewrite the deploy playbook or disable the service
- [ ] 4.3 Create `090-remove-gravitee.yml`
- [ ] 4.4 Test deploy and remove cycle

---

## Phase 5: Deployment Verification — COMPLETE

23/26 services verified. All deploy and undeploy cleanly.

**Automated testing (PLAN-013):** `./uis test-all` runs 47 operations (deploy + undeploy + verify) for all 23 services. First full automated run: 47/47 PASS in 38m 40s (2026-02-26).

Service dependency fixes during PLAN-013:
- `service-otel-collector.sh`: Added `SCRIPT_REQUIRES="prometheus loki tempo"` (E2E needs backends)
- `service-grafana.sh`: Added `SCRIPT_REQUIRES="prometheus loki tempo otel-collector"` (E2E sends data via OTEL)

### Tasks

- [x] 5.1 Verify monitoring stack: prometheus, grafana, loki, tempo, otel-collector ✓ (talk9.md)
- [x] 5.2 Verify databases: mysql, mongodb, qdrant ✓ (talk9.md)
- [x] 5.3 Verify AI stack: openwebui, litellm ✓ (talk9.md)
- [x] 5.4 Verify data science stack: jupyterhub, spark, unity-catalog ✓ (talk9.md)
- [x] 5.5 Verify other: nginx, elasticsearch, rabbitmq ✓ (talk9.md)
- [x] 5.6 Verify management: pgadmin, redisinsight ✓ (talk10.md)
- [x] 5.7 Verify tailscale-tunnel ✓ (PLAN-009/010/011 — 12+ rounds of testing)
- [x] 5.8 Verify cloudflare-tunnel ✓ (PLAN-cloudflare-tunnel-undeploy — deploy, undeploy, E2E connectivity all passed)

**Skipped**: gravitee (broken before migration).

---

## Files to Modify

| File | Change |
|------|--------|
| `provision-host/uis/services/management/service-argocd.sh` | ✅ Done — Add `SCRIPT_REMOVE_PLAYBOOK` |
| `provision-host/uis/services/network/service-tailscale-tunnel.sh` | ✅ Done — `SCRIPT_REMOVE_PLAYBOOK` added (PLAN-009) |
| `provision-host/uis/services/network/service-cloudflare-tunnel.sh` | ✅ Done — Already had `SCRIPT_REMOVE_PLAYBOOK` |
| `ansible/playbooks/350-setup-jupyterhub.yml` | ✅ Done — Replace hardcoded `topsecret/` path (PR #35) |
| `ansible/playbooks/01-configure_provision-host.yml` | ✅ Done — Replace hardcoded `secrets/` SSH key path (PR #35) |
| `ansible/playbooks/802-deploy-network-tailscale-tunnel.yml` | ✅ Done — Update error message text (PR #35) |

## Files to Create

| File | Purpose |
|------|---------|
| ~~`ansible/playbooks/801-remove-network-tailscale-tunnel.yml`~~ | ✅ Done (PLAN-009) |
| ~~`ansible/playbooks/821-remove-network-cloudflare-tunnel.yml`~~ | ✅ Done (PLAN-cloudflare-tunnel-undeploy, PR #43) |
| `ansible/playbooks/090-remove-gravitee.yml` | Gravitee removal (if service is fixed) |
