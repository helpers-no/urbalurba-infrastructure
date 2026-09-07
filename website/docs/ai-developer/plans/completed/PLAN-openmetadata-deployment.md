# Deploy OpenMetadata

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed

**Goal**: Deploy OpenMetadata 1.12.1 as a UIS platform service using the official Helm chart, reusing existing PostgreSQL and Elasticsearch

**Last Updated**: 2026-03-10

**Investigation**: [INVESTIGATE-openmetadata-deployment.md](INVESTIGATE-openmetadata-deployment.md)

---

## Overview

OpenMetadata is a data governance and metadata platform. It will be deployed as manifest 340 in the ANALYTICS category, reusing existing UIS PostgreSQL (manifest 042) and Elasticsearch 9.3.0 (manifest 060). The Kubernetes native orchestrator replaces Airflow for ingestion pipelines.

Key decisions from investigation:
- **Version**: OpenMetadata 1.12.1 (Helm chart 1.12.1, pinned)
- **Database**: PostgreSQL (existing UIS instance, new `openmetadata_db` database)
- **Search**: Elasticsearch 9.3.0 (existing UIS instance)
- **Ingestion**: K8s Jobs executor (no Airflow)
- **Deployment**: Official `openmetadata` Helm chart via Ansible playbook

---

## Phase 1: Service Definition and Configuration Files — ✅ DONE

Create all the static files needed before deployment.

### Tasks

- [x] 1.1 Create service definition script `provision-host/uis/services/analytics/service-openmetadata.sh` ✓
- [x] 1.2 Create Helm values file `manifests/340-openmetadata-config.yaml` ✓
- [x] 1.3 Create IngressRoute `manifests/341-openmetadata-ingressroute.yaml` ✓
- [x] 1.4 Add OpenMetadata secrets to `provision-host/uis/templates/secrets-templates/00-common-values.env.template` ✓
- [x] 1.5 Add OpenMetadata namespace block to `provision-host/uis/templates/secrets-templates/00-master-secrets.yml.template` ✓

### Implementation Details

**1.1 Service definition** — follow the Unity Catalog pattern (`service-unity-catalog.sh`):
```bash
SCRIPT_ID="openmetadata"
SCRIPT_NAME="OpenMetadata"
SCRIPT_DESCRIPTION="Open-source data governance and metadata platform"
SCRIPT_CATEGORY="ANALYTICS"
SCRIPT_PLAYBOOK="340-setup-openmetadata.yml"
SCRIPT_REMOVE_PLAYBOOK="340-remove-openmetadata.yml"
SCRIPT_CHECK_COMMAND="kubectl get pods -n openmetadata -l app.kubernetes.io/name=openmetadata --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REQUIRES="postgresql elasticsearch"
SCRIPT_PRIORITY="93"
SCRIPT_HELM_CHART="open-metadata/openmetadata"
SCRIPT_NAMESPACE="openmetadata"
# Website metadata fields (SCRIPT_ABSTRACT, SCRIPT_LOGO, SCRIPT_WEBSITE, SCRIPT_TAGS, SCRIPT_SUMMARY, SCRIPT_DOCS)
```

**1.2 Helm values** — key configuration in `340-openmetadata-config.yaml`:
- Pin image to `docker.getcollate.io/openmetadata/server:1.12.1` (explicit registry + tag)
- Point database to `postgresql.default.svc.cluster.local:5432/openmetadata_db`
- Point search to `elasticsearch-master.default.svc.cluster.local:9200` (HTTP, scheme `http`, no auth — must explicitly disable ES auth since some charts default to expecting it)
- Set `pipelineServiceClientConfig.type: "k8s"` for K8s orchestrator
- Set dev-appropriate resource limits (CPU 500m, memory 1.5Gi)
- Database credentials via `secretKeyRef` from `urbalurba-secrets`
- **Admin credentials**: OpenMetadata bootstraps with `admin@open-metadata.org` / `admin` — the Helm chart has no mechanism to override this. The setup playbook changes the password post-deploy via `PUT /api/v1/users/changePassword` API. The admin email cannot be changed (it's `admin@open-metadata.org`), only the password is changed to `OPENMETADATA_ADMIN_PASSWORD` from `urbalurba-secrets`.

**1.3 IngressRoute** — follow the standard UIS pattern:
- `HostRegexp('openmetadata\..+')` routing to port 8585
- Namespace: `openmetadata`
- Label: `protection: public`

**1.4 Secrets template** — add to the OPTIONAL section in `00-common-values.env.template`:
```bash
# ================================================================
# 🔧 OPTIONAL - OPENMETADATA
# ================================================================
# OpenMetadata bootstraps with admin@open-metadata.org — this cannot be changed via Helm
OPENMETADATA_ADMIN_EMAIL=admin@open-metadata.org
OPENMETADATA_ADMIN_PASSWORD=${DEFAULT_ADMIN_PASSWORD}
OPENMETADATA_DB_PASSWORD=${DEFAULT_DATABASE_PASSWORD}
```

OpenMetadata's default admin is `admin@open-metadata.org` / `admin`. The email is fixed (cannot be changed). The password is changed post-deploy by the setup playbook via the OpenMetadata API.

**1.5 Master secrets** — add namespace block after unity-catalog block in `00-master-secrets.yml.template`:
- Namespace: `openmetadata`
- Secret keys: `OPENMETADATA_DATABASE_PASSWORD`, `OPENMETADATA_DATABASE_USER`, `OPENMETADATA_ADMIN_EMAIL`, `OPENMETADATA_ADMIN_PASSWORD`
- All derived from standard UIS variables (`PGPASSWORD`, `DEFAULT_ADMIN_EMAIL`, `DEFAULT_ADMIN_PASSWORD`)

### Validation

User reviews the created files for correctness.

---

## Phase 2: Ansible Playbooks — ✅ DONE

Create the setup, remove, and verify playbooks.

### Tasks

- [x] 2.1 Create setup playbook `ansible/playbooks/340-setup-openmetadata.yml` ✓
- [x] 2.2 Create remove playbook `ansible/playbooks/340-remove-openmetadata.yml` ✓
- [x] 2.3 Create verify playbook `ansible/playbooks/340-test-openmetadata.yml` ✓
- [x] 2.4 Register `openmetadata` in `VERIFY_SERVICES` in `provision-host/uis/lib/integration-testing.sh` ✓
- [x] 2.5 Add `openmetadata` verify command to `provision-host/uis/manage/uis-cli.sh` ✓

### Implementation Details

**2.1 Setup playbook** — combines Unity Catalog pattern (database creation) with Elasticsearch pattern (Helm deployment):

1. **Prerequisites**: Create namespace, verify PostgreSQL and Elasticsearch are running, check secrets exist
2. **Database**: Get PostgreSQL pod, retrieve password from secrets, create `openmetadata_db` database
3. **Helm**: Add `open-metadata` Helm repo, `helm upgrade --install openmetadata open-metadata/openmetadata --version 1.12.1 -f 340-openmetadata-config.yaml -n openmetadata --wait`
4. **RBAC**: Verify the Helm chart creates the required ServiceAccount, Role, and RoleBinding for the K8s Jobs executor. If not (check `kubectl get clusterrole,clusterrolebinding -l app.kubernetes.io/name=openmetadata`), create them manually — OpenMetadata needs permissions to create/read/delete Jobs, CronJobs, Pods, and Pod logs.
5. **Admin credentials**: If the Helm chart doesn't support setting admin credentials natively, call the OpenMetadata API post-deploy to update the admin user's email and password from `urbalurba-secrets`.
6. **Ingress**: Apply `341-openmetadata-ingressroute.yaml`
7. **Health check**: Wait for pod ready, check API responds at `/api/v1/system/health`
8. **Status**: Display final deployment status

**2.2 Remove playbook** — follow Unity Catalog remove pattern:
1. Delete IngressRoute
2. `helm uninstall openmetadata -n openmetadata`
3. Wait for pods to terminate
4. Delete PVCs in the openmetadata namespace (`kubectl delete pvc -n openmetadata --all --ignore-not-found`) — follows the ES remove pattern
5. Delete namespace
6. Note: PostgreSQL database `openmetadata_db` is NOT deleted (manual cleanup if needed)

**2.3 Verify playbook** (`340-test-openmetadata.yml`) — follows the ArgoCD (`220-test-argocd.yml`) and Authentik (`070-test-authentik-auth.yml`) patterns:
- Uses `kubectl run curlimages/curl` for all tests (from inside the cluster)
- Uses `ansible.builtin.assert` with `fail_msg` containing troubleshooting commands
- Reads credentials from `urbalurba-secrets` (never hardcoded)
- Includes negative test (wrong credentials)
- Summary section at the end listing all results

6 tests (all CRITICAL):

| Test | What | How |
|---|---|---|
| **A. API health** | Server process responds | `GET /api/v1/system/health` → returns `OK` (HTTP 200). No auth needed. |
| **B. Version** | Correct version deployed | `GET /api/v1/system/version` → JSON contains `"version": "1.12.1"`. No auth needed. |
| **C. Admin login** | Credentials from secrets work | Login with `OPENMETADATA_ADMIN_EMAIL` / `OPENMETADATA_ADMIN_PASSWORD` from `urbalurba-secrets`. Must return a JWT token. The exact login API endpoint must be verified during implementation (likely `POST /api/v1/users/login` or `POST /api/v1/users/loginWithPwd`). Confirms both authentication AND database connectivity (user records are in PostgreSQL). |
| **D. Database & Search connected** | PostgreSQL and Elasticsearch validated | `GET /api/v1/system/status` with JWT token from test C. Checks `database.passed: true` and `searchInstance.passed: true`. This is the comprehensive deployment validation endpoint. |
| **E. UI via Traefik** | IngressRoute works | `curl -H "Host: openmetadata.localhost" http://<traefik-clusterip>` → HTTP 200. Same pattern as ArgoCD test C. |
| **F. Wrong credentials rejected** | Bad password denied | Login with wrong password must NOT return a JWT token. Same pattern as ArgoCD test D and Authentik test E. |

**Key details**:
- Tests C, D, and F read the admin credentials from `urbalurba-secrets` in the `openmetadata` namespace (same as ArgoCD reads `ARGOCD_ADMIN_PASSWORD` and Authentik uses blueprint users). The credentials come from `DEFAULT_ADMIN_EMAIL` / `DEFAULT_ADMIN_PASSWORD` via the secrets pipeline — never hardcoded.
- Test D validates both PostgreSQL AND Elasticsearch connectivity in a single call — the `/api/v1/system/status` endpoint checks all backend connections and returns per-component pass/fail.
- Each test uses `ansible.builtin.assert` with detailed `fail_msg` including kubectl troubleshooting commands (pod logs, secret values, service status).

**2.4 Integration test registration** — add to `VERIFY_SERVICES` in `integration-testing.sh`:
```bash
VERIFY_SERVICES="
argocd:argocd verify
openmetadata:openmetadata verify
"
```

**2.5 CLI verify command** — add `openmetadata` to the `cmd_verify()` case statement in `uis-cli.sh`, calling `ansible-playbook 340-test-openmetadata.yml`. This enables `./uis verify openmetadata`.

### Validation

User reviews the playbook structure.

---

## Phase 3: Registration and Documentation — ✅ DONE

Register the service and create documentation.

### Tasks

- [x] 3.1 Add `openmetadata` to `.uis.extend/enabled-services.conf` ✓
- [x] 3.2 Add `packages/analytics/openmetadata` to `website/sidebars.ts` ✓
- [x] 3.3 Create documentation page `website/docs/services/analytics/openmetadata.md` ✓

### Implementation Details

**3.1 enabled-services.conf** — add `openmetadata` line (commented out by default, under a `# === Analytics ===` section)

**3.2 sidebars.ts** — add after `unitycatalog` in the Analytics items array:
```typescript
'packages/analytics/openmetadata',
```

**3.3 Documentation** — follow the Elasticsearch docs page pattern (`website/docs/services/databases/elasticsearch.md`):
- Service info table (category, deploy/undeploy commands, dependencies, Helm chart with pinned version, namespace)
- What It Does section
- Deploy / Verify / Undeploy sections
- Configuration section (Helm values, secrets, key files)
- Troubleshooting section

### Validation

User reviews documentation and sidebar entry.

---

## Phase 4: Build, Deploy, and Test — ✅ DONE

Build the provision host container, deploy, and verify with the tester.

### Tasks

- [x] 4.1 Run `./uis build` to build new provision host container with the service definition ✓
- [x] 4.2 Write test instructions to `talk/talk.md` for the tester ✓
- [x] 4.3 Wait for tester results ✓
- [x] 4.4 Fix any issues found during testing (5 rounds — base64 login, requestType, password complexity, default-secrets.env) ✓

### Implementation Details

**4.1** The tester needs the updated container to have the service definition available.

**4.2 Test instructions** for the tester:
1. Restart with new container: `UIS_IMAGE=uis-provision-host:local ./uis restart`
2. Generate and apply secrets: `./uis secrets generate && ./uis secrets apply`
3. Deploy dependencies if not running: `./uis deploy postgresql && ./uis deploy elasticsearch`
4. Deploy OpenMetadata: `./uis deploy openmetadata`
5. Run verification: `./uis verify openmetadata` (runs all 6 E2E tests)
6. Undeploy: `./uis undeploy openmetadata`
7. Confirm cleanup: `kubectl get all -n openmetadata` (should show nothing)

### Validation

All 6 verify tests pass (API health, version, admin login, database+search connected, UI via Traefik, wrong credentials rejected). Deploy and undeploy both succeed.

---

## Phase 5: Cleanup and Status Updates — ✅ DONE

Update investigation, roadmap, and complete the plan.

### Tasks

- [x] 5.1 Update `INVESTIGATE-openmetadata-deployment.md` — mark remaining next steps as done ✓
- [x] 5.2 Update `STATUS-platform-roadmap.md` — mark #6 as Complete, add to Completed Investigations table ✓
- [x] 5.3 Move plan and investigation to `completed/` ✓

### Validation

User confirms all status updates are correct.

---

## Acceptance Criteria

- [x] OpenMetadata 1.12.1 pod is running in the `openmetadata` namespace
- [x] Admin credentials use `DEFAULT_ADMIN_PASSWORD` from secrets (password changed post-deploy via API; email is fixed at `admin@open-metadata.org`)
- [x] `./uis verify openmetadata` passes all 6 tests:
  - [x] A. API health check (GET /api/v1/system/health → OK)
  - [x] B. Version check (GET /api/v1/system/version → 1.12.1)
  - [x] C. Admin login with credentials from secrets (returns JWT token)
  - [x] D. Database and search connected (GET /api/v1/system/status → both passed)
  - [x] E. UI accessible via Traefik (openmetadata.localhost → HTTP 200)
  - [x] F. Wrong credentials rejected (bad password does NOT return token)
- [x] `./uis deploy openmetadata` works end-to-end
- [x] `./uis undeploy openmetadata` cleans up all resources
- [x] Service appears in `./uis list`
- [x] `./uis test-all --dry-run` includes openmetadata with verify step
- [x] Documentation page exists at the correct sidebar location
- [x] Tester has verified the deployment (Round 5 — all 8 steps PASS)

---

## Files to Create

| File | Type |
|------|------|
| `provision-host/uis/services/analytics/service-openmetadata.sh` | New |
| `manifests/340-openmetadata-config.yaml` | New |
| `manifests/341-openmetadata-ingressroute.yaml` | New |
| `ansible/playbooks/340-setup-openmetadata.yml` | New |
| `ansible/playbooks/340-remove-openmetadata.yml` | New |
| `ansible/playbooks/340-test-openmetadata.yml` | New |
| `website/docs/services/analytics/openmetadata.md` | New |

## Files to Modify

| File | Change |
|------|--------|
| `provision-host/uis/templates/secrets-templates/00-common-values.env.template` | Add OpenMetadata section (admin + DB credentials) |
| `provision-host/uis/templates/secrets-templates/00-master-secrets.yml.template` | Add openmetadata namespace block |
| `provision-host/uis/lib/integration-testing.sh` | Add `openmetadata` to `VERIFY_SERVICES` |
| `provision-host/uis/manage/uis-cli.sh` | Add `openmetadata` to `cmd_verify()` |
| `.uis.extend/enabled-services.conf` | Add `openmetadata` |
| `website/sidebars.ts` | Add to Analytics items |
| `website/docs/ai-developer/plans/backlog/INVESTIGATE-openmetadata-deployment.md` | Mark next steps done |
| `website/docs/ai-developer/plans/backlog/STATUS-platform-roadmap.md` | Update #6 status |
