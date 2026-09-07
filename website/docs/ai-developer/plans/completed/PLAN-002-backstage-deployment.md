# PLAN-002: Deploy Backstage (RHDH) as a UIS Service

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed

**Goal**: Deploy Red Hat Developer Hub (RHDH) in UIS following the adding-a-service guide, with the generated catalog loaded, the Kubernetes plugin showing live service status, and the Grafana plugin linking services to their dashboards

**Completed**: 2026-03-12
**Last Updated**: 2026-03-12

**Investigation**: [INVESTIGATE-backstage.md](./INVESTIGATE-backstage.md)

**Prerequisites**: PLAN-001-backstage-metadata-and-generator must be complete (catalog YAML must exist in `generated/backstage/catalog/`)

**Priority**: Medium — requires a running cluster

---

## Overview

Deploy Backstage using the RHDH community image (`quay.io/rhdh-community/rhdh:1.9`) with the RHDH Helm chart. This follows the [Adding a Service](../../../contributors/guides/adding-a-service.md) guide completely.

Backstage will be deployed **without authentication** in this plan. Authentik OIDC integration is handled in PLAN-003.

### Reference services

- **OpenMetadata** (`340-*`) — closest match (Helm + PostgreSQL + utility DB playbook + verify tests)
- **OpenWebUI** (`200-*`) — reference for Helm values and secrets pattern

---

## Phase 1: Service Definition and Configuration Files

Create all static files needed before deployment.

### Tasks

- [x] 1.1 Create service definition `provision-host/uis/services/management/service-backstage.sh`
- [x] 1.2 Create Helm values `manifests/650-backstage-config.yaml` — RHDH chart uses `upstream.backstage` and `global.dynamic` keys
- [x] 1.3 Create IngressRoute `manifests/651-backstage-ingressroute.yaml` — route `backstage.localhost` to port 7007
- [x] 1.4 Create RBAC `manifests/652-backstage-rbac.yaml` — ServiceAccount + ClusterRoleBinding for K8s plugin
- [x] 1.5 Catalog mounted via ConfigMap from generated files (created dynamically in setup playbook, not as static manifest)
- [x] 1.6 Add Backstage secrets to `provision-host/uis/templates/secrets-templates/00-common-values.env.template`
- [x] 1.7 Add Backstage namespace block to `provision-host/uis/templates/secrets-templates/00-master-secrets.yml.template`

### Implementation Details

**1.2 Helm values** — key configuration:
- Pin image to `quay.io/rhdh-community/rhdh:1.9`
- Database: `postgresql.default.svc.cluster.local:5432/backstage` (credentials via `secretKeyRef`)
- Catalog: file-based, mounted from ConfigMap
- K8s plugin: enabled, uses ServiceAccount token
- Auth: disabled (guest access, no OIDC — that's PLAN-003)
- Health check: `/healthcheck` on port 7007
- Grafana plugin: enabled via `dynamic-plugins.yaml`, configured to connect to `grafana.default.svc.cluster.local:3000`
- **Resource tuning** — override RHDH defaults to laptop-friendly values:
  ```yaml
  upstream:
    backstage:
      resources:
        requests:
          cpu: 250m
          memory: 256Mi
        limits:
          cpu: 1000m
          memory: 1Gi
  ```
  RHDH defaults are 1Gi request / 2.5Gi limit — too heavy for a laptop. See investigation "Resource Usage and Image Strategy" section. If this proves insufficient, increase. If Backstage is still too heavy overall, switch to a custom minimal image (only changes the image reference).

**1.3 IngressRoute** — standard UIS pattern:
- `HostRegexp('backstage\..+')` routing to port 7007
- Namespace: `backstage`
- Label: `protection: public`

**1.6 Secrets** — add to the OPTIONAL section:
```bash
# ================================================================
# 🔧 OPTIONAL - BACKSTAGE
# ================================================================
BACKSTAGE_DB_PASSWORD=${DEFAULT_DATABASE_PASSWORD}
BACKSTAGE_SESSION_SECRET=generate-a-session-secret-here
# OIDC secrets are in PLAN-003 (Authentik integration)
```

### Validation

User reviews created files for correctness.

---

## Phase 2: Ansible Playbooks

Create setup, remove, and verify playbooks.

### Tasks

- [x] 2.1 Database setup inline in setup playbook (separate utility not needed — uses u02-verify-postgres.yml for validation)
- [x] 2.2 Create setup playbook `ansible/playbooks/650-setup-backstage.yml`
- [x] 2.3 Create remove playbook `ansible/playbooks/650-remove-backstage.yml`
- [x] 2.4 Create verify playbook `ansible/playbooks/650-test-backstage.yml`
- [x] 2.5 Add `rhdh-chart` Helm repo to `ansible/playbooks/05-install-helm-repos.yml`
- [x] 2.6 Register `backstage` in `VERIFY_SERVICES` in `provision-host/uis/lib/integration-testing.sh`
- [x] 2.7 Add `backstage` verify command to `provision-host/uis/manage/uis-cli.sh`

### Implementation Details

**2.1 Database playbook** — creates `backstage` database in shared PostgreSQL:
- Get PostgreSQL pod, retrieve password from secrets
- Create database `backstage`, user `backstage`
- Same pattern as `u09-authentik-create-postgres.yml`

**2.2 Setup playbook** — follows the OpenMetadata pattern:
1. Create namespace `backstage`
2. Verify PostgreSQL is running, check secrets exist
3. Call `u10-backstage-create-postgres.yml` to create database
4. Apply RBAC (`652-backstage-rbac.yaml`)
5. Apply catalog ConfigMap (`653-backstage-catalog.yaml`)
6. Helm install: `helm upgrade --install backstage rhdh-chart/backstage --version <pinned> -f 650-backstage-config.yaml -n backstage --wait`
7. Apply IngressRoute (`651-backstage-ingressroute.yaml`)
8. Health check: wait for pod ready, check `/healthcheck` responds

**2.3 Remove playbook:**
1. Delete IngressRoute
2. `helm uninstall backstage -n backstage`
3. Wait for pods to terminate
4. Delete PVCs
5. Delete namespace
6. Note: PostgreSQL database `backstage` is NOT deleted

**2.4 Verify playbook** — follows the OpenMetadata test pattern:

| Test | What | How |
|------|------|-----|
| **A. Health check** | Server responds | `GET /healthcheck` → HTTP 200 |
| **B. Catalog loaded** | Entities are present | `GET /api/catalog/entities` → returns entities |
| **C. K8s plugin responds** | Kubernetes integration works | Check that K8s plugin can list pods |
| **D. UI via Traefik** | IngressRoute works | `curl -H "Host: backstage.localhost" http://<traefik-clusterip>` → HTTP 200 |
| **E. Grafana plugin** | Grafana integration works | Check that Grafana dashboards are linked for annotated services (if Grafana is deployed) |

### Validation

User reviews playbook structure.

---

## Phase 3: Registration, Documentation, and Testing

Register the service, create docs, build, and test.

### Tasks

- [x] 3.1 Add `backstage` to `.uis.extend/enabled-services.conf`
- [x] 3.2 Add `packages/management/backstage` to `website/sidebars.ts`
- [x] 3.3 Create documentation page `website/docs/services/management/backstage.md`
- [x] 3.4 Run `./uis build` to build new provision host container
- [x] 3.5 Write test instructions to `talk/talk.md` for the tester
- [x] 3.6 Wait for tester results and fix issues (19 tester messages, 16 contributor responses)

### Implementation Details

**3.3 Documentation** — follow the OpenMetadata docs page pattern:
- Service info table (category, deploy/undeploy commands, dependencies, RHDH Helm chart with pinned version, namespace)
- What It Does section
- Deploy / Verify / Undeploy sections
- Configuration section (Helm values, catalog ConfigMap, K8s RBAC)
- Troubleshooting section

**3.5 Test instructions:**
1. Restart with new container: `UIS_IMAGE=uis-provision-host:local ./uis restart`
2. Generate and apply secrets: `./uis secrets generate && ./uis secrets apply`
3. Deploy PostgreSQL if not running: `./uis deploy postgresql`
4. Generate catalog: `./uis docs generate-backstage-catalog`
5. Deploy Backstage: `./uis deploy backstage`
6. Run verification: `./uis verify backstage`
7. Open `http://backstage.localhost` and browse the catalog
8. Undeploy: `./uis undeploy backstage`
9. Confirm cleanup: `kubectl get all -n backstage`

### Validation

All verify tests pass. Deploy and undeploy both succeed. Catalog shows all UIS services with correct relationships.

---

## Phase 4: Cleanup and Status Updates

### Tasks

- [x] 4.1 Update `INVESTIGATE-backstage.md` — note PLAN-002 is complete
- [x] 4.2 Move this plan to `completed/`

### Validation

User confirms status updates are correct.

---

## Acceptance Criteria

- [x] Backstage (RHDH 1.9) pod is running in the `backstage` namespace
- [x] `./uis deploy backstage` works end-to-end
- [x] `./uis undeploy backstage` cleans up all resources
- [x] `./uis verify backstage` passes all tests (A-E)
- [x] Catalog shows 25 UIS components with correct systems and owners
- [x] K8s plugin responds (verify test C passes)
- [ ] Grafana plugin — deferred (not bundled in RHDH 1.9, `plugins: []` for now)
- [x] UI accessible at `http://backstage.localhost`
- [x] Service appears in `./uis list`
- [x] Documentation page exists at the correct sidebar location
- [x] Tester has verified the deployment (19 messages over 16 fix rounds)

---

## Files to Create

| File | Type |
|------|------|
| `provision-host/uis/services/management/service-backstage.sh` | Service definition |
| `manifests/650-backstage-config.yaml` | Helm values |
| `manifests/651-backstage-ingressroute.yaml` | IngressRoute |
| `manifests/652-backstage-rbac.yaml` | RBAC for K8s plugin |
| `manifests/653-backstage-catalog.yaml` | Catalog ConfigMap |
| `ansible/playbooks/utility/u10-backstage-create-postgres.yml` | DB setup |
| `ansible/playbooks/650-setup-backstage.yml` | Setup playbook |
| `ansible/playbooks/650-remove-backstage.yml` | Remove playbook |
| `ansible/playbooks/650-test-backstage.yml` | Verify playbook |
| `website/docs/services/management/backstage.md` | Documentation |

## Files to Modify

| File | Change |
|------|--------|
| `provision-host/uis/templates/secrets-templates/00-common-values.env.template` | Add Backstage section |
| `provision-host/uis/templates/secrets-templates/00-master-secrets.yml.template` | Add backstage namespace block |
| `ansible/playbooks/05-install-helm-repos.yml` | Add `rhdh-chart` repo |
| `provision-host/uis/lib/integration-testing.sh` | Add `backstage` to `VERIFY_SERVICES` |
| `provision-host/uis/manage/uis-cli.sh` | Add `backstage` to `cmd_verify()` |
| `.uis.extend/enabled-services.conf` | Add `backstage` |
| `website/sidebars.ts` | Add to Management items |
