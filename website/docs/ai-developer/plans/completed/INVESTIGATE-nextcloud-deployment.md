# Investigate: Nextcloud Deployment

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed

**Goal**: Determine the best approach for deploying Nextcloud as a UIS platform service

**Last Updated**: 2026-03-10

---

## Questions to Answer

1. What is Nextcloud and what does it provide? ✅
2. Which existing UIS services can Nextcloud reuse? ✅
3. What category and manifest number should it use? ✅
4. What are the resource requirements — is it feasible on a developer laptop? ✅
5. Should we use the Helm chart or custom manifests? ✅
6. What does the initial setup look like (skip Authentik, keep it simple)? ✅
7. What are the exact Helm chart values for external Redis with auth? ✅
8. How does OnlyOffice JWT authentication work? ✅
9. Can OnlyOffice integration be fully automated (no manual UI steps)? ✅
10. What is the health endpoint for verify tests? ✅
11. What are the pinned versions (image, chart, OnlyOffice)? ✅
12. How should cron jobs run in Kubernetes? ✅
13. What PHP tuning is needed? ✅
14. How long does first boot take? ✅

---

## Background Research

### What is Nextcloud?

Nextcloud is a self-hosted content collaboration platform — a private cloud alternative to Google Drive, Dropbox, and Microsoft 365. It provides:

- **File sync and sharing** — store, access, and share files with desktop and mobile clients
- **Nextcloud Office** — collaborative document editing (based on LibreOffice)
- **Groupware** — Calendar, Contacts, and Mail
- **Nextcloud Talk** — audio/video calls and chat (WebRTC)
- **App ecosystem** — extensible via hundreds of apps
- **AI assistant** — local AI features for content generation, summarization, translation

Used by tens of millions of users, popular for organizations needing data sovereignty.

### Architecture

| Component | Role |
|---|---|
| **Nextcloud PHP app** | Core application — file management, APIs, web UI |
| **Web server** | Apache (bundled in Docker image) or nginx |
| **Database** | Stores metadata, users, shares, calendar/contacts |
| **Redis** | Memory cache for sessions and transactional file locking |
| **Storage** | Persistent storage for user files |
| **Cron job** | Background tasks (file scanning, cleanup, notifications) |
| **Optional: Collabora/OnlyOffice** | Document editing server (separate container) |
| **Optional: TURN/STUN server** | For Talk video calls behind NAT |

### Docker Image

- **Image**: `nextcloud:33-apache` (Nextcloud 33.0.0, updated 2026-03-03)
- **Variant**: `-apache` bundles Apache, simplest to deploy
- **Port**: 80
- **Key environment variables**:
  - `NEXTCLOUD_ADMIN_USER` / `NEXTCLOUD_ADMIN_PASSWORD` — initial admin account
  - `POSTGRES_HOST`, `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD` — database connection
  - `REDIS_HOST`, `REDIS_HOST_PORT`, `REDIS_HOST_PASSWORD` — Redis connection
  - `NEXTCLOUD_TRUSTED_DOMAINS` — allowed access domains
  - All sensitive variables support a `_FILE` suffix for Kubernetes secrets

### Helm Chart

Community-maintained chart under the Nextcloud GitHub organization:

- **Repository**: https://github.com/nextcloud/helm
- **Chart repo URL**: `https://nextcloud.github.io/helm/`
- **Helm repo add**: `helm repo add nextcloud https://nextcloud.github.io/helm/`
- **Chart version**: `9.0.3` (released 2026-03-09, targets Nextcloud 33)
- **Requires**: Helm 3.7.0+

The chart includes Bitnami sub-charts for PostgreSQL, MariaDB, and Redis — all can be **disabled** to use existing UIS services instead.

### Database Support

| Database | Supported Versions |
|---|---|
| **PostgreSQL** | 13, 14, 15, 16, 17 |
| **MySQL** | 8.0, 8.4 |
| **MariaDB** | 10.6, 10.11, 11.4 |
| **SQLite** | Testing only |

**PostgreSQL is fully supported** and is UIS's preferred database.

### Redis Usage

Redis is **strongly recommended** for:
1. **Transactional file locking** — prevents file corruption during concurrent access. Without Redis, locking falls back to the database (adds significant load).
2. **Memory caching** — sessions, distributed cache, general app cache.

Redis is the only supported backend for file locking (Memcached is not suitable).

### SSO / OIDC Support

Nextcloud supports OIDC via the "OpenID Connect user backend" app (`user_oidc`). Compatible with Authentik — official integration docs exist. **Skip for initial setup** — add later.

### Admin Interface

All administration is via the web UI at `nextcloud.localhost/settings/admin`. There is also an `occ` CLI tool inside the container for maintenance tasks:

```bash
kubectl exec -it <nextcloud-pod> -- su -s /bin/bash www-data -c "php occ status"
```

---

## Existing UIS Services That Nextcloud Can Reuse

| Nextcloud needs | UIS already has | Reusable? |
|---|---|---|
| **PostgreSQL 13+** | PostgreSQL in `default` namespace (manifest 042) | Yes — create `nextcloud` database on existing instance |
| **Redis** | Redis in `default` namespace (manifest 050) | Yes — shared instance, authentication enabled |

No new backing services needed. Nextcloud only adds the Nextcloud application pod itself.

### PostgreSQL reuse

Create a `nextcloud` database on the existing PostgreSQL instance. The setup playbook creates the database, same pattern as Unity Catalog and OpenMetadata.

### Redis reuse

Nextcloud connects to the existing Redis via the Helm chart's `externalRedis` section. The UIS Redis host is `redis-master.default.svc.cluster.local` (Bitnami naming). The Redis password is in the `default` namespace secrets as `REDIS_PASSWORD`.

The Helm chart handles Redis config automatically via `defaultConfigs.redis.config.php: true` — no need for manual PHP config.

---

## Deployment Approach

### Recommendation: Official Helm chart (v9.0.3)

Use the `nextcloud/nextcloud` Helm chart with sub-charts disabled, pointing to existing UIS services:

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

# Persistence — local-path storage class (UIS standard)
persistence:
  enabled: true
  size: 10Gi
  storageClass: local-path

# Nextcloud configuration
nextcloud:
  host: nextcloud.localhost
  trustedDomains:
    - nextcloud.localhost
    - nextcloud.tailnet-name.ts.net
  # PHP tuning — default upload limit is 2MB, increase it
  phpConfigs:
    upload.ini: |
      upload_max_filesize = 512M
      post_max_size = 512M
      memory_limit = 512M

# Cron — sidecar is simplest, runs /cron.sh alongside the main container
cronjob:
  enabled: true
  type: sidecar

# Startup probe — first boot can take 3-5 minutes (DB migrations, file copy)
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

### Health endpoint

Nextcloud exposes `/status.php` which returns JSON:

```json
{
  "installed": true,
  "maintenance": false,
  "needsDbUpgrade": false,
  "version": "33.0.0.7",
  "versionstring": "33.0.0",
  "productname": "Nextcloud"
}
```

The Helm chart probes use this endpoint automatically. The `Host: localhost` header is required in probes to avoid trusted domain rejection.

### First boot timing

First boot takes **30 seconds to 5+ minutes** depending on storage speed. The bottleneck is copying Nextcloud files to the PVC and running database schema creation. With `local-path` storage (UIS default), expect ~1-2 minutes. The `startupProbe` with `failureThreshold: 30` allows up to 5 minutes before Kubernetes gives up.

---

## Category and Manifest Number

Nextcloud is a collaboration/productivity platform. There is no COLLABORATION category in UIS. The closest existing category is **MANAGEMENT** (600-799), which contains admin and utility tools (pgAdmin, RedisInsight, ArgoCD).

Existing MANAGEMENT manifests: 641, 651, 741, 751.

**Proposed: 620** for Nextcloud.

---

## Ingress

Following the UIS pattern: `HostRegexp(`nextcloud\..+`)` routing to port 80.

Access at `http://nextcloud.localhost`.

---

## Resource Requirements

Nextcloud is lightweight compared to OpenMetadata or Enonic:

| Component | CPU request | Memory request |
|---|---|---|
| Nextcloud (Apache + PHP) | 250m | 512Mi |
| OnlyOffice Document Server | 500m | 2Gi |
| (PostgreSQL — shared, already running) | — | — |
| (Redis — shared, already running) | — | — |
| **Total new resources** | **~750m** | **~2.5Gi** |

Moderate for a developer laptop. OnlyOffice is the heavier component.

---

## Secrets Integration

Following the UIS secrets pattern (same as Unity Catalog, OpenMetadata):

**1. Variables in `00-common-values.env.template`:**

```bash
# Nextcloud + OnlyOffice
NEXTCLOUD_ADMIN_USER=admin
NEXTCLOUD_ADMIN_PASSWORD=NextcloudAdmin123
NEXTCLOUD_DB_PASSWORD=${DEFAULT_DATABASE_PASSWORD}
ONLYOFFICE_JWT_SECRET=OnlyOfficeJwtSecret123
```

**2. Secret block in `00-master-secrets.yml.template`:**

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

**3. Setup playbook** retrieves credentials from secrets, creates the database on PostgreSQL, passes credentials to Helm via `existingSecret`. The OnlyOffice JWT secret must be passed to both the OnlyOffice container (`JWT_SECRET` env var) and to Nextcloud's OnlyOffice app config (`occ config:app:set onlyoffice jwt_secret`).

### Password restrictions

Do NOT use `!`, `$`, `` ` ``, `\`, or `"` in passwords.

---

## Dependencies

```
SCRIPT_REQUIRES="postgresql redis"
```

The setup playbook should:
1. Verify PostgreSQL and Redis are running
2. Create the `nextcloud` database on the existing PostgreSQL
3. Deploy the Nextcloud Helm chart (with external DB + Redis)
4. Deploy the OnlyOffice Document Server (separate Deployment/StatefulSet)
5. Deploy IngressRoutes for both Nextcloud and OnlyOffice
6. Wait for Nextcloud to be ready (`/status.php` returns `installed: true`)
7. Install and configure the OnlyOffice connector via `occ` CLI (automated, no manual UI)
8. Display deployment summary

---

## Proposed Files

| Piece | File |
|-------|------|
| Service definition | `provision-host/uis/services/management/service-nextcloud.sh` (must include `SCRIPT_IMAGE="nextcloud:33-apache"` and website metadata) |
| Setup playbook | `ansible/playbooks/620-setup-nextcloud.yml` |
| Remove playbook | `ansible/playbooks/620-remove-nextcloud.yml` |
| Verify playbook | `ansible/playbooks/620-test-nextcloud.yml` |
| Config / Helm values | `manifests/620-nextcloud-config.yaml` |
| IngressRoute (Nextcloud) | `manifests/621-nextcloud-ingressroute.yaml` |
| OnlyOffice config | `manifests/622-onlyoffice-config.yaml` |
| IngressRoute (OnlyOffice) | `manifests/623-onlyoffice-ingressroute.yaml` |
| Secrets variables | Add to `provision-host/uis/templates/secrets-templates/00-common-values.env.template` |
| Secrets manifest | Add `nextcloud` namespace block to `provision-host/uis/templates/secrets-templates/00-master-secrets.yml.template` |
| Documentation | `website/docs/services/management/nextcloud.md` |

---

## Helm Repository

The Nextcloud Helm repo (`https://nextcloud.github.io/helm/`) is not currently registered in UIS. Add it dynamically in the setup playbook (same pattern as Elasticsearch).

---

## OnlyOffice — document editing

Nextcloud alone can store and share files but cannot edit documents in the browser. A separate document editing server is needed.

**Decision: OnlyOffice** — chosen over Collabora because the user base is familiar with Microsoft Office. OnlyOffice uses a modern ribbon UI (Microsoft Office-like) and uses OOXML (DOCX, XLSX, PPTX) as its native format, providing the best MS Office compatibility among open-source options.

### OnlyOffice licensing

OnlyOffice has two editions:

| | Community Edition | Enterprise Edition |
|---|---|---|
| **License** | AGPL v3 (open source) | Proprietary (paid) |
| **Editing features** | All — docs, spreadsheets, presentations, PDF, forms | Same |
| **Real-time collaboration** | Yes | Yes |
| **Simultaneous connections** | **Up to 20** | Thousands |
| **White label** | No | Yes |
| **Private Rooms (E2E encryption)** | No | Yes |
| **Support** | GitHub / forum | Priority support tiers |

**For UIS (local dev): Community Edition is fine.** The 20 connection limit is not a concern. All editing features are identical. If this moves to production with more than 20 concurrent users, an Enterprise license would be needed.

### OnlyOffice details

- **Docker image**: `onlyoffice/documentserver:9.3.1` (Community Edition, ~1.5 GB, updated 2026-03-05)
- **Port**: 80 (HTTP)
- **Resource requirements**: ~2-4 GiB RAM (heavier than Collabora)
- **No database needed** — OnlyOffice Document Server is stateless, it processes documents sent by Nextcloud
- **Deployment**: Simple Kubernetes Deployment + Service (no Helm chart needed for a single container)

### OnlyOffice JWT authentication

OnlyOffice uses JWT to authenticate requests from Nextcloud. Since v7.2, JWT is **enabled by default** and a random secret is generated if not set explicitly — this breaks on every restart.

**Must set explicitly:**
- `JWT_SECRET` environment variable on the OnlyOffice container
- `jwt_secret` config key in Nextcloud's OnlyOffice app (via `occ`)

Both values must match.

### OnlyOffice integration — fully automated via occ CLI

No manual web UI steps required. The setup playbook automates everything:

```bash
# 1. Install the OnlyOffice connector app
kubectl exec <nextcloud-pod> -- su -s /bin/bash www-data -c "php occ app:install onlyoffice"

# 2. Set the Document Server URL (internal cluster address)
kubectl exec <nextcloud-pod> -- su -s /bin/bash www-data -c \
  "php occ config:app:set onlyoffice DocumentServerUrl --value='http://onlyoffice.localhost'"

# 3. Set internal server-to-server URL (bypasses ingress)
kubectl exec <nextcloud-pod> -- su -s /bin/bash www-data -c \
  "php occ config:app:set onlyoffice DocumentServerInternalUrl --value='http://onlyoffice-svc.nextcloud.svc.cluster.local:80'"

# 4. Set the storage URL (how OnlyOffice calls back to Nextcloud)
kubectl exec <nextcloud-pod> -- su -s /bin/bash www-data -c \
  "php occ config:app:set onlyoffice StorageUrl --value='http://nextcloud.nextcloud.svc.cluster.local:80'"

# 5. Set the shared JWT secret (must match OnlyOffice container's JWT_SECRET)
kubectl exec <nextcloud-pod> -- su -s /bin/bash www-data -c \
  "php occ config:app:set onlyoffice jwt_secret --value='<secret-from-k8s-secret>'"
```

### OnlyOffice ingress

Separate hostname: `HostRegexp(`onlyoffice\..+`)` routing to port 80.

Access at `http://onlyoffice.localhost`. Nextcloud connects to it internally via `http://onlyoffice-service.nextcloud.svc.cluster.local` (or similar).

### OnlyOffice resource estimate

| Component | CPU request | Memory request |
|---|---|---|
| OnlyOffice Document Server | 500m | 2Gi |

This is significant for a laptop. Combined with Nextcloud itself (~250m CPU, 512Mi), the total is ~750m CPU and ~2.5Gi RAM for the Nextcloud + OnlyOffice stack.

### Proposed OnlyOffice files

| Piece | File |
|-------|------|
| Config / Helm values | `manifests/622-onlyoffice-config.yaml` |
| IngressRoute | `manifests/623-onlyoffice-ingressroute.yaml` |

OnlyOffice is deployed as part of the Nextcloud setup playbook (`620-setup-nextcloud.yml`) — not a separate UIS service.

---

## Verify Playbook Plan

The verify playbook (`620-test-nextcloud.yml`) should test these scenarios:

| Test | What it checks |
|------|---------------|
| A. Health endpoint | `GET /status.php` returns `installed: true` and `maintenance: false` |
| B. Admin login | Login with admin credentials returns 200 (not redirect to setup) |
| C. Wrong credentials | Login with bad password returns 401 |
| D. Traefik routing | `http://nextcloud.localhost` resolves to Nextcloud |
| E. OnlyOffice health | OnlyOffice healthcheck endpoint returns 200 |
| F. OnlyOffice JWT | OnlyOffice rejects unsigned requests (JWT enforcement) |

Register in `integration-testing.sh` (VERIFY_SERVICES) and `uis-cli.sh` (cmd_verify).

---

## What we skip for initial setup

- **Authentik SSO** — use Nextcloud's built-in admin account. Add OIDC later.
- **TURN/STUN server** — only needed for Talk video calls behind NAT.
- **SMTP** — email notifications. Not needed for local dev.
- **enabled-services.conf** — add commented-out entry during implementation.
- **Stack membership** — consider a "collaboration" stack if more tools are added later.

---

## Next Steps

- [x] Create PLAN-nextcloud-deployment.md with implementation phases ✓
- [x] Implement and deploy Nextcloud + OnlyOffice (8 E2E tests pass) ✓
