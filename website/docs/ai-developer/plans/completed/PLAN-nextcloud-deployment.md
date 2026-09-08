# Deploy Nextcloud + OnlyOffice

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed

**Goal**: Deploy Nextcloud 33 with OnlyOffice Document Server as a UIS platform service, reusing existing PostgreSQL and Redis

**Last Updated**: 2026-03-10

**Investigation**: [INVESTIGATE-nextcloud-deployment.md](../completed/INVESTIGATE-nextcloud-deployment.md)

---

## Overview

Nextcloud is a self-hosted collaboration platform (file sync, document editing, calendar, contacts). It will be deployed as manifest 620 in the MANAGEMENT category using the official Helm chart (v9.0.3). OnlyOffice Document Server provides browser-based document editing (DOCX, XLSX, PPTX) and is deployed as a separate Deployment in the same namespace.

Key decisions from investigation:
- **Nextcloud image**: `nextcloud:33-apache` (Nextcloud 33.0.0, pinned)
- **OnlyOffice image**: `onlyoffice/documentserver:9.3.1` (~1.5 GB, pinned)
- **Helm chart**: `nextcloud/nextcloud` v9.0.3
- **Pattern**: Helm for Nextcloud, plain Deployment for OnlyOffice
- **Category**: MANAGEMENT, manifest **620**
- **Namespace**: `nextcloud`
- **Dependencies**: Reuses existing PostgreSQL (manifest 042) and Redis (manifest 050) — no new backing services
- **Redis host**: `redis-master.default.svc.cluster.local` (Bitnami naming)
- **Admin**: `admin` / password from `NEXTCLOUD_ADMIN_PASSWORD` secret
- **OnlyOffice JWT**: Shared secret (`ONLYOFFICE_JWT_SECRET`) must match between containers
- **OnlyOffice integration**: Fully automated via `occ` CLI — no manual UI steps
- **Cron**: Sidecar container running `/cron.sh`
- **Health endpoint**: `GET /status.php` returns JSON with `installed`, `maintenance`, `needsDbUpgrade`
- **First boot**: 1–5 minutes (DB migrations, file copy). Startup probe allows 5 minutes.
- **PHP tuning**: Upload limit increased to 512M (default is 2MB)

---

## Phase 1: Service Definition and Configuration Files — ✅ DONE

Create all static files needed before deployment.

### Tasks

- [x] 1.1 Create service definition `provision-host/uis/services/management/service-nextcloud.sh` ✓
- [x] 1.2 Create Helm values `manifests/620-nextcloud-config.yaml` ✓
- [x] 1.3 Create Nextcloud IngressRoute `manifests/621-nextcloud-ingressroute.yaml` ✓
- [x] 1.4 Create OnlyOffice config `manifests/622-onlyoffice-config.yaml` (Deployment + Service) ✓
- [x] 1.5 Create OnlyOffice IngressRoute `manifests/623-onlyoffice-ingressroute.yaml` ✓
- [x] 1.6 Add Nextcloud + OnlyOffice secrets to `provision-host/uis/templates/secrets-templates/00-common-values.env.template` ✓
- [x] 1.7 Add `nextcloud` namespace block to `provision-host/uis/templates/secrets-templates/00-master-secrets.yml.template` ✓

### Implementation Details

**1.1 Service definition** — follow the OpenMetadata pattern (`service-openmetadata.sh`):
```bash
SCRIPT_ID="nextcloud"
SCRIPT_NAME="Nextcloud"
SCRIPT_DESCRIPTION="Self-hosted collaboration platform with file sync and document editing"
SCRIPT_CATEGORY="MANAGEMENT"
SCRIPT_PLAYBOOK="620-setup-nextcloud.yml"
SCRIPT_REMOVE_PLAYBOOK="620-remove-nextcloud.yml"
SCRIPT_CHECK_COMMAND="kubectl get pods -n nextcloud -l app.kubernetes.io/name=nextcloud --no-headers 2>/dev/null | grep -q Running"
SCRIPT_REQUIRES="postgresql redis"
SCRIPT_PRIORITY="620"
SCRIPT_IMAGE="nextcloud:33-apache"
SCRIPT_HELM_CHART="nextcloud/nextcloud"
SCRIPT_NAMESPACE="nextcloud"
# Website metadata fields (SCRIPT_ABSTRACT, SCRIPT_LOGO, SCRIPT_WEBSITE, SCRIPT_TAGS, SCRIPT_SUMMARY, SCRIPT_DOCS)
```

**1.2 Helm values** — `620-nextcloud-config.yaml`:
```yaml
# Disable bundled sub-charts — use existing UIS services
internalDatabase:
  enabled: false
postgresql:
  enabled: false
mariadb:
  enabled: false
redis:
  enabled: false

# Point to existing PostgreSQL
externalDatabase:
  enabled: true
  type: postgresql
  host: postgresql.default.svc.cluster.local
  database: nextcloud
  existingSecret:
    enabled: true
    secretName: urbalurba-secrets
    usernameKey: NEXTCLOUD_DATABASE_USER
    passwordKey: NEXTCLOUD_DATABASE_PASSWORD

# Point to existing Redis
externalRedis:
  enabled: true
  host: redis-master.default.svc.cluster.local
  port: "6379"
  existingSecret:
    enabled: true
    secretName: urbalurba-secrets
    passwordKey: REDIS_PASSWORD

# Persistence
persistence:
  enabled: true
  size: 10Gi
  storageClass: local-path

# Nextcloud configuration
nextcloud:
  host: nextcloud.localhost
  existingSecret:
    enabled: true
    secretName: urbalurba-secrets
    usernameKey: NEXTCLOUD_ADMIN_USER
    passwordKey: NEXTCLOUD_ADMIN_PASSWORD
  trustedDomains:
    - nextcloud.localhost
  phpConfigs:
    upload.ini: |
      upload_max_filesize = 512M
      post_max_size = 512M
      memory_limit = 512M

# Cron — sidecar is simplest
cronjob:
  enabled: true
  type: sidecar

# Probes — generous startup for first boot (DB migrations, file copy)
startupProbe:
  enabled: true
  initialDelaySeconds: 30
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 30
livenessProbe:
  enabled: true
  initialDelaySeconds: 10
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 3
readinessProbe:
  enabled: true
  initialDelaySeconds: 10
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 3
```

**1.3 Nextcloud IngressRoute** — standard UIS pattern:
- `HostRegexp('nextcloud\..+')` routing to port 80
- Namespace: `nextcloud`
- Label: `protection: public`

**1.4 OnlyOffice config** — plain Kubernetes Deployment + Service in namespace `nextcloud`:
- Image: `onlyoffice/documentserver:9.3.1` (~1.5 GB — first pull takes several minutes)
- Service name: `onlyoffice-svc` (referenced by occ commands in setup playbook)
- Port: 80
- Env: `JWT_ENABLED=true`, `JWT_SECRET` from secret `urbalurba-secrets` key `ONLYOFFICE_JWT_SECRET`
- Resource requests: 500m CPU, 2Gi memory
- Readiness probe: `GET /healthcheck` on port 80 (OnlyOffice takes 30-60s to initialize)
- No PVC needed (stateless)

**1.5 OnlyOffice IngressRoute** — standard UIS pattern:
- `HostRegexp('onlyoffice\..+')` routing to port 80
- Namespace: `nextcloud`
- Label: `protection: public`

**1.6 Secrets template** — add to the OPTIONAL section in `00-common-values.env.template`:
```bash
# Nextcloud + OnlyOffice
NEXTCLOUD_ADMIN_USER=admin
NEXTCLOUD_ADMIN_PASSWORD=NextcloudAdmin123
ONLYOFFICE_JWT_SECRET=OnlyOfficeJwtSecret123
```

**1.7 Master secrets** — add namespace block in `00-master-secrets.yml.template`:
```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: nextcloud
---
apiVersion: v1
kind: Secret
metadata:
  name: urbalurba-secrets
  namespace: nextcloud
type: Opaque
stringData:
  NEXTCLOUD_ADMIN_USER: "${NEXTCLOUD_ADMIN_USER}"
  NEXTCLOUD_ADMIN_PASSWORD: "${NEXTCLOUD_ADMIN_PASSWORD}"
  NEXTCLOUD_DATABASE_USER: "postgres"
  NEXTCLOUD_DATABASE_PASSWORD: "${PGPASSWORD}"
  REDIS_PASSWORD: "${REDIS_PASSWORD}"
  ONLYOFFICE_JWT_SECRET: "${ONLYOFFICE_JWT_SECRET}"
```

### Validation

User reviews the created files for correctness.

---

## Phase 2: Ansible Playbooks — ✅ DONE

Create the setup, remove, and verify playbooks.

### Tasks

- [x] 2.1 Create setup playbook `ansible/playbooks/620-setup-nextcloud.yml` ✓
- [x] 2.2 Create remove playbook `ansible/playbooks/620-remove-nextcloud.yml` ✓
- [x] 2.3 Create verify playbook `ansible/playbooks/620-test-nextcloud.yml` ✓
- [x] 2.4 Register `nextcloud` in `VERIFY_SERVICES` in `provision-host/uis/lib/integration-testing.sh` ✓
- [x] 2.5 Add `nextcloud` verify command to `provision-host/uis/manage/uis-cli.sh` ✓

### Implementation Details

**2.1 Setup playbook** — follow OpenMetadata pattern (`340-setup-openmetadata.yml`):

Key vars:
```yaml
helm_release_name: "nextcloud"       # Determines K8s Service name
helm_chart: "nextcloud/nextcloud"
helm_chart_version: "9.0.3"
```

Steps:
1. **Prerequisites**: Create namespace, check secrets exist, verify PostgreSQL and Redis are running
2. **Database**: Create `nextcloud` database on existing PostgreSQL (same pattern as OpenMetadata)
3. **Helm repo**: Add `nextcloud` repo (`https://nextcloud.github.io/helm/`) via `kubernetes.core.helm_repository`
4. **Helm install**: Install chart with `--version 9.0.3` and values from `620-nextcloud-config.yaml`
5. **Nextcloud IngressRoute**: Apply `621-nextcloud-ingressroute.yaml`
6. **Wait for Nextcloud**: Wait for pod ready (startup probe handles first boot — up to 5 minutes)
7. **Deploy OnlyOffice**: Apply `622-onlyoffice-config.yaml` (Deployment + Service). Note: image is ~1.5 GB, first pull takes several minutes
8. **OnlyOffice IngressRoute**: Apply `623-onlyoffice-ingressroute.yaml`
9. **Wait for OnlyOffice**: Wait for OnlyOffice pod ready (readiness probe on `/healthcheck`, ~30-60s)
10. **Configure OnlyOffice integration** via `occ` CLI (requires internet — Nextcloud downloads the connector app from the App Store):
    ```bash
    # Install the OnlyOffice connector app (downloads from Nextcloud App Store — needs internet)
    kubectl exec <nextcloud-pod> -- su -s /bin/bash www-data -c "php occ app:install onlyoffice"
    # Set Document Server URL (public, for browser access)
    kubectl exec <nextcloud-pod> -- su -s /bin/bash www-data -c \
      "php occ config:app:set onlyoffice DocumentServerUrl --value='http://onlyoffice.localhost'"
    # Set internal server-to-server URL (bypasses ingress, uses K8s Service name from 622-onlyoffice-config.yaml)
    kubectl exec <nextcloud-pod> -- su -s /bin/bash www-data -c \
      "php occ config:app:set onlyoffice DocumentServerInternalUrl --value='http://onlyoffice-svc.nextcloud.svc.cluster.local:80'"
    # Set storage URL (how OnlyOffice calls back to Nextcloud, uses Helm release name as Service name)
    kubectl exec <nextcloud-pod> -- su -s /bin/bash www-data -c \
      "php occ config:app:set onlyoffice StorageUrl --value='http://nextcloud.nextcloud.svc.cluster.local:80'"
    # Set shared JWT secret (must match JWT_SECRET env var on OnlyOffice container)
    kubectl exec <nextcloud-pod> -- su -s /bin/bash www-data -c \
      "php occ config:app:set onlyoffice jwt_secret --value='<secret-from-k8s-secret>'"
    ```
    **Important:** The Nextcloud Service name (`nextcloud`) comes from `helm_release_name`. The OnlyOffice Service name (`onlyoffice-svc`) is defined in `622-onlyoffice-config.yaml`. Both must match the URLs above.
11. **Status**: Display deployment summary with URLs

**2.2 Remove playbook** — follow OpenMetadata pattern (`300-remove-openmetadata.yml`):
1. Remove OnlyOffice IngressRoute
2. Delete OnlyOffice Deployment + Service
3. Remove Nextcloud Helm release
4. Remove Nextcloud IngressRoute
5. Delete PVCs (opt-in via `remove_pvc` flag)
6. Drop `nextcloud` database from PostgreSQL (opt-in via `remove_database` flag)
7. Delete namespace

**2.3 Verify playbook** (`620-test-nextcloud.yml`) — 6 tests:

| Test | What | How |
|------|------|-----|
| **A. Health endpoint** | Nextcloud is installed and running | `GET /status.php` → JSON contains `"installed":true` and `"maintenance":false` |
| **B. Admin login via WebDAV** | Admin credentials work | `GET /remote.php/dav` with basic auth (admin + correct password) → HTTP 200 with multistatus XML |
| **C. Wrong credentials** | Bad password rejected | `GET /remote.php/dav` with basic auth (admin + wrong password) → HTTP 401 |
| **D. Traefik routing** | IngressRoute works for Nextcloud | `curl -H "Host: nextcloud.localhost" http://<traefik-clusterip>` → HTTP 200 |
| **E. OnlyOffice health** | OnlyOffice is running | `GET /healthcheck` on OnlyOffice service → response contains `true` |
| **F. OnlyOffice JWT** | JWT enforcement works | Unsigned request to OnlyOffice command endpoint → rejected |

Uses `kubectl run curlimages/curl` for in-cluster testing.

**2.4 Integration test registration** — add to `VERIFY_SERVICES` in `integration-testing.sh`:
```bash
nextcloud:nextcloud verify
```

**2.5 CLI verify command** — add `nextcloud` to `cmd_verify()` in `uis-cli.sh`, enabling `./uis verify nextcloud`.

### Validation

User reviews the playbook structure.

---

## Phase 3: Build, Deploy, and Test

Build the provision host container, deploy, and verify with the tester. This must pass before writing documentation.

### Tasks

- [x] 3.1 Run `./uis build` to build new provision host container ✓
- [x] 3.2 Rename existing `talk/talk.md` to `talk/talk20.md` and create new `talk/talk.md` with test instructions ✓
- [ ] 3.3 Wait for tester results
- [ ] 3.4 Fix any issues found during testing

### Implementation Details

**3.2 Test instructions** — rename existing `talk.md` → `talk20.md`, then create new `talk.md` for the tester:
1. Restart with new container: `UIS_IMAGE=uis-provision-host:local ./uis restart`
2. Generate and apply secrets: `./uis secrets generate && ./uis secrets apply`
3. Ensure PostgreSQL and Redis are running: `./uis deploy postgresql && ./uis deploy redis`
4. Deploy Nextcloud: `./uis deploy nextcloud`
5. Run verification: `./uis verify nextcloud` (runs all 6 E2E tests)
6. Check `http://nextcloud.localhost` in browser — should show Nextcloud login page
7. Login with `admin` / password from `./uis secrets show NEXTCLOUD_ADMIN_PASSWORD`
8. Check `http://onlyoffice.localhost` in browser — should show OnlyOffice welcome page
9. Create a DOCX file in Nextcloud — should open in OnlyOffice editor
10. Undeploy: `./uis undeploy nextcloud`
11. Confirm cleanup: `kubectl get all -n nextcloud` (should show nothing)

### Validation

All 6 verify tests pass. Deploy and undeploy both succeed. Admin login works in browser. Document editing via OnlyOffice works.

---

## Phase 4: Registration and Documentation

Register the service and create documentation. Only after deployment is verified working.

### Tasks

- [ ] 4.1 Add `nextcloud` to `provision-host/uis/templates/uis.extend/enabled-services.conf.default` (commented out)
- [ ] 4.2 Add `packages/management/nextcloud` to `website/sidebars.ts`
- [ ] 4.3 Update `website/docs/services/management/index.md` — add Nextcloud to services table
- [ ] 4.4 Create documentation page `website/docs/services/management/nextcloud.md`
- [ ] 4.5 Update `website/src/data/services.json` — add Nextcloud entry

### Implementation Details

**4.4 Documentation** — follow OpenMetadata docs page pattern:
- Service info table (category, deploy/undeploy/verify commands, namespace, URLs)
- What It Does section (file sync, document editing via OnlyOffice, calendar, contacts)
- Deploy / Verify / Undeploy sections
- Configuration section (manifests, secrets, key files)
- OnlyOffice section (what it provides, JWT authentication)
- Troubleshooting section (first boot slow, PVC cleanup, Redis connection, upload limits)

### Validation

```bash
cd website && npm run build
```

User confirms documentation builds and sidebar entry appears.

---

## Phase 5: Cleanup and Status Updates

Update investigation, roadmap, and complete the plan.

### Tasks

- [ ] 5.1 Update `INVESTIGATE-nextcloud-deployment.md` — mark next step as done
- [ ] 5.2 Update `STATUS-platform-roadmap.md` — mark #7 as Complete, add to Completed Investigations table
- [ ] 5.3 Move plan and investigation to `completed/`

### Validation

User confirms all status updates are correct.

---

## Acceptance Criteria

- [ ] Nextcloud 33 pod is running in the `nextcloud` namespace
- [ ] Admin login with `admin` / `NEXTCLOUD_ADMIN_PASSWORD` works
- [ ] `./uis deploy nextcloud` works end-to-end (creates database, deploys Helm, configures OnlyOffice)
- [ ] `./uis undeploy nextcloud` cleans up all resources
- [ ] `./uis verify nextcloud` passes all 6 tests
- [ ] Service appears in `./uis list`
- [ ] `./uis test-all --dry-run` includes nextcloud with verify step
- [ ] `http://nextcloud.localhost` shows Nextcloud login page
- [ ] `http://onlyoffice.localhost` shows OnlyOffice welcome page
- [ ] Document editing via OnlyOffice works (create/edit DOCX in browser)
- [ ] File upload works with files up to 512MB
- [ ] Documentation page exists at the correct sidebar location
- [ ] Website builds without errors

---

## Files to Create

| File | Purpose |
|------|---------|
| `provision-host/uis/services/management/service-nextcloud.sh` | Service definition |
| `manifests/620-nextcloud-config.yaml` | Helm values |
| `manifests/621-nextcloud-ingressroute.yaml` | Nextcloud IngressRoute |
| `manifests/622-onlyoffice-config.yaml` | OnlyOffice Deployment + Service |
| `manifests/623-onlyoffice-ingressroute.yaml` | OnlyOffice IngressRoute |
| `ansible/playbooks/620-setup-nextcloud.yml` | Deployment playbook |
| `ansible/playbooks/620-remove-nextcloud.yml` | Removal playbook |
| `ansible/playbooks/620-test-nextcloud.yml` | E2E verification (6 tests) |
| `website/docs/services/management/nextcloud.md` | Documentation page |

## Files to Modify

| File | Change |
|------|--------|
| `provision-host/uis/templates/secrets-templates/00-common-values.env.template` | Add Nextcloud + OnlyOffice section |
| `provision-host/uis/templates/secrets-templates/00-master-secrets.yml.template` | Add `nextcloud` namespace block |
| `provision-host/uis/lib/integration-testing.sh` | Add `nextcloud` to `VERIFY_SERVICES` |
| `provision-host/uis/manage/uis-cli.sh` | Add `nextcloud` to `cmd_verify()` |
| `provision-host/uis/templates/uis.extend/enabled-services.conf.default` | Add `nextcloud` (commented out) |
| `website/sidebars.ts` | Add to Management items |
| `website/docs/services/management/index.md` | Add Nextcloud to services table |
| `website/src/data/services.json` | Add Nextcloud entry |
| `website/docs/ai-developer/plans/backlog/INVESTIGATE-nextcloud-deployment.md` | Mark next step done |
| `website/docs/ai-developer/plans/backlog/STATUS-platform-roadmap.md` | Update #7 status |
