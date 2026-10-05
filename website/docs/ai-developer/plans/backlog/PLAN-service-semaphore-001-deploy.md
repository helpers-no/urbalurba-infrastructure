# Plan: Deploy SemaphoreUI as a standard UIS service

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

**Goal**: `uis deploy semaphore` on a clean installation produces a reachable
[SemaphoreUI](https://semaphoreui.com) with one working admin login and zero
pre-configured projects, repositories or credentials — on Rancher Desktop today,
unchanged when later retargeted to a Proxmox LXC in production (see Investigation
Part 2).

**Investigation**: [INVESTIGATE-service-semaphore.md](./INVESTIGATE-service-semaphore.md)
— read this first. F1-F9 and Part 2/3 are the evidence this plan implements; this
file does not repeat the reasoning, only the resulting decisions.

**GitHub Issue**: urb-agents#1856

**Last Updated**: 2026-10-05

---

## Problem Summary

No file in this repository mentions Semaphore. A lab owner who wants the same
Ansible-runner capability the reference installation already uses daily has no
manifest, no playbook and no documented path to get it. This plan ships that
path: a manifest set + ansible playbook + service-wrapper metadata, following
the exact pattern already proven by `uptime-kuma` (also a single-pod,
SQLite-backed, no-official-Helm-chart service) and the admin-credential pattern
already proven by `grafana`/`argocd`/`uptime-kuma`.

**Decisions this plan makes that the Investigation left open** (Part 5, Q3-Q5):

| Open question | Decision | Why |
|---|---|---|
| Q3: admin password handling | UIS-generated via `urbalurba-secrets`, inheriting `${DEFAULT_ADMIN_PASSWORD}` | Matches `grafana-admin-password`/`uptime-kuma-admin-password` exactly — one platform credential to rotate, not one per service |
| Q4: manifest category/namespace | `SCRIPT_CATEGORY="MANAGEMENT"`, dedicated `semaphore` namespace | It is an operator tool (job runner + credential store), the same class as ArgoCD/pgAdmin, not a browser-automation tool (browserless/neko) |
| Q5: TLS/exposure default | Internal-only Traefik `IngressRoute`, no public case by default | Matches Dagster's UI and Uptime Kuma's default — an operator tool with no reason to be internet-facing on a lab install |

**Manifest numbering**: `630` — free in the `600-799` management range (checked:
`620`/`621` nextcloud, `622`/`623` onlyoffice, `641` pgadmin, `650-654` backstage,
`651`/`741`/`751` — `630-639` unused).

**Three internal secrets (F2) — mechanism decided, correcting the Investigation's
assumption of ansible-side generation**: the released binary (verified locally
against the exact reference version, v2.19.12) reads `cookie_hash`,
`cookie_encryption` and `access_key_encryption` from **environment variables**
(`SEMAPHORE_COOKIE_HASH`, `SEMAPHORE_COOKIE_ENCRYPTION`,
`SEMAPHORE_ACCESS_KEY_ENCRYPTION`) as well as from `config.json`, and starts
cleanly with all three absent from the file. This repo has no existing precedent
for ansible generating a fresh random secret per `uis deploy` run — every
comparable value (`DEFAULT_AUTHENTIK_SECRET_KEY`, `DEFAULT_OPENWEBUI_SECRET_KEY`)
is instead a **fixed, checked-in development default** that a production
operator is explicitly told to override in their own `.uis.secrets/` copy
(`provision-host/uis/templates/default-secrets.env` header: *"These are
DEVELOPMENT DEFAULTS for localhost testing only... For production, create your
own secrets in `.uis.secrets/`"*). This plan follows that existing convention
exactly rather than inventing a new one:

- `config.json` ships as a **static ConfigMap** holding only non-sensitive
  settings (`port`, `web_host`, `max_parallel_tasks`, `tmp_path`, `dialect`,
  the sqlite path) — no secret fields in it at all.
- The three secrets are injected as **pod env vars** (`SEMAPHORE_COOKIE_HASH`,
  `SEMAPHORE_COOKIE_ENCRYPTION`, `SEMAPHORE_ACCESS_KEY_ENCRYPTION`), each a
  `secretKeyRef` against `urbalurba-secrets`, exactly like every other
  UIS service's admin-password env var.
- `default-secrets.env` gets three new fixed dev-default values
  (`DEFAULT_SEMAPHORE_COOKIE_HASH` etc.), propagated through the same
  `copy_secrets_templates()` sed block in `first-run.sh` that already handles
  `DEFAULT_AUTHENTIK_SECRET_KEY`/`DEFAULT_OPENWEBUI_SECRET_KEY`. Production
  operators override them in their own `.uis.secrets/secrets-config/00-common-values.env.template`,
  the same way they are already told to for Authentik's and OpenWebUI's keys.

This is a smaller, more idiomatic change than templating `config.json` per
install, and it means the ansible playbook never has to generate or persist a
secret value itself.

---

## Phase 1: Secrets wiring

### Tasks

- [ ] 1.1 Add to `provision-host/uis/templates/default-secrets.env`:
  `DEFAULT_SEMAPHORE_COOKIE_HASH`, `DEFAULT_SEMAPHORE_COOKIE_ENCRYPTION`,
  `DEFAULT_SEMAPHORE_ACCESS_KEY_ENCRYPTION` — each a fixed base64-looking
  dev-default value (e.g. `openssl rand -base64 32` run once, by hand, to
  produce the literal string committed here — not generated at runtime),
  under a `# Semaphore` comment block mirroring the existing Authentik/OpenWebUI
  entries. Add a one-line comment stating these are dev-only and must be
  regenerated for production, matching the file's existing header warning.
- [ ] 1.2 Add the matching `sed` lines to `copy_secrets_templates()` in
  `provision-host/uis/lib/first-run.sh` (next to the existing
  `DEFAULT_AUTHENTIK_SECRET_KEY`/`DEFAULT_OPENWEBUI_SECRET_KEY` lines).
- [ ] 1.3 Add a `# Semaphore` section to
  `provision-host/uis/templates/secrets-templates/00-common-values.env.template`
  declaring the three `DEFAULT_SEMAPHORE_*` variables as operator-overridable,
  matching the existing Authentik/OpenWebUI sections' comment style.
- [ ] 1.4 Add a `SEMAPHORE ADMIN CREDENTIALS` block to
  `provision-host/uis/templates/secrets-templates/00-master-secrets.yml.template`'s
  `stringData:` section (the block starting around the `GRAFANA ADMIN
  CREDENTIALS`/`UPTIME KUMA ADMIN CREDENTIALS` entries):
  ```yaml
  semaphore-admin-user: "admin"
  semaphore-admin-password: "${DEFAULT_ADMIN_PASSWORD}"
  semaphore-cookie-hash: "${DEFAULT_SEMAPHORE_COOKIE_HASH}"
  semaphore-cookie-encryption: "${DEFAULT_SEMAPHORE_COOKIE_ENCRYPTION}"
  semaphore-access-key-encryption: "${DEFAULT_SEMAPHORE_ACCESS_KEY_ENCRYPTION}"
  ```

### Validation

```bash
uis secrets generate
grep -c "^semaphore-" .uis.secrets/generated/kubernetes/kubernetes-secrets.yml
```

Expect 5 matching keys, all with non-empty resolved values (no literal
`${DEFAULT_...}` left unsubstituted).

---

## Phase 2: Manifests

### Tasks

- [ ] 2.1 `manifests/630-semaphore-statefulset.yaml` — mirror
  `manifests/230-uptime-kuma-statefulset.yaml`'s structure exactly:
  - `Namespace: semaphore`
  - `ConfigMap` holding `config.json` (non-sensitive fields only, per the
    decision above) and `PersistentVolumeClaim` (`semaphore-data`, size TBD at
    implementation time — reference instance's DB is 51 MB after weeks of real
    use, F9; pick a PVC size with headroom, e.g. 2Gi)
  - `StatefulSet`, `replicas: 1`, pinned image tag (`semaphoreui/semaphore:v2.19.12`,
    matching the reference instance's version), `volumeMounts` at
    `/etc/semaphore` (config, from the ConfigMap) and `/var/lib/semaphore`
    (data, from the PVC), the three secret env vars from Phase 1,
    `dagsterWebserver`-style small resource requests/limits (F9: ~150 MiB RSS
    idle), readiness/liveness `httpGet` probes against Semaphore's root path
  - Plain `Service` (ClusterIP), port matching `config.json`'s `port`
- [ ] 2.2 `manifests/630-semaphore-ingressroute.yaml` — mirror
  `manifests/230-uptime-kuma-ingressroute.yaml`: Traefik `IngressRoute`,
  `entryPoints: [web]`, `HostRegexp(\`semaphore\..+\`)`, internal-only labels
  (per Q5's decision — no public-facing label).

### Validation

```bash
kubectl apply --dry-run=client -f manifests/630-semaphore-statefulset.yaml
kubectl apply --dry-run=client -f manifests/630-semaphore-ingressroute.yaml
```

Both apply cleanly with no schema errors.

---

## Phase 3: Ansible playbook

### Tasks

- [ ] 3.1 `ansible/playbooks/630-setup-semaphore.yml`, following
  `ansible/playbooks/230-setup-uptime-kuma.yml`'s proven shape:
  1. Create namespace
  2. `kubernetes.core.k8s` apply of the Phase 2 manifests
  3. Wait for the pod `Running` (`retries`/`delay`/`until`)
  4. Wait for HTTP to actually answer — throwaway `kubectl run curlimages/curl`
     against the Service, **not** just "pod Running" (uptime-kuma's proven
     pattern; a `Running` pod with a still-migrating SQLite DB is not yet
     serving)
  5. Verify the data volume is mounted (`kubectl exec ... test -d /var/lib/semaphore`)
  6. Read `semaphore-admin-user`/`semaphore-admin-password` from
     `urbalurba-secrets` (`no_log: true`); fail clearly if missing
  7. **Non-interactive admin bootstrap** — simpler than Uptime Kuma's raw-SQL
     hack, because Semaphore ships a CLI for exactly this (Investigation F4):
     ```bash
     kubectl exec <pod> -- semaphore users add --admin \
       --login admin --email "$ADMIN_EMAIL" --name Admin \
       --password "$ADMIN_PASSWORD" --config /etc/semaphore/config.json
     ```
     Idempotent handling: a redeploy against an existing PVC already has this
     user (Uptime Kuma's documented redeploy-reconciliation problem applies
     identically here — `uis undeploy` keeps the PVC). If `users add` fails
     because the login already exists, reconcile the password instead:
     ```bash
     semaphore users change-by-login --login admin --password "$ADMIN_PASSWORD" \
       --config /etc/semaphore/config.json
     ```
  8. **Verify the credential actually authenticates** — not just that the row
     exists (Uptime Kuma's standard, applied here too):
     ```bash
     curl -s -o /dev/null -w "%{http_code}" -X POST http://<svc>/api/auth/login \
       -H "Content-Type: application/json" \
       -d "{\"auth\":\"admin\",\"password\":\"$ADMIN_PASSWORD\"}"
     ```
     Expect `204` (Semaphore's documented success response for this endpoint).
     Fail the playbook clearly if not.
  9. Final report task with clear operator messaging — URL, admin login,
     explicit statement that zero projects/repositories are configured (F5) and
     that is intentional.
- [ ] 3.2 `ansible/playbooks/630-remove-semaphore.yml` — standard removal
  playbook (delete namespace/resources), mirroring
  `ansible/playbooks/230-remove-uptime-kuma.yml` if one exists, else the
  nearest equivalent `*-remove-*.yml`.

### Validation

```bash
ansible-playbook --syntax-check ansible/playbooks/630-setup-semaphore.yml
ansible-playbook --syntax-check ansible/playbooks/630-remove-semaphore.yml
shellcheck <any embedded script blocks, if extracted to files>
./uis deploy semaphore   # against a real Rancher Desktop cluster
curl -s http://semaphore.localhost/api/ping   # or equivalent health endpoint
./uis deploy semaphore   # second run — must stay idempotent, not fail on existing user
./uis undeploy semaphore && ./uis deploy semaphore   # PVC survives; login still works with same password
```

User confirms the UI is reachable, the admin login works, and no
project/repository/template exists on a clean install.

---

## Phase 4: Service-wrapper metadata

### Tasks

- [ ] 4.1 `provision-host/uis/services/management/service-semaphore.sh`,
  mirroring `service-argocd.sh`'s and `service-uptime-kuma.sh`'s shape:
  ```bash
  SCRIPT_ID="semaphore"
  SCRIPT_NAME="SemaphoreUI"
  SCRIPT_DESCRIPTION="Web UI and API for running Ansible, Terraform, OpenTofu and PowerShell"
  SCRIPT_CATEGORY="MANAGEMENT"
  SCRIPT_PLAYBOOK="630-setup-semaphore.yml"
  SCRIPT_MANIFEST=""
  SCRIPT_CHECK_COMMAND="kubectl get pods -n semaphore -l app=semaphore --no-headers 2>/dev/null | grep -q Running"
  SCRIPT_REMOVE_PLAYBOOK="630-remove-semaphore.yml"
  SCRIPT_REQUIRES=""
  SCRIPT_PRIORITY="85"
  SCRIPT_IMAGE="semaphoreui/semaphore:v2.19.12"
  SCRIPT_HELM_CHART=""
  SCRIPT_NAMESPACE="semaphore"
  SCRIPT_KIND="Component"
  SCRIPT_TYPE="tool"
  SCRIPT_OWNER="platform-team"
  SCRIPT_PROVIDES_APIS="semaphore-api"
  SCRIPT_CONSUMES_APIS=""
  SCRIPT_ABSTRACT="Web UI and API for running Ansible, Terraform, OpenTofu and PowerShell against your own hosts"
  SCRIPT_SUMMARY="<see Implementation Notes — must state F8's scope honestly and F6's plaintext-token fact; drafted in full during PLAN-002>"
  SCRIPT_LOGO="semaphore-logo.svg"
  SCRIPT_WEBSITE="https://semaphoreui.com"
  SCRIPT_TAGS="automation,ansible,terraform,opentofu,ci-cd,playbooks,ops"
  SCRIPT_DOCS="/docs/services/management/semaphore"
  ```
  `SCRIPT_SUMMARY` gets its final wording in PLAN-002 (the docs plan); a
  placeholder here is enough for `services.json` generation to succeed.
- [ ] 4.2 Regenerate `website/src/data/services.json`:
  ```bash
  provision-host/uis/manage/uis-docs.sh
  ```
  (Confirmed this session: this file is fully generated from `service-*.sh`
  files — do not hand-edit it.)
- [ ] 4.3 Add a placeholder `static/img/services/semaphore-logo.svg` if the
  docs build requires the referenced asset to exist (check against how
  `uptime-kuma-logo.svg` is handled — same directory, same requirement).

### Validation

```bash
cd website && npm run build
```

Must succeed with no broken-asset or broken-link errors (standing pre-push
gate for this repo).

---

## Acceptance Criteria

- [ ] `uis deploy semaphore` on a clean Rancher Desktop cluster produces a
  reachable UI with one working admin login
- [ ] Zero pre-configured projects, repositories, inventories or templates
  (F5) — confirmed by checking the relevant tables are empty, or simply that
  the UI's project list is empty on first login
- [ ] A second `./uis deploy semaphore` run is idempotent — no error, no
  duplicate user, same working login
- [ ] Login still works after `./uis undeploy semaphore && ./uis deploy semaphore`
  (PVC survives; password reconciliation path exercised)
- [ ] No real hostnames, IPs, project names or repository names from the
  reference instance appear anywhere in the manifests, playbook or
  service-wrapper file (grep check before opening the PR, same check already
  run clean on the Investigation doc)
- [ ] `npm run build` passes in `website/`
- [ ] `ansible-playbook --syntax-check` and `kubectl apply --dry-run=client`
  pass on every new file

## Implementation Notes

- **Image tag**: pin to `v2.19.12` (the exact reference-instance version,
  already verified byte-identical via Go BuildID this session) rather than
  `:latest`, matching this repo's general pinning discipline.
- **Why env vars for the three secrets, not a templated config.json**:
  verified locally this session — the real v2.19.12 binary accepts
  `SEMAPHORE_COOKIE_HASH`/`SEMAPHORE_COOKIE_ENCRYPTION`/`SEMAPHORE_ACCESS_KEY_ENCRYPTION`
  as environment variables (struct tags confirmed via `strings` on the
  binary), and starts cleanly with a config.json that omits all three. Env-var
  injection from a Secret is the same mechanism every other UIS service already
  uses for its admin password — no new templating logic needed in the playbook.
- **Do not** reproduce the reference instance's actual project, repository,
  inventory, template or host-naming data anywhere in this plan's output — the
  Investigation's F8/Appendix constraint applies identically here.
- **`vaults rekey`** exists upstream for rotating `access_key_encryption` after
  the fact — worth a one-line mention in the PLAN-002 docs page, not something
  this plan needs to automate.
- If `ansible/playbooks/230-remove-uptime-kuma.yml` turns out not to exist,
  use the nearest other service's `*-remove-*.yml` as the pattern instead —
  check before assuming.

## Files to Modify

- `provision-host/uis/templates/default-secrets.env`
- `provision-host/uis/lib/first-run.sh`
- `provision-host/uis/templates/secrets-templates/00-common-values.env.template`
- `provision-host/uis/templates/secrets-templates/00-master-secrets.yml.template`
- `manifests/630-semaphore-statefulset.yaml` (new)
- `manifests/630-semaphore-ingressroute.yaml` (new)
- `ansible/playbooks/630-setup-semaphore.yml` (new)
- `ansible/playbooks/630-remove-semaphore.yml` (new)
- `provision-host/uis/services/management/service-semaphore.sh` (new)
- `website/src/data/services.json` (auto-regenerated, not hand-edited)
- `static/img/services/semaphore-logo.svg` (new, if required)
