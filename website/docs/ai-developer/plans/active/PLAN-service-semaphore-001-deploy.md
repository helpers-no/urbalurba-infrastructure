# Plan: Deploy SemaphoreUI as a standard UIS service

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Active — Phases 1-4 implemented and locally verified; not yet deployed to a real cluster (see Implementation Notes)

**Goal**: `uis deploy semaphore` on a clean installation produces a reachable
[SemaphoreUI](https://semaphoreui.com) with one working admin login and zero
pre-configured projects, repositories or credentials — on Rancher Desktop today,
unchanged when later retargeted to a Proxmox LXC in production (see Investigation
Part 2).

**Investigation**: [INVESTIGATE-service-semaphore.md](../backlog/INVESTIGATE-service-semaphore.md)
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

- [x] 1.1 Added to `provision-host/uis/templates/default-secrets.env`:
  `DEFAULT_SEMAPHORE_COOKIE_HASH`, `DEFAULT_SEMAPHORE_COOKIE_ENCRYPTION`,
  `DEFAULT_SEMAPHORE_ACCESS_KEY_ENCRYPTION`, each a real `openssl rand -base64 32`
  value generated once and committed literally, under a comment block stating
  they are dev-only and must be regenerated for production. ✓
- [x] 1.2 Added the matching `sed` lines to `copy_secrets_templates()` in
  `provision-host/uis/lib/first-run.sh`. Used `|` as the sed delimiter (not `/`)
  because these base64 values legitimately contain `/` — verified this against
  the real substitution, not assumed. ✓
- [x] 1.3 Added a `# Semaphore` section to
  `provision-host/uis/templates/secrets-templates/00-common-values.env.template`. ✓
- [x] 1.4 Added a `SEMAPHORE NAMESPACE SECRETS` block to
  `provision-host/uis/templates/secrets-templates/00-master-secrets.yml.template`
  — one real deviation from the sketch below: this repo's pattern is a
  **per-namespace** `urbalurba-secrets` copy (confirmed by reading the argocd/
  jupyterhub/backstage/browser blocks), so this added its own `kind: Namespace`
  + `kind: Secret` pair for the `semaphore` namespace, not a few keys merged
  into an existing block. Also added `semaphore-admin-email` (inheriting
  `${DEFAULT_ADMIN_EMAIL}`) beyond what was sketched here, because
  `semaphore users add --admin` requires a real email argument and no other
  secret key here was a valid source for one.
  ```yaml
  semaphore-admin-user: "admin"
  semaphore-admin-email: "${DEFAULT_ADMIN_EMAIL}"
  semaphore-admin-password: "${DEFAULT_ADMIN_PASSWORD}"
  semaphore-cookie-hash: "${DEFAULT_SEMAPHORE_COOKIE_HASH}"
  semaphore-cookie-encryption: "${DEFAULT_SEMAPHORE_COOKIE_ENCRYPTION}"
  semaphore-access-key-encryption: "${DEFAULT_SEMAPHORE_ACCESS_KEY_ENCRYPTION}"
  ```

### Validation — done, against an isolated scratch `SECRETS_DIR`/`TEMPLATES_DIR`

```bash
uis secrets generate
grep -c "^semaphore-" .uis.secrets/generated/kubernetes/kubernetes-secrets.yml
```

Ran the real `copy_secrets_templates`/`generate_kubernetes_secrets` functions
(sourced directly, pointed at a throwaway directory — Docker is not available
on this machine so the `./uis` CLI wrapper itself cannot run here) and parsed
the output with PyYAML: all 6 keys resolved with real values, no leftover
`${DEFAULT_...}` placeholders, and both the `Namespace: semaphore` and
`Secret: urbalurba-secrets (ns=semaphore)` documents are present.

---

## Phase 2: Manifests

### Tasks

- [x] 2.1 `manifests/630-semaphore-statefulset.yaml` — ConfigMap + PVC
  (`semaphore-data`, 2Gi) + StatefulSet + Service, mirroring
  `230-uptime-kuma-statefulset.yaml`. Two things verified against the real
  upstream source rather than assumed, both load-bearing:
  - **`config.json`'s `"port"` field is a Go `net.Listen` address, not a bare
    number** — it must keep the leading colon (`":3000"`). Verified by running
    this exact config against the real v2.19.12 binary.
  - **The pod needs `securityContext.fsGroup: 0`.** Pulled the real
    `semaphoreui/semaphore` Dockerfile and `server-wrapper` script from
    `raw.githubusercontent.com` and confirmed: the image runs as uid 1001,
    group 0 (`adduser -D -u 1001 -G root semaphore`), and
    `/var/lib/semaphore` is `chown`'d to that group with no group-write
    `chmod`. A freshly provisioned PVC mounts owned by root with no group
    access, so without `fsGroup: 0` the container cannot create
    `database.sqlite`. This would have been a real, silent first-deploy
    failure if shipped without checking the actual image.
  - The wrapper script also confirmed `/etc/semaphore` and `/var/lib/semaphore`
    are exactly the image's built-in mount points, and that a *present*
    `config.json` skips the interactive-setup-wizard code path entirely — the
    ConfigMap approach is correct, not just plausible.
  - Readiness/liveness probes use `/api/ping` (verified to return `pong`/200
    against the real binary), not `/` — the sketch below guessed `/`.
- [x] 2.2 `manifests/630-semaphore-ingressroute.yaml` — Traefik `IngressRoute`,
  internal-only. Deviated from the sketch below after re-checking Dagster's
  actual IngressRoute: Dagster uses no `type`/`routing`/`protection` labels at
  all, just `app:` plus an `annotations.urbalurba.io/description` stating
  internal-only — that is the pattern this mirrors, not Uptime Kuma's older
  `protection: public` labels (which would have been the wrong signal here).

### Validation

YAML structure verified by parsing both files with PyYAML (4 documents:
ConfigMap, PVC, StatefulSet, Service — plus the IngressRoute). `kubectl` is
not installed on this machine (no cluster access here), so
`kubectl apply --dry-run=client` itself could not be run — this is a gap, not
a pass; a server-side check against a real cluster is still needed before
calling this fully verified.

---

## Phase 3: Ansible playbook

### Tasks

- [x] 3.1 `ansible/playbooks/630-setup-semaphore.yml`, following
  `230-setup-uptime-kuma.yml`'s shape (namespace → apply manifests → wait for
  Running → wait for real HTTP 200 on `/api/ping` → verify volume mounted →
  read secret, fail clearly if missing → bootstrap/reconcile admin → verify
  login → final report). One real deviation from the sketch below, found by
  actually running the admin-bootstrap commands against the real binary
  (downloaded the pinned v2.19.12 release locally and exercised each step):
  **`semaphore users add --admin` on a login that already exists does not
  exit non-zero cleanly — it panics with a raw Go stack trace (`UNIQUE
  constraint failed: user.email`, rc=2).** The sketch's "if add fails,
  reconcile instead" plan would have meant parsing a panic trace to detect
  that case. Used `semaphore users get --login <user>` first instead (rc=0 if
  it exists, rc=1 if not — also verified directly) and branch cleanly on that,
  so `add` is only ever called on a login confirmed not to exist yet.
  Also verified directly: `users change-by-login` correctly updates the
  password and the new password authenticates immediately (HTTP 204 from
  `/api/auth/login`); the admin-bootstrap and reconcile commands in the
  playbook are exactly the commands exercised, not merely plausible ones.
- [x] 3.2 `ansible/playbooks/630-remove-semaphore.yml` — standard removal
  playbook, mirroring `230-remove-uptime-kuma.yml` (which does exist). Also
  removes the ConfigMap, which uptime-kuma's equivalent doesn't have.

### Validation

```bash
ansible-playbook --syntax-check ansible/playbooks/630-setup-semaphore.yml   # passed
ansible-playbook --syntax-check ansible/playbooks/630-remove-semaphore.yml  # passed
shellcheck <embedded shell task bodies, extracted with Jinja replaced by placeholder vars>  # passed, no real findings
```

**Not run** (no Docker, no kubectl, no live cluster on this machine):
`./uis deploy semaphore` end-to-end, the idempotent-second-run check, and the
undeploy/redeploy check. What *is* verified is every individual command the
playbook issues, run directly against the real binary outside Kubernetes (see
3.1) — this substantially de-risks the sequence but is not the same as a real
cluster run. **A real `./uis deploy semaphore` on an actual cluster is still
required before this plan's Acceptance Criteria can be marked met.**

---

## Phase 4: Service-wrapper metadata

### Tasks

- [x] 4.1 `provision-host/uis/services/management/service-semaphore.sh` —
  written with a real `SCRIPT_SUMMARY`, not a placeholder (see note below on
  why). Found and fixed a real, previously-undiscovered bug in
  `uis-docs.sh`'s field parsing while writing it: it silently **strips every
  apostrophe** from `SCRIPT_SUMMARY`/`SCRIPT_ABSTRACT` text (confirmed no
  existing merged service wrapper has ever put an apostrophe inside a parsed
  field value — only ever in comments, e.g. Dagster's). Worked around it by
  not using apostrophes in this service's summary; the generator bug itself
  is a separate, pre-existing issue out of this plan's scope, worth a
  follow-up ticket.
- [x] 4.2 Regenerated `website/src/data/services.json` via `uis-docs.sh` — 40
  services now (was 39), `semaphore` entry confirmed present and correct by
  parsing the output.
- [x] 4.3 Added the real SemaphoreUI logomark as
  `website/static/img/services/semaphore-logo.svg`, fetched from the
  project's own public repo (`web/src/assets/logo.svg` at the pinned
  `v2.19.12` tag) rather than a placeholder — same kind of asset
  `uptime-kuma-logo.svg`/`browserless-logo.svg` already are.
- [x] 4.4 (not in the original sketch — required to pass Acceptance's
  `npm run build` criterion, discovered only by actually running the build)
  Wrote `website/docs/services/management/semaphore.md`. `services.json`'s
  `SCRIPT_DOCS` field feeds Docusaurus's broken-link checker, which **fails
  the build** if the page it points to does not exist — this is not optional
  polish, it is required for Phase 4 to build at all. This absorbs most of
  `PLAN-service-semaphore-002-docs.md`'s scope (F5/F6/F8 facts, admin
  credentials table, "adding your first project" steps); PLAN-002 as a
  separate backlog item may now be largely redundant — worth closing or
  narrowing rather than leaving it to duplicate this page.

### Validation

```bash
cd website && npm run build
```

Passed clean on the second attempt — the first attempt failed on two real
issues found only by running it, not by inspection: a relative link in this
file broken by the backlog→active move (`./INVESTIGATE-...` →
`../backlog/INVESTIGATE-...`), and the missing docs page above.

---

## Acceptance Criteria

- [ ] `uis deploy semaphore` on a clean Rancher Desktop cluster produces a
  reachable UI with one working admin login — **not yet run; no cluster
  available in the environment this was implemented in.** Every command the
  playbook issues was verified individually against the real binary outside
  Kubernetes (see Phase 3), which de-risks this substantially but is not a
  substitute for a real run.
- [ ] Zero pre-configured projects, repositories, inventories or templates
  (F5) — true by construction (nothing in this plan creates any), confirmed
  locally that a freshly-bootstrapped instance's project list is `[]`
- [ ] A second `./uis deploy semaphore` run is idempotent — no error, no
  duplicate user, same working login — **not yet run against a real
  cluster**; the underlying `users get` → branch → `add`/`change-by-login`
  logic was verified directly against the real binary
- [ ] Login still works after `./uis undeploy semaphore && ./uis deploy semaphore`
  — **not yet run against a real cluster**
- [x] No real hostnames, IPs, project names or repository names from the
  reference instance appear anywhere in the manifests, playbook or
  service-wrapper file — grepped clean across every changed/new file
- [x] `npm run build` passes in `website/` — passed
- [x] `ansible-playbook --syntax-check` passed on both playbooks. `kubectl
  apply --dry-run=client` **could not be run** — no `kubectl` binary on this
  machine. YAML structure was instead verified by parsing with PyYAML
  (correct document count/kinds); this is a weaker check than a real
  server-side dry-run and should be treated as unverified until one happens.

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
- `ansible/playbooks/230-remove-uptime-kuma.yml` does exist and was used directly.
- **Known gap, explicitly not closed by this PR**: no real Kubernetes cluster,
  `kubectl`, or Docker was available in the environment this was implemented
  in, so `./uis deploy semaphore` itself has never actually run. Every
  command the playbook issues was instead verified directly against the real
  v2.19.12 binary outside Kubernetes (config.json shape, port format, health
  endpoint, non-interactive admin bootstrap, idempotent reconcile path,
  login verification) and the manifests were checked against the real
  upstream Dockerfile/entrypoint script (mount paths, user/group, config-file
  detection logic) rather than assumed. That is real risk reduction, but it
  is not the same claim as "this has been deployed and works" — the first
  real cluster run is the remaining, load-bearing unknown.
- Found a real bug in `provision-host/uis/manage/uis-docs.sh` while writing
  the service wrapper: it strips apostrophes from `SCRIPT_SUMMARY`/
  `SCRIPT_ABSTRACT` during parsing. Worked around locally; not fixed here
  (out of this plan's scope) — worth its own small follow-up.

## Files to Modify

- `provision-host/uis/templates/default-secrets.env` ✓
- `provision-host/uis/lib/first-run.sh` ✓
- `provision-host/uis/templates/secrets-templates/00-common-values.env.template` ✓
- `provision-host/uis/templates/secrets-templates/00-master-secrets.yml.template` ✓
- `manifests/630-semaphore-statefulset.yaml` (new) ✓
- `manifests/630-semaphore-ingressroute.yaml` (new) ✓
- `ansible/playbooks/630-setup-semaphore.yml` (new) ✓
- `ansible/playbooks/630-remove-semaphore.yml` (new) ✓
- `provision-host/uis/services/management/service-semaphore.sh` (new) ✓
- `website/src/data/services.json` (auto-regenerated, not hand-edited) ✓
- `website/static/img/services/semaphore-logo.svg` (new) ✓
- `website/docs/services/management/semaphore.md` (new, not in the original
  list — required by Phase 4's own build gate; see note there) ✓
