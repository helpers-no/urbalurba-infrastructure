# Deploy Enonic XP CMS

**Target file**: `website/docs/ai-developer/plans/backlog/PLAN-enonic-xp-deployment.md`

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed

**Goal**: Deploy Enonic XP 7.16.2 as a UIS platform service using direct Kubernetes manifests (StatefulSet pattern), with no external database dependencies

**Last Updated**: 2026-03-10

**Investigation**: [INVESTIGATE-enonic-xp-deployment.md](INVESTIGATE-enonic-xp-deployment.md)

---

## Overview

Enonic XP is a headless CMS used by Norwegian organizations (NAV, Gjensidige). It will be deployed as manifest 085 in the INTEGRATION category using direct YAML manifests (StatefulSet pattern like Unity Catalog — no Helm chart). Enonic has embedded Elasticsearch and NoSQL storage, so it has no external database dependencies.

Key decisions from investigation:
- **Version**: Enonic XP 7.16.2 (image `enonic/xp:7.16.2-ubuntu`, pinned)
- **Pattern**: StatefulSet + ConfigMap + PVC (direct manifests, no Helm)
- **Category**: INTEGRATION, manifest **085**
- **Namespace**: `enonic`
- **Admin**: User `su`, password set via `xp.suPassword` in `system.properties` (injected from `DEFAULT_ADMIN_PASSWORD` secret at container startup)
- **Ports**: 8080 (web/API), 4848 (management — internal only), 2609 (statistics/health — internal only)
- **Storage**: Single PVC for `$XP_HOME` (blobstore, index, config, deploy, snapshots)
- **No sidecar**: The app deployment pipeline (#5 on roadmap) is a separate follow-up

---

## Phase 1: Service Definition and Configuration Files — ✅ DONE

Create all static files needed before deployment.

### Tasks

- [x] 1.1 Create service definition `provision-host/uis/services/integration/service-enonic.sh` ✓
- [x] 1.2 Create ConfigMap `manifests/085-enonic-config.yaml` ✓
- [x] 1.3 Create StatefulSet + Service + PVC `manifests/085-enonic-statefulset.yaml` ✓
- [x] 1.4 Create IngressRoute `manifests/085-enonic-ingressroute.yaml` ✓
- [x] 1.5 Add Enonic secrets to `provision-host/uis/templates/secrets-templates/00-common-values.env.template` ✓
- [x] 1.6 Add Enonic namespace block to `provision-host/uis/templates/secrets-templates/00-master-secrets.yml.template` ✓

### Implementation Details

**1.1 Service definition** — follow the OpenMetadata pattern (`service-openmetadata.sh`):
```bash
SCRIPT_ID="enonic"
SCRIPT_NAME="Enonic XP"
SCRIPT_DESCRIPTION="Headless CMS platform for content management and delivery"
SCRIPT_CATEGORY="INTEGRATION"
SCRIPT_PLAYBOOK="085-setup-enonic.yml"
SCRIPT_REMOVE_PLAYBOOK="085-remove-enonic.yml"
SCRIPT_CHECK_COMMAND="kubectl get pods -n enonic -l app=enonic-xp --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REQUIRES=""  # No external dependencies
SCRIPT_PRIORITY="85"
SCRIPT_IMAGE="enonic/xp:7.16.2-ubuntu"
SCRIPT_NAMESPACE="enonic"
# Website metadata fields (SCRIPT_ABSTRACT, SCRIPT_LOGO, SCRIPT_WEBSITE, SCRIPT_TAGS, SCRIPT_SUMMARY, SCRIPT_DOCS)
```

**1.2 ConfigMap** — XP configuration in `085-enonic-config.yaml`:
- JVM heap settings via `XP_OPTS` (e.g., `-Xms512m -Xmx1g` for dev)
- Any XP configuration properties needed

**1.3 StatefulSet** — in `085-enonic-statefulset.yaml` (follow Unity Catalog pattern `320-unity-catalog-deployment.yaml`):
- ServiceAccount: `enonic-xp`
- StatefulSet with image `enonic/xp:7.16.2-ubuntu` (pinned)
- Single PVC for `$XP_HOME` (1Gi for dev, `local-path` storage class)
- Ports: 8080 (web), 4848 (management), 2609 (statistics/health)
- `xp.suPassword` injected into `system.properties` via entrypoint override (from `ENONIC_ADMIN_PASSWORD` secret)
- Startup probe: `GET /health` on port 2609 with generous timeout (first boot creates indexes)
- Readiness probe: `GET /ready` on port 2609 (validates all services operational)
- Liveness probe: `GET /health` on port 2609 (validates data services available)
- Resource requests: 500m CPU, 1Gi memory
- Service: ClusterIP on ports 8080, 4848, 2609

**1.4 IngressRoute** — follow standard pattern (`341-openmetadata-ingressroute.yaml`):
- `HostRegexp('enonic\..+')` routing to port 8080
- Namespace: `enonic`
- Label: `protection: public`

**1.5 Secrets template** — add to the OPTIONAL section in `00-common-values.env.template`:
```bash
# ================================================================
# OPTIONAL - ENONIC XP
# ================================================================
# Admin password for Enonic XP superuser (user: su)
ENONIC_ADMIN_PASSWORD=${DEFAULT_ADMIN_PASSWORD}
```

**1.6 Master secrets** — add namespace block after the openmetadata block in `00-master-secrets.yml.template`:
- Namespace: `enonic`
- Secret keys: `ENONIC_ADMIN_PASSWORD`
- Derived from `${ENONIC_ADMIN_PASSWORD}` (which defaults to `${DEFAULT_ADMIN_PASSWORD}`)

### Validation

User reviews the created files for correctness.

---

## Phase 2: Ansible Playbooks — ✅ DONE

Create the setup, remove, and verify playbooks.

### Tasks

- [x] 2.1 Create setup playbook `ansible/playbooks/085-setup-enonic.yml` ✓
- [x] 2.2 Create remove playbook `ansible/playbooks/085-remove-enonic.yml` ✓
- [x] 2.3 Create verify playbook `ansible/playbooks/085-test-enonic.yml` ✓
- [x] 2.4 Register `enonic` in `VERIFY_SERVICES` in `provision-host/uis/lib/integration-testing.sh` ✓
- [x] 2.5 Add `enonic` verify command to `provision-host/uis/manage/uis-cli.sh` ✓

### Implementation Details

**2.1 Setup playbook** — follow Unity Catalog pattern (`320-setup-unity-catalog.yml`):

1. **Prerequisites**: Create namespace, check secrets exist
2. **Deploy**: Apply ConfigMap, StatefulSet + Service + PVC via `kubernetes.core.k8s`
3. **Wait**: Wait for pod ready with generous timeout (first boot creates indexes and may take 2-3 minutes)
4. **Ingress**: Apply IngressRoute
5. **Health check**: HTTP GET to `http://enonic-xp.enonic.svc:8080/` — verify XP responds
6. **Status**: Display deployment status

No database setup needed — Enonic has embedded storage.

**2.2 Remove playbook** — follow Unity Catalog pattern (`320-remove-unity-catalog.yml`):
1. Delete IngressRoute
2. Delete StatefulSet + Service via `kubernetes.core.k8s`
3. Wait for pod termination
4. Delete PVCs
5. Delete namespace
6. Note: PVC data is lost (user warned)

**2.3 Verify playbook** (`085-test-enonic.yml`) — 6 tests, follow OpenMetadata test pattern (`340-test-openmetadata.yml`):

| Test | What | How |
|------|------|-----|
| **A. Health check** | XP data services ready | `GET :2609/health` → HTTP 200. No auth needed. Validates embedded Elasticsearch and storage are operational. |
| **B. Readiness check** | XP fully operational | `GET :2609/ready` → HTTP 200. No auth needed. Validates all services needed for full operation. |
| **C. Repository list** | Embedded storage works (read-back) | `GET :4848/repo/list` with basic auth (`su` / `ENONIC_ADMIN_PASSWORD`) → HTTP 200, response contains `"id":"system-repo"` (default repo). Proves admin auth AND embedded storage read-back work. |
| **D. UI via Traefik** | IngressRoute works | `curl -H "Host: enonic.localhost" http://<traefik-clusterip>` → HTTP 200 |
| **E. Admin UI accessible** | Admin console loads | `GET :8080/admin` with basic auth (`su` / `ENONIC_ADMIN_PASSWORD`) → HTTP 200 |
| **F. Wrong credentials** | Bad password rejected | `GET :4848/repo/list` with wrong password → HTTP 401 |

Uses `kubectl run curlimages/curl` for in-cluster testing, `ansible.builtin.assert` with `fail_msg`.

**Port notes**: Port 2609 (statistics) exposes `/health` and `/ready` endpoints without auth — ideal for probes. Port 4848 (management) requires basic auth with Administrator role — the `repo/list` endpoint lists all repositories and proves the embedded storage engine is working.

**2.4 Integration test registration** — add to `VERIFY_SERVICES` in `integration-testing.sh`:
```bash
enonic:enonic verify
```

**2.5 CLI verify command** — add `enonic` to `cmd_verify()` in `uis-cli.sh`, enabling `./uis verify enonic`.

### Validation

User reviews the playbook structure.

---

## Phase 3: Registration and Documentation — ✅ DONE

Register the service and create documentation.

### Tasks

- [x] 3.1 Add `enonic` to `.uis.extend/enabled-services.conf` ✓
- [x] 3.2 Add `packages/integration/enonic` to `website/sidebars.ts` (Integration items) ✓
- [x] 3.3 Update `website/docs/services/integration/index.md` — add Enonic to services table ✓
- [x] 3.4 Create documentation page `website/docs/services/integration/enonic.md` ✓

### Implementation Details

**3.1 enabled-services.conf** — add `enonic` line (under integration section)

**3.2 sidebars.ts** — add to Integration items array (currently has `rabbitmq` and `gravitee`):
```typescript
'packages/integration/enonic',
```

**3.3 Integration index** — add row to services table:
```markdown
| [Enonic XP](./enonic.md) | Headless CMS platform | `./uis deploy enonic` |
```

**3.4 Documentation** — follow OpenMetadata docs page pattern (`openmetadata.md`):
- Service info table (category, deploy/undeploy/verify commands, namespace)
- What It Does section
- Deploy / Verify / Undeploy sections
- Configuration section (manifests, secrets, key files)
- Troubleshooting section

### Validation

```bash
cd website && npm run build
```

User confirms documentation builds and sidebar entry appears.

---

## Phase 4: Build, Deploy, and Test — ✅ DONE

Build the provision host container, deploy, and verify with the tester.

### Tasks

- [x] 4.1 Run `./uis build` to build new provision host container ✓
- [x] 4.2 Write test instructions to `talk/talk.md` for the tester ✓
- [x] 4.3 Wait for tester results ✓ (6 rounds of testing)
- [x] 4.4 Fix any issues found during testing ✓ (5 issues fixed — see below)

### Issues Fixed During Testing

| Round | Issue | Fix |
|-------|-------|-----|
| 1 | Image `enonic/xp:7.16.2` not found | Changed to `enonic/xp:7.16.2-ubuntu` |
| 2 | Service only exposes port 8080 | Added ports 2609 and 4848 to Service |
| 2 | `XP_SU_PASSWORD` env var ignored | Password injected via `system.properties` (`xp.suPassword`) using entrypoint override |
| 3-4 | Test D: 307→401 for login page | Check response body ("Enonic XP") instead of HTTP status |
| 5 | Test E: same redirect issue | Same content-based fix |

### Implementation Details

**4.2 Test instructions** for the tester:
1. Restart with new container: `UIS_IMAGE=uis-provision-host:local ./uis restart`
2. Generate and apply secrets: `./uis secrets generate && ./uis secrets apply`
3. Deploy Enonic: `./uis deploy enonic`
4. Run verification: `./uis verify enonic` (runs all 6 E2E tests)
5. Check `http://enonic.localhost` in browser — should show XP welcome/login page
6. Login with `su` / password from `./uis secrets show DEFAULT_ADMIN_PASSWORD`
7. Undeploy: `./uis undeploy enonic`
8. Confirm cleanup: `kubectl get all -n enonic` (should show nothing)

### Validation

All 6 verify tests pass. Deploy and undeploy both succeed. Admin login works in browser.

---

## Phase 5: Cleanup and Status Updates — ✅ DONE

Update investigation, roadmap, and complete the plan.

### Tasks

- [x] 5.1 Update `INVESTIGATE-enonic-xp-deployment.md` — mark last next step as done ✓
- [x] 5.2 Update `STATUS-platform-roadmap.md` — mark #4 as Complete, add to Completed Investigations table ✓
- [x] 5.3 Move plan and investigation to `completed/` ✓

### Validation

User confirms all status updates are correct.

---

## Acceptance Criteria

- [x] Enonic XP 7.16.2 pod is running in the `enonic` namespace ✓
- [x] Admin login with `su` / `DEFAULT_ADMIN_PASSWORD` works ✓ (via `xp.suPassword` in `system.properties`)
- [x] `./uis deploy enonic` works end-to-end (no external dependencies needed) ✓
- [x] `./uis undeploy enonic` cleans up all resources ✓
- [x] `./uis verify enonic` passes all 6 tests ✓
- [x] Service appears in `./uis list` ✓
- [x] `./uis test-all --dry-run` includes enonic with verify step ✓
- [x] `http://enonic.localhost` shows Enonic XP welcome/login page ✓
- [x] Documentation page exists at the correct sidebar location ✓
- [x] Website builds without errors ✓
- [x] Tester has verified the deployment ✓ (6 rounds, all 6 E2E tests pass)

---

## Files to Create

| File | Purpose |
|------|---------|
| `provision-host/uis/services/integration/service-enonic.sh` | Service definition |
| `manifests/085-enonic-config.yaml` | ConfigMap (XP configuration) |
| `manifests/085-enonic-statefulset.yaml` | StatefulSet + Service + PVC + ServiceAccount |
| `manifests/085-enonic-ingressroute.yaml` | Traefik IngressRoute |
| `ansible/playbooks/085-setup-enonic.yml` | Deployment playbook |
| `ansible/playbooks/085-remove-enonic.yml` | Removal playbook |
| `ansible/playbooks/085-test-enonic.yml` | E2E verification (6 tests) |
| `website/docs/services/integration/enonic.md` | Documentation page |

## Files to Modify

| File | Change |
|------|--------|
| `provision-host/uis/templates/secrets-templates/00-common-values.env.template` | Add Enonic section (admin password) |
| `provision-host/uis/templates/secrets-templates/00-master-secrets.yml.template` | Add `enonic` namespace block |
| `provision-host/uis/lib/integration-testing.sh` | Add `enonic` to `VERIFY_SERVICES` |
| `provision-host/uis/manage/uis-cli.sh` | Add `enonic` to `cmd_verify()` |
| `.uis.extend/enabled-services.conf` | Add `enonic` |
| `website/sidebars.ts` | Add to Integration items |
| `website/docs/services/integration/index.md` | Add Enonic to services table |
| `website/docs/ai-developer/plans/backlog/INVESTIGATE-enonic-xp-deployment.md` | Mark last next step done |
| `website/docs/ai-developer/plans/backlog/STATUS-platform-roadmap.md` | Update #4 status |
