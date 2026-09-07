# Plan: Gravitee APIM 4.11 deployment on PostgreSQL

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed

**Goal**: After this plan, `./uis deploy postgresql && ./uis deploy gravitee` on a fresh local cluster produces a working Gravitee APIM 4.11 deployment with admin Console, Developer Portal, and API Gateway, backed by PostgreSQL — no MongoDB, no Elasticsearch, no Redis. `./uis undeploy gravitee --purge` cleanly tears down all Gravitee state.

**Last Updated**: 2026-05-06

**Completed**: 2026-05-06 — Gravitee close-out shipped to `origin/main` over the gravitee work-stream commits ending at `de872dd` (E2E smoke-test docs). PLAN-001 (org name) and PLAN-002 (portal entrypoint) follow-ups in `plans/completed/` covered the remaining post-deploy config work. All four URLs (Console, Portal, Gateway, Management API) verified live; CI green; rebuilt `uis-provision-host:latest` published.

**Investigation**: [INVESTIGATE-gravitee-fix.md](./INVESTIGATE-gravitee-fix.md) — 17 decisions resolved, 12 open checks (all empirical, handled during implementation).

**Strategy**: Ships as **two PRs**:

- **PR-A** (this plan, Phases 1–4) — "Make it work." Single PR; Phases 1–4 are inseparable because Phase 4 validates the others.
- **PR-B** (Phase 5) — "Clean up MongoDB residue." Separate PR, gated on PR-A merged + verified on a fresh cluster. Removes dead code from the MongoDB-side bootstrap and the transition-stub keys.

**Prerequisites**:
- The investigation document is complete; no design questions remain that would affect plan structure.
- The platform's PostgreSQL service (manifest 042) is already deployed and working — Gravitee is a consumer, not a provisioner.

**Blocks**:
- A future PLAN to enable Elasticsearch-backed analytics if the analytics tab becomes a real requirement.
- A future PLAN to add Redis if rate-limit/caching policies become a real requirement.
- A future PLAN to add Authentik forward-auth in front of Gravitee.

---

## Pre-conditions — what already landed during the investigation

Phase 1 of this plan is **partially complete in the working tree** at the time of writing. The following changes are already in place; the implementation should NOT redo them:

- `provision-host/uis/templates/secrets-templates/00-common-values.env.template` — `GRAVITEE_POSTGRES_USER`, `GRAVITEE_POSTGRES_PASSWORD`, `GRAVITEE_POSTGRES_DATABASE` first-class variables added under a new "OPTIONAL - GRAVITEE APIM" section.
- `provision-host/uis/templates/secrets-templates/00-master-secrets.yml.template`:
  - New `gravitee/urbalurba-secrets` block with `GRAVITEE_POSTGRES_HOST/PORT/USER/PASSWORD/DATABASE/JDBC_URL`, `GRAVITEE_ADMIN_EMAIL`, `GRAVITEE_ADMIN_PASSWORD`, `GRAVITEE_ENCRYPTION_KEY`.
  - Old `GRAVITEE.IO API MANAGEMENT SYSTEM` block removed from the `default` namespace.
  - Three `GRAVITEE_MONGODB_DATABASE_*` keys retained as **transition stubs** (with deprecation comment) in the MongoDB section, because `040-setup-mongodb.yml` still validates their presence on `./uis deploy mongodb`. These are removed in PR-B / Phase 5.
- `website/docs/services/integration/gravitee.md` — service doc rewritten around the new architecture, with an "Implementation in Progress" banner and the "What we lose by skipping ES and Redis" subsection.

The implementation starts from this state.

---

# PR-A — Phases 1–4: Make it work

Single PR, single feature branch. Merging unblocks the user-facing `./uis deploy gravitee` flow.

## Phase 1: Service metadata

Finishes the work the investigation started. Service-script rewrite + a regen + a dry-run-apply of the secrets block.

### Tasks

- [ ] 1.1 Rewrite `provision-host/uis/services/integration/service-gravitee.sh` per the target shape in [INVESTIGATE-gravitee-fix.md § Recommended Target Shape § Service metadata](./INVESTIGATE-gravitee-fix.md#recommended-target-shape). Pin `SCRIPT_IMAGE="graviteeio/apim:4.11.3"`.
- [ ] 1.2 Add `SCRIPT_LOGO="gravitee-logo.svg"` and source the SVG from Gravitee's official brand assets into `website/static/img/services/gravitee-logo.svg`. Strip embedded CSS / scripts; ensure ~24×24 viewBox so it renders cleanly in the services table.
- [ ] 1.3 Regenerate `services.json` and the per-service docs that depend on it:
  ```bash
  ./uis-docs.sh
  ```
  Service doc page `gravitee.md` already exists with the target content; the generator skips it (skip-if-exists). Verify the metadata table in `gravitee.md` reflects the new `SCRIPT_*` values — if it doesn't, that's because the page was hand-edited; manually update only the metadata table.
- [ ] 1.4 Dry-run-apply the secrets:
  ```bash
  ./uis secrets generate
  kubectl apply --dry-run=client -f .uis.secrets/generated/kubernetes/kubernetes-secrets.yml
  ```
  Expect: clean parse, gravitee namespace + secret render correctly, all `GRAVITEE_POSTGRES_*` keys populate from the env template.

### Validation

```bash
# Service registers correctly
./uis list | grep gravitee
# Expect: namespace `gravitee`, dependencies `postgresql`, REMOVE playbook present.

jq '.services[] | select(.id == "gravitee")' website/src/data/services.json
# Expect: namespace=gravitee, requires=["postgresql"], image=graviteeio/apim:4.11.3
```

User confirms the service entry is sane before moving on.

---

## Phase 2: Helm values + IngressRoutes

Builds the deployable configuration. No deploy yet — this phase produces files that Phase 3's playbook will apply.

### Tasks

- [ ] 2.1 **Verify chart resource names** before writing the IngressRoute manifest (Open Check #1):
  ```bash
  helm repo add graviteeio https://helm.gravitee.io 2>/dev/null
  helm repo update graviteeio
  helm template gravitee-apim graviteeio/apim --version 4.11.3 \
      --namespace gravitee \
      --set mongodb-replicaset.enabled=false \
      --set elasticsearch.enabled=false \
      --set ratelimit.type=none \
      --set analytics.enabled=false \
      --set api.ingress.management.enabled=false \
      --set api.ingress.portal.enabled=false \
      --set gateway.ingress.enabled=false \
      --set ui.ingress.enabled=false \
      --set portal.ingress.enabled=false \
      | grep -E '^(kind: Service|  name:|  namespace:|    port:|    targetPort:)' | head -60
  ```
  Capture the four Service names and their HTTP ports. Use these as the source of truth for both 2.2 (IngressRoute) and 2.3 (`SCRIPT_CHECK_COMMAND`'s instance label).

- [ ] 2.2 Rewrite `manifests/091-gravitee-ingress.yaml` per the target shape in [INVESTIGATE-gravitee-fix.md § Recommended Target Shape § IngressRoute](./INVESTIGATE-gravitee-fix.md#recommended-target-shape). Substitute the actual service names and ports from 2.1.

- [ ] 2.3 Update `service-gravitee.sh` `SCRIPT_CHECK_COMMAND` if 2.1 reveals the instance label is different from the placeholder `app.kubernetes.io/instance=gravitee-apim`.

- [ ] 2.4 Rewrite `manifests/090-gravitee-config.yaml` per the target shape in [INVESTIGATE-gravitee-fix.md § Recommended Target Shape § Helm values](./INVESTIGATE-gravitee-fix.md#recommended-target-shape). Specifically:
  - Disable bundled subcharts (`mongodb-replicaset.enabled: false`, `elasticsearch.enabled: false`, `es.enabled: false`).
  - `management.type: jdbc`, with JDBC URL/username/password.
  - `ratelimit.type: none`, `analytics.enabled: false`.
  - Disable chart-managed ingress on `api`, `gateway`, `ui`, `portal`.
  - Per-component `resources.requests` and `resources.limits` per the laptop-tuned table in the investigation.
  - **Critical** (Decision #16): set `ui.env.MANAGEMENT_URL` and `portal.env.PORTAL_API_URL` (or the actual chart key per Open Check #3) to the external Management API hostname `http://gravitee-api.localhost`.
  - **Critical** (Decision #17): set `api.cors.allowOrigin: "*"` (or actual chart key per Open Check #4).

- [ ] 2.5 Resolve Open Check #2 — try `secret://kubernetes/urbalurba-secrets:KEY` for `management.jdbc.url/username/password`. If pod logs in Phase 4 show `unable to resolve secret reference`, switch to the `extraEnvs` fallback shown in the investigation (apply on **both** `api` and `gateway` blocks).

### Validation

```bash
kubectl apply --dry-run=client -f manifests/091-gravitee-ingress.yaml
# Expect: 4 IngressRoutes, no schema errors.

# Helm values render check (still no deploy)
helm template gravitee-apim graviteeio/apim --version 4.11.3 \
    --namespace gravitee \
    -f manifests/090-gravitee-config.yaml \
    | head -40
# Expect: no chart-managed Ingress objects in output, JDBC env vars present on api+gateway.
```

User confirms the rendered values match the intent before moving to Phase 3.

---

## Phase 3: Setup and remove playbooks

### Tasks

- [ ] 3.1 Rewrite `ansible/playbooks/090-setup-gravitee.yml` from scratch around the standard UIS playbook pattern. Steps (per investigation):
  1. Display deployment context (namespace, chart version, target Postgres host).
  2. Ensure namespace `gravitee` exists.
  3. Verify `gravitee/urbalurba-secrets` carries the required `GRAVITEE_POSTGRES_*` and admin keys. Fail with a clear message if missing.
  4. **Bootstrap database**: idempotently create `graviteedb` and `gravitee_user` against `postgresql.default.svc.cluster.local` using the Postgres admin password from `default/postgresql` secret. Mirror the existing pattern used by Backstage / OpenWebUI / OpenMetadata for Postgres-backed apps. All secret-handling tasks set `no_log: true`.
  5. Ensure the `graviteeio` Helm repo is registered and up to date.
  6. Install/upgrade `graviteeio/apim` at `4.11.3` with values from `manifests/090-gravitee-config.yaml` using `kubernetes.core.helm`.
  7. Apply `manifests/091-gravitee-ingress.yaml` with `kubernetes.core.k8s`.
  8. Wait for all four Deployments (`gravitee-apim-api`, `gravitee-apim-gateway`, `gravitee-apim-ui`, `gravitee-apim-portal`) to reach Available — use the chart's actual deployment names from Phase 2.1.
  9. Health-probe internal endpoints from inside the cluster:
     - `curl -fsS http://gravitee-apim-api.gravitee.svc.cluster.local:83/management/health`
     - `curl -fsS http://gravitee-apim-gateway.gravitee.svc.cluster.local:82/_node/health`
     - (Verify exact paths/ports against Open Check #5 results.)
  10. Print concise access URLs (`http://gravitee.localhost`, `gravitee-api.localhost`, `gravitee-gw.localhost`, `gravitee-portal.localhost`) and a one-line admin login hint sourcing email/password from the secret.

- [ ] 3.2 Create `ansible/playbooks/090-remove-gravitee.yml`:
  - Default mode: uninstall the `gravitee-apim` Helm release; remove the four IngressRoute objects from namespace `gravitee`. Keep PVCs, secret, namespace.
  - **`--purge` mode** (Decision #2: aggressive purge): also drop `graviteedb` + `gravitee_user` on PostgreSQL, delete `gravitee/urbalurba-secrets`, delete all PVCs in the `gravitee` namespace, delete the namespace itself. Trigger via Ansible extra-var `gravitee_purge=true`. The setup playbook should be wired so `./uis undeploy gravitee --purge` passes the flag.
  - **Confirmation prompt**: when `gravitee_purge=true` and stdin is a TTY, prompt "About to drop the gravitee database, role, secret, namespace, and all PVCs. Type 'yes' to continue:". Skip the prompt when `gravitee_purge_yes=true` is also set (for automation / CI).
  - All destructive tasks `no_log: true`.

- [ ] 3.3 Verify `./uis undeploy gravitee --purge` plumbs through to `gravitee_purge=true`. If the existing `service-deployment.sh` doesn't already pass `--purge`-style flags, update it minimally — same plumbing PostgREST uses for `--app`/`--url-prefix`.

### Validation

```bash
# Lint
ansible-playbook --syntax-check ansible/playbooks/090-setup-gravitee.yml
ansible-playbook --syntax-check ansible/playbooks/090-remove-gravitee.yml

# Dry-run setup (will fail at the actual helm install — that's fine, we want
# to see steps 1-3 succeed and the bootstrap SQL render correctly)
ANSIBLE_VAULT_PASSWORD_FILE=... \
    ansible-playbook ansible/playbooks/090-setup-gravitee.yml --check
```

User confirms playbook structure follows UIS conventions before Phase 4.

---

## Phase 4: End-to-end validation — the PR-A merge gate

This is the gate. PR-A does not merge until everything in this phase passes on a freshly-reset cluster.

### Tasks

- [ ] 4.1 Reset the local cluster to a known clean state (Rancher Desktop "Reset Kubernetes" or equivalent). Confirm no `gravitee*` namespace, no `gravitee*` pods, no MongoDB-Gravitee residue.

- [ ] 4.2 Bring up dependencies:
  ```bash
  ./uis secrets generate
  ./uis secrets apply
  ./uis deploy postgresql
  ```
  Confirm `postgresql-0` Ready, `default/urbalurba-secrets` carries the new `gravitee/...` block (rendered, not in default), and `gravitee/urbalurba-secrets` carries `GRAVITEE_POSTGRES_*`.

- [ ] 4.3 Deploy:
  ```bash
  ./uis deploy gravitee
  ```
  Expected: setup playbook completes; all four Deployments reach Available within a reasonable time (Helm chart timeout: 10 minutes).

- [ ] 4.4 **Resolve Open Checks during the live deploy**:
  - **#3 (SPA URL config)**: load `http://gravitee.localhost`. If the Console SPA can fetch its constants and reach `http://gravitee-api.localhost/management/...`, the `ui.env.MANAGEMENT_URL` setting is correct. Otherwise, browser DevTools will show a 404 / CORS error pointing at the wrong URL — adjust `ui.env.*` and re-deploy.
  - **#4 (CORS)**: same load attempt — CORS errors in DevTools mean the API server isn't allowing the Console origin. Adjust `api.cors.*`.
  - **#5 (health endpoint paths)**: confirm the Step 9 curl in `090-setup-gravitee.yml` actually returns 200, not 404.
  - **#6 (Liquibase migration ownership)**: inspect both `gravitee-apim-api` and `gravitee-apim-gateway` startup logs side-by-side. Expectation: only one runs Liquibase. If both attempt migrations, document the lock-conflict behavior and decide whether to delay gateway start.
  - **#7 (rate-limit-with-none-store UX)**: in the Console, try to apply a rate-limit policy to a sample API. Document what happens (UI disables the option / accepts but warns / silent no-op). Add the result to `gravitee.md` Troubleshooting if it's surprising.
  - **#9 (PVCs)**: list PVCs in the `gravitee` namespace. Decide which `--purge` should remove (recommend: all of them, given Decision #2 chose aggressive purge).

- [ ] 4.5 Verify all four URLs resolve from the host:
  ```bash
  curl -fsS http://gravitee.localhost/                            # Console SPA root
  curl -fsS http://gravitee-api.localhost/management/health       # 200 OK
  curl -fsS http://gravitee-gw.localhost/_node/health             # 200 OK
  curl -fsS http://gravitee-portal.localhost/                     # Portal SPA root
  ```

- [ ] 4.6 Log into the Console at `http://gravitee.localhost` with `${DEFAULT_ADMIN_EMAIL}` / `${DEFAULT_ADMIN_PASSWORD}`. Create a sample API. Deploy it. Hit it via the Gateway. (This verifies the full management → gateway → request-proxy flow against real PostgreSQL state. Manual; not part of the automated smoke test, which stays health-only per Decision #4.)

- [ ] 4.7 Verify PostgreSQL state from outside Gravitee:
  ```bash
  PGPW=$(kubectl get secret postgresql -n default -o jsonpath='{.data.postgres-password}' | base64 -d)
  kubectl exec -n default postgresql-0 -- bash -c \
      "PGPASSWORD='$PGPW' psql -U postgres -At -c '\l graviteedb'"
  kubectl exec -n default postgresql-0 -- bash -c \
      "PGPASSWORD='$PGPW' psql -U postgres -d graviteedb -At -c '\dn api_v1; \dt' | head"
  ```
  Expect: `graviteedb` exists, owned by `gravitee_user`. The Liquibase-managed schema has tables (count > 0).

- [ ] 4.8 Idempotency: re-run `./uis deploy gravitee` against the running cluster. Expect: `helm upgrade` no-op (or near no-op), no schema changes, all four Deployments stay Available.

- [ ] 4.9 Lifecycle test:
  ```bash
  ./uis undeploy gravitee
  ```
  Expect: Helm release removed, four IngressRoutes gone, namespace + PVCs + secret + database all preserved.
  ```bash
  ./uis deploy gravitee
  ```
  Expect: re-deploy succeeds with no re-bootstrap required (database + roles already exist; secret already exists; chart re-installs cleanly).

- [ ] 4.10 Purge test (manual, last):
  ```bash
  echo "yes" | ./uis undeploy gravitee --purge
  ```
  Expect: confirmation prompt appears; on `yes`, the database, role, secret, all PVCs, and the namespace are gone. Followed by a clean redeploy:
  ```bash
  ./uis deploy gravitee
  ```
  Expect: full bootstrap rerun, Liquibase recreates schema, all four pods reach Ready.

- [ ] 4.11 Update Open Check answers in [INVESTIGATE-gravitee-fix.md](./INVESTIGATE-gravitee-fix.md) — replace each open check with the resolved answer. The investigation file moves from `backlog/` to `completed/` after PR-B merges.

### Validation

The Phase 4 task list IS the validation. PR-A merges only when all 11 boxes are checked and the results captured in the PR description.

---

## PR-A acceptance criteria

- [ ] `./uis list` shows Gravitee in namespace `gravitee` with `SCRIPT_REQUIRES="postgresql"` and a populated `SCRIPT_REMOVE_PLAYBOOK`.
- [ ] `./uis deploy gravitee` deploys APIM 4.11.3 with all four Deployments reaching Available. Gravitee itself does not deploy or depend on MongoDB / Elasticsearch / Redis — none appear in the `gravitee` namespace, and no Gravitee pod holds connections to those services. (UIS may run those services for other consumers; this criterion is about Gravitee's dependencies.)
- [ ] PostgreSQL contains a `graviteedb` database owned by `gravitee_user`, with a non-empty Liquibase-managed schema.
- [ ] No tracked manifest contains a literal Gravitee password, JDBC URL with credentials, or admin password.
- [ ] All four URLs (`http://gravitee.localhost`, `gravitee-api.localhost`, `gravitee-gw.localhost`, `gravitee-portal.localhost`) return 200.
- [ ] Admin login + create-API + proxy-request flow works once end-to-end (manual test, captured in PR description).
- [ ] `./uis undeploy gravitee` removes Helm release and IngressRoutes; PVCs, secret, namespace, database preserved. `./uis deploy gravitee` afterward succeeds without re-bootstrap.
- [ ] `./uis undeploy gravitee --purge` prompts for confirmation, then drops database + role + secret + PVCs + namespace. `./uis deploy gravitee` afterward succeeds with a full bootstrap from scratch.
- [ ] Open Checks #1, #3, #4, #5, #6, #7, #9 from the investigation are resolved with concrete answers captured in the PR description.

---

# PR-B — Phase 5: MongoDB-residue cleanup

Separate PR. Gates on PR-A merged + verified on at least one fresh cluster bringup. Mechanical cleanup, no behavior change for Gravitee.

## Phase 5: dead-code removal

### Tasks

- [ ] 5.1 Remove the Gravitee-specific blocks from `manifests/040-mongodb-config.yaml` — the init container that creates the `gravitee_user` and `graviteedb` MongoDB user/database (lines ~63 onward). Verify nothing else in the manifest references those env keys.
- [ ] 5.2 Remove the Gravitee-specific blocks from `ansible/playbooks/040-setup-mongodb.yml` — the validation loop assertion (line ~52) and the verification task (lines ~165–167). The remaining MongoDB setup must still work for any OTHER consumer; a green `./uis deploy mongodb` after this change is the validation.
- [ ] 5.3 Remove the three transition-stub keys from `provision-host/uis/templates/secrets-templates/00-master-secrets.yml.template` (`GRAVITEE_MONGODB_DATABASE_NAME/USER/PASSWORD`) and the multi-line deprecation comment block above them.
- [ ] 5.4 Update `troubleshooting/debug-mongodb.sh` — remove the three `GRAVITEE_MONGODB_DATABASE_*` lookups (lines ~59–61). Replace with a one-line comment noting Gravitee no longer uses MongoDB.
- [ ] 5.5 Grep the entire repo for `GRAVITEE_MONGODB` — target zero matches. If any remain, decide case-by-case (delete or update).
- [ ] 5.6 Add `ansible/playbooks/090-test-gravitee.yml` covering: pods Ready, four IngressRoutes resolve, Management API health 200, Gateway `/_node/health` 200, Console root 200, Portal root 200. Health-only per Decision #4.
- [ ] 5.7 Register Gravitee in the `./uis test-all` flow.
- [ ] 5.8 Update the integration-testing docs to remove the "Gravitee always skipped" callout.
- [ ] 5.9 Move `INVESTIGATE-gravitee-fix.md` from `plans/backlog/` to `plans/completed/`. Mark this plan completed and move it from `plans/active/` to `plans/completed/`.

### Validation

```bash
# MongoDB still works for non-Gravitee consumers
./uis undeploy mongodb
./uis deploy mongodb
# Expect: green; no Gravitee-related validation errors.

# Zero Gravitee-MongoDB references in tracked files
grep -r "GRAVITEE_MONGODB" \
    provision-host ansible manifests troubleshooting \
    website/docs/services website/src/data 2>/dev/null
# Expect: no output.

# Test playbook works
./uis verify gravitee
./uis test-all
# Expect: gravitee included, all checks pass.
```

---

## PR-B acceptance criteria

- [ ] `grep -r GRAVITEE_MONGODB` across tracked files returns zero matches.
- [ ] `./uis deploy mongodb` succeeds on a fresh cluster (no Gravitee bootstrap, since Gravitee no longer uses MongoDB).
- [ ] `./uis verify gravitee` passes against a running deployment from PR-A.
- [ ] `./uis test-all` includes Gravitee and reports green.
- [ ] Investigation document moved to `completed/`. Plan document moved to `completed/`.

---

## Validation Commands (post-merge, both PRs)

```bash
# Full bringup chain on a fresh cluster
./uis secrets generate
./uis secrets apply
./uis deploy postgresql
./uis deploy gravitee

# Health checks
curl -fsS http://gravitee.localhost/
curl -fsS http://gravitee-api.localhost/management/health
curl -fsS http://gravitee-gw.localhost/_node/health
curl -fsS http://gravitee-portal.localhost/

# Database side
PGPW=$(kubectl get secret postgresql -n default -o jsonpath='{.data.postgres-password}' | base64 -d)
kubectl exec -n default postgresql-0 -- bash -c \
    "PGPASSWORD='$PGPW' psql -U postgres -At -c '\l graviteedb'"

# Cluster side
kubectl get pods -n gravitee
kubectl get ingressroute -n gravitee
kubectl get secret urbalurba-secrets -n gravitee -o jsonpath='{.data}' | jq 'keys'

# Lifecycle
./uis undeploy gravitee
./uis deploy gravitee
echo "yes" | ./uis undeploy gravitee --purge
./uis deploy gravitee

# Automated test
./uis verify gravitee
./uis test-all
```

---

## Files Modified

### PR-A (Phases 1–4)

| File | Change |
|------|--------|
| `provision-host/uis/services/integration/service-gravitee.sh` | Replaced. New SCRIPT_* values per investigation target shape. |
| `manifests/090-gravitee-config.yaml` | Replaced. Helm values for APIM 4.11.3, JDBC backend, no ES/Redis, chart ingress disabled, laptop-tuned resources, SPA URL config, CORS. |
| `manifests/091-gravitee-ingress.yaml` | Replaced. Four `HostRegexp` IngressRoutes in `gravitee` namespace. |
| `ansible/playbooks/090-setup-gravitee.yml` | Replaced. Standard UIS playbook pattern, ~150–200 lines (down from 465). |
| `ansible/playbooks/090-remove-gravitee.yml` | Created. Default + `--purge` modes with confirmation prompt. |
| `provision-host/uis/lib/service-deployment.sh` | Possibly minor change in 3.3 to wire `--purge` through to the remove playbook. |
| `website/static/img/services/gravitee-logo.svg` | Added. Sourced from Gravitee's brand assets. |
| `website/src/data/services.json` | Regenerated by `./uis-docs.sh`. |

### PR-B (Phase 5)

| File | Change |
|------|--------|
| `manifests/040-mongodb-config.yaml` | Removed Gravitee-specific MongoDB user/database init. |
| `ansible/playbooks/040-setup-mongodb.yml` | Removed Gravitee secret-key validation and verification task. |
| `provision-host/uis/templates/secrets-templates/00-master-secrets.yml.template` | Removed three `GRAVITEE_MONGODB_DATABASE_*` transition-stub keys + deprecation comment. |
| `troubleshooting/debug-mongodb.sh` | Removed Gravitee MongoDB lookups. |
| `ansible/playbooks/090-test-gravitee.yml` | Created. Health-only smoke checks. |
| `website/docs/ai-developer/plans/backlog/INVESTIGATE-gravitee-fix.md` | Moved to `completed/`. |
| `website/docs/ai-developer/plans/active/PLAN-gravitee-postgresql-deployment.md` | Moved to `completed/`. |
| Integration testing docs (TBD path) | Removed "Gravitee always skipped" callout. |

---

## Out of Scope (explicitly)

- **No Authentik forward-auth.** Gravitee runs with its own admin login for v1. SSO is a future plan.
- **No Elasticsearch.** Analytics tab in Console stays empty by design. Switch on later if needed.
- **No Redis.** Rate-limit and response-cache policies don't enforce. Switch on later if needed.
- **No collision detection for old MongoDB-Gravitee state.** This plan assumes a fresh local cluster. Contributors with old state on their cluster manually clean it up before deploying.
- **No production hardening for `GRAVITEE_ENCRYPTION_KEY`.** Default value derived from `${DEFAULT_ADMIN_PASSWORD}`; replace with a securely-generated random key when deploying outside dev.
- **No functional smoke test (create-API + proxy)** in `090-test-gravitee.yml`. Health-only per Decision #4. A functional test is its own future plan once a fixture API definition is designed.
- **No image-registry mirror.** Pulls direct from Docker Hub. CI rate-limit concerns are deferred.

---

## Open follow-ups (track but don't block)

| Item | Owner | When |
|------|-------|------|
| Functional smoke test (create + proxy) | TBD | Once a fixture API definition exists |
| Authentik forward-auth integration | TBD | After Gravitee's own login flow is verified working |
| Switch on Elasticsearch for analytics | TBD | When analytics dashboards become a real ask |
| Switch on Redis for rate-limit policies | TBD | When rate-limiting becomes a real ask |
| Production-grade `GRAVITEE_ENCRYPTION_KEY` rotation strategy | TBD | First non-dev deploy target |
| Chart 4.12 bump | TBD | After 4.12 stable lands (~June 2026) |
