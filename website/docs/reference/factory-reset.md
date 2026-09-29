# Factory Reset and Full Verification

How to factory-reset Rancher Desktop, rebuild from scratch, and verify all services.

## When to Use This

- After major infrastructure changes (secrets migration, path changes, etc.)
- When the cluster is in an unknown state and you want a clean start
- To verify that the entire system works end-to-end from zero

## What Gets Wiped

Rancher Desktop → Troubleshooting → Factory Reset wipes:

| Wiped | Survives |
|-------|----------|
| K3s cluster, all pods | Host filesystem files |
| PersistentVolumes | `.uis.extend/` directory |
| Docker containers and images | `.uis.secrets/` directory |
| Rancher Desktop settings | Repository files |

The `uis-provision-host` container and image are destroyed. You must rebuild locally.

## Recovery Procedure

### 0. Write down the settings first

🔴 **"Rancher Desktop settings" in the table above includes the VM allocation.** Memory, CPU and disk size go back to defaults, and a cluster with less RAM than before fails in ways that look like UIS defects. Record them before you reset:

```
Rancher Desktop → Preferences → Virtual Machine → Memory / CPUs / Disk size
```

🔵 `.uis.extend/` and `.uis.secrets/` survive a factory reset, so your secrets and your enabled-service list do not need rebuilding — provided you skip the optional `rm -rf` in step 2.

### 1. Factory Reset

1. Open Rancher Desktop → Troubleshooting → **Factory Reset**
2. Wait for Rancher Desktop to restart
3. Re-enable Kubernetes in Rancher Desktop settings
4. Wait for Kubernetes to show "Running" (can take a few minutes)

### 2. Clean Slate (optional)

If you want a completely fresh test with no leftover config:

```bash
rm -rf .uis.extend .uis.secrets
```

Skip this step if you want to preserve your existing secrets and configuration.

### 3. Start, and check you are running what you think you are

```bash
# Start the container. The image was wiped, so this pulls it from the registry.
./uis start

# 🔴 Confirm which image you are testing, BEFORE deploying anything
./uis version
docker image inspect --format '{{index .RepoDigests 0}}' ghcr.io/helpers-no/uis-provision-host:latest

# Verify cluster is healthy
./uis exec kubectl get nodes
./uis exec kubectl get pods -A
```

:::danger Do not run `./uis build` here

The previous version of this runbook said to rebuild locally *"since factory reset wiped it"*. **That is wrong, and it quietly invalidates a release test.**

- `./uis start` pulls the image by itself — `check_image()` in `./uis` pulls when the image is absent, which after a reset it always is.
- `./uis build` tags **`uis-provision-host:local`**, and `./uis start` uses `${UIS_IMAGE:-ghcr.io/helpers-no/uis-provision-host:latest}`. So the build is several minutes spent producing an image nothing then runs.
- 🔴 Worse, it reads as though you are now testing your own build. If you are verifying a release, build nothing.

⚠️ And check the **digest**, not just the tag. A tag is a pointer: on 2026-09-29 `1.6.176` was rebuilt and served two different digests within seven minutes (`urb-agents#1736`, [merges-that-build-nothing](../ai-developer/plans/backlog/INVESTIGATE-merges-that-build-nothing.md)).

:::

### 4. Deploy Services

```bash
# Deploy all enabled services
./uis deploy

# Or deploy individual services
./uis deploy whoami
```

The `ensure_secrets_applied()` function in `first-run.sh` automatically re-applies secrets to a fresh cluster before every deployment.

## Service Deployment Order

Deploy in this order to respect dependencies:

### Phase 1: Core (no dependencies)

| # | Service | Notes |
|---|---------|-------|
| 1 | **nginx** | Default enabled service, verifies system is running |
| 2 | **whoami** | Simplest service, baseline test |

### Phase 2: Databases (no dependencies)

| # | Service | Notes |
|---|---------|-------|
| 3 | **postgresql** | Required by authentik, openwebui, litellm, unity-catalog |
| 4 | **redis** | Required by authentik |
| 5 | **mysql** | Standalone |
| 6 | **mongodb** | Standalone |
| 7 | **qdrant** | Standalone vector database |
| 8 | **elasticsearch** | Standalone search |
| 9 | **rabbitmq** | Standalone queue |

### Phase 3: Services with dependencies

| # | Service | Depends on |
|---|---------|------------|
| 10 | **authentik** | postgresql, redis |
| 11 | **openwebui** | postgresql |
| 12 | **litellm** | postgresql |

### Phase 4: Monitoring (no dependencies)

| # | Service | Notes |
|---|---------|-------|
| 13 | **prometheus** | Standalone |
| 14 | **grafana** | Standalone |
| 15 | **loki** | Standalone |
| 16 | **tempo** | Standalone |
| 17 | **otel-collector** | Standalone |

### Phase 5: Management and Data Science

| # | Service | Depends on |
|---|---------|------------|
| 18 | **argocd** | Standalone |
| 19 | **pgadmin** | Standalone (connects to postgresql) |
| 20 | **redisinsight** | Standalone (connects to redis) |
| 21 | **jupyterhub** | Standalone |
| 22 | **spark** | Standalone |
| 23 | **unity-catalog** | postgresql |

### Skip (require external accounts)

| Service | Why |
|---------|-----|
| **tailscale-tunnel** | Requires Tailscale auth key |
| **cloudflare-tunnel** | Requires Cloudflare token |
| **gravitee** | Was broken before migration, needs fresh setup |

## Verification Checklist

For each service, verify:

1. **Deploy**: `./uis deploy <service>` — completes without errors
2. **Pods running**: `./uis exec kubectl get pods -A` — pods show Running/Ready
3. **Undeploy**: `./uis undeploy <service>` — completes without errors
4. **Clean removal**: `./uis exec kubectl get pods -A` — no leftover pods

### Stack Tests

After individual services pass, test full stacks:

- **Observability**: prometheus + grafana + loki + tempo + otel-collector
- **AI**: postgresql + openwebui + litellm
- **Data Science**: postgresql + jupyterhub + spark + unity-catalog
- **Authentication**: postgresql + redis + authentik

## Known Issues from Previous Resets

Issues discovered during factory reset testing (2026-02-20) that have been fixed:

- Config files not created on `./uis start` (lazy initialization) — fixed in first-run.sh
- Shell arithmetic bug with `wc -l` whitespace in Redis/RabbitMQ removal playbooks
- RabbitMQ health check used wrong namespace
- Unity Catalog: wrong image, wrong security context, wrong API version
- pgAdmin: `admin@localhost` rejected by email validator (now `admin@example.com`)
- pgAdmin: OOM on login with 256Mi memory (now 512Mi)
- Secrets generation: missing `mkdir -p` for config directory
- Default secrets: hardcoded values instead of reading from `default-secrets.env`

These are fixed but listed here so future testers know what to watch for if similar patterns emerge.
