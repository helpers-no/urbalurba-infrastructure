# INVESTIGATE: Rancher Reset and Full Service Verification

**Related**: [STATUS-service-migration](STATUS-service-migration.md), [INVESTIGATE-unity-catalog-crashloop](INVESTIGATE-unity-catalog-crashloop.md)
**Created**: 2026-02-19
**Status:** Completed
**Completed**: 2026-02-20

## Goal

Determine the exact procedure to factory-reset Rancher Desktop, reprovision from scratch, and verify all 24 services deploy and undeploy correctly.

## Factory Reset

Rancher Desktop → Troubleshooting → Factory Reset:
- **Wipes**: K3s cluster, all pods, PersistentVolumes, Docker containers, Docker images, Rancher Desktop settings
- **Survives**: Only host filesystem files (`.uis.extend/`, `.uis.secrets/`, repo files)

The `uis-provision-host` container and image are wiped by factory reset and must be rebuilt locally before use.

The tester must delete any previous `.uis.extend/` and `.uis.secrets/` folders so that we have a clean test.

## Recovery Procedure

After factory reset and re-enabling Kubernetes:

### Contributor (builds image and prepares tester)

```bash
./uis build            # rebuild the container image locally
cp uis <tester-dir>/   # copy the uis wrapper to the tester directory
```

The contributor verifies the image builds successfully before handing off to the tester.

### Tester (clean slate verification)

```bash
rm -rf .uis.extend .uis.secrets   # ensure no leftover config
./uis start            # uis wrapper creates .uis.extend/ and .uis.secrets/, starts container
./uis deploy           # calls ensure_secrets_applied() automatically, deploys enabled services
```

For individual services:
```bash
./uis deploy <service>
```

The `ensure_secrets_applied()` function in `first-run.sh` handles re-applying secrets to a fresh cluster. The `uis deploy` command calls it before every deployment.

## Final Verification Status

**26/26 services defined, 23/26 verified.** All testable services deploy and undeploy cleanly from a factory-reset clean slate.

| Status | Services |
|--------|----------|
| Verified (23) | nginx, whoami, postgresql, redis, mysql, mongodb, qdrant, elasticsearch, rabbitmq, authentik, openwebui, litellm, prometheus, grafana, loki, tempo, otel-collector, argocd, jupyterhub, spark, unity-catalog, pgadmin, redisinsight |
| Skipped (3) | gravitee (broken before migration), tailscale-tunnel (requires auth key), cloudflare-tunnel (requires token) |

Tested across 8 rounds in talk9.md + 8 rounds in talk10.md. Bugs found and fixed during testing:
- Lazy initialization (config files not created on `./uis start`)
- Schema regex too strict for `removePlaybook` with parameters
- Shell arithmetic bug (`wc -l` whitespace) in Redis/RabbitMQ removal playbooks
- RabbitMQ health check wrong namespace
- Unity Catalog: wrong image, wrong security context, wrong API version, no curl in container (see [INVESTIGATE-unity-catalog-crashloop](INVESTIGATE-unity-catalog-crashloop.md))
- pgAdmin: `admin@localhost` rejected by email validator, changed to `admin@example.com`
- pgAdmin: OOM on login with 256Mi memory limit, increased to 512Mi
- pgAdmin/RedisInsight removal playbooks: same `grep -c` "Illegal number" bug
- Secrets generation: missing `mkdir -p` for `secrets-config/` directory
- Default secrets duplication: `first-run.sh` hardcoded values instead of reading from `default-secrets.env`

## Proposed Test Strategy

### Phase 1: Reset and Bootstrap

1. Factory reset Rancher Desktop
2. Re-enable Kubernetes, wait for ready
3. `./uis build` — rebuild the container image locally
4. `./uis start` — creates container from local image
5. `./uis secrets apply`
6. Verify cluster is healthy: `kubectl get nodes`, `kubectl get pods -A`

### Phase 2: Deploy and Verify Each Service

Test each service: deploy → verify pods running → verify connectivity → undeploy → verify clean removal.

**Suggested order** (dependencies first):

1. **nginx** — used by automatic install to verify the system is started
2. **whoami** — simplest service, baseline test
3. **postgresql** — required by authentik, openwebui, litellm, unity-catalog
4. **redis** — required by authentik
5. **mysql** — standalone database
6. **mongodb** — standalone database
7. **qdrant** — standalone vector database
8. **elasticsearch** — standalone search
9. **rabbitmq** — standalone queue
10. **authentik** — depends on postgresql + redis
11. **openwebui** — depends on postgresql
12. **litellm** — depends on postgresql
13. **prometheus** — monitoring, standalone
14. **grafana** — monitoring, standalone
15. **loki** — monitoring, standalone
16. **tempo** — monitoring, standalone
17. **otel-collector** — monitoring, standalone
18. **argocd** — management
19. **jupyterhub** — data science
20. **spark** — data science
21. **unity-catalog** — data science, depends on postgresql

Skip for now (require external accounts or broken):
- **tailscale-tunnel** — requires Tailscale auth key
- **cloudflare-tunnel** — requires Cloudflare token
- **gravitee** — was broken before migration

### Phase 3: Stack Tests

After individual verification, test deploying full stacks:
- Observability stack: prometheus + grafana + loki + tempo + otel-collector
- AI stack: openwebui + litellm
- Data science stack: jupyterhub + spark + unity-catalog

## Resolved Questions

1. **Tester workflow**: The tester runs on the same Rancher Desktop, so factory reset wipes the tester's containers too. The contributor builds the image locally and copies the `uis` file to the tester directory.

2. **How long does a full cycle take?** TBD — will measure during testing.

3. **Data persistence**: For this test we wipe everything. Services like PostgreSQL start fresh. That's expected.

4. **`enabled-services.conf` already has nginx** as the only enabled service by default. The old system used nginx to verify that the system is started. No changes needed.

5. **`./uis` is the standard path.** Decided in PLAN-004/PLAN-005. The legacy `install-rancher.sh` is no longer used.
