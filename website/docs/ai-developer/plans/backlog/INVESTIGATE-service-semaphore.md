# Investigate: SemaphoreUI as a UIS service

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

**Goal**: Make [SemaphoreUI](https://semaphoreui.com) — a web UI and API for running
Ansible (and Terraform/OpenTofu/PowerShell) playbooks — a standard, documented UIS
service: `uis deploy semaphore` installs a clean instance with no projects, repos or
credentials pre-configured, the same way `uis deploy dagster` ships an empty
`dagster-user-deployments: []`.

**Origin**: Terje, 2026-10-05 (`urb-agents#1856`) — UIS has a real, actively-used
SemaphoreUI instance on the reference installation's network, and zero documentation
of how it's set up. Ties directly into the architecture direction from
`urb-agents#1805`: section 7 ("CI/CD and build infrastructure") asks "can essential
pipelines be triggered and coordinated without an external control plane?" and
section 4.2 ("Alternate — local execution during external service outages") names
self-hosted runners and local pipeline coordination as exactly this class of
capability. SemaphoreUI is a concrete, already-running answer to both — UIS just
doesn't know about it yet.

**Related**: [INVESTIGATE-system-registry-cache](./INVESTIGATE-system-registry-cache.md)
(F1, the "components beside the cluster" class that F8 below first mis-assigned
this investigation to, then corrected), [INVESTIGATE-system-backup-and-scheduling](./INVESTIGATE-system-backup-and-scheduling.md)
(Part 4 Q1, same class), [INVESTIGATE-service-uptime-kuma](./INVESTIGATE-service-uptime-kuma.md)
(F8, same class), [INVESTIGATE-system-platform-provisioning-layer](./INVESTIGATE-system-platform-provisioning-layer.md).

**Created**: 2026-10-05 — investigated read-only against a real, actively-used
reference instance (dedicated SSH access provisioned specifically for this; the
instance itself was explicitly flagged as production, not disposable — nothing on
it was changed).

---

## Background

No file in this repository mentions SemaphoreUI, Semaphore, or `semaphore` as a
service. `grep -ril semaphore provision-host/ ansible/ manifests/` → no matches
before this investigation. The reference instance exists and is in active daily
use (thousands of recorded task runs), entirely outside UIS's knowledge — a lab
owner cloning this repository today would have no way to reproduce it.

---

## Part 1: Findings from the reference instance

### F1 — Installed as a native systemd service from an official `.deb`, not Docker

```
dpkg -l | grep semaphore
ii  semaphore  2.19.12  amd64  Modern UI and powerful API for Ansible, Terraform, OpenTofu, PowerShell and other DevOps tools.
```

A single statically-linked Go binary at `/usr/bin/semaphore` (~100 MB), installed
from the project's own `.deb` release (not an apt repository — no `Candidate`
version source beyond `/var/lib/dpkg/status`). Systemd unit:

```
[Service]
Type=simple
ExecStart=/usr/bin/semaphore service --config=/etc/semaphore/config.json
Restart=always
RestartSec=5
```

`semaphore service` and `semaphore server` are aliases for the same server-mode
command — the CLI's help text lists both. No reverse proxy in front of it on the
reference instance; it serves its own HTTP directly on the configured port.

### F2 — Config is one small JSON file; three secrets are generated once and never rotated

`/etc/semaphore/config.json` (503 bytes, `0600 root:root`) holds, among plain
settings (`port`, `web_host`, `max_parallel_tasks`, `tmp_path`): `cookie_hash`,
`cookie_encryption` and `access_key_encryption` — three independent base64 secrets.
`cookie_hash`/`cookie_encryption` sign and encrypt session cookies; `access_key_encryption`
is the key that encrypts every stored credential (SSH keys, vault passwords, API
tokens for Terraform backends, etc.) at rest in the database. Semaphore's own
`vaults rekey` subcommand exists specifically to re-encrypt all stored secrets
under a new key — implying rotation is a supported but manual, explicit act, not
automatic.

**For a clean install, these three values must be freshly generated per
installation** (e.g. `openssl rand -base64 32`) and never reused across
installations or checked into anything — equivalent in sensitivity to the
cookie-signing and encryption keys UIS's own secrets pipeline already treats this
way for other services.

### F3 — Storage: the reference instance uses embedded SQLite, not Postgres/MySQL

```json
"dialect": "sqlite",
"sqlite": {"host": "/var/lib/semaphore/database.sqlite"}
```

Semaphore supports `bolt` (deprecated), `sqlite`, `mysql` and `postgres` as the
`dialect`. The reference instance's database was 51 MB after several weeks of
real daily use (7,367 recorded task runs, 1 project, 5 stored access keys) — a
light footprint. **For a UIS in-cluster deployment, Postgres is the better fit**:
UIS already runs a shared PostgreSQL for every other stateful service
(dagster, authentik, etc.) via the same `uis configure postgresql` pattern, and a
pod-local SQLite file doesn't survive a pod reschedule onto different storage the
way a chart's `persistentVolumeClaim` + an external Postgres both do more
conventionally. Semaphore's own docs confirm Postgres is a first-class supported
dialect, not an afterthought.

### F4 — Non-interactive bootstrap exists; the interactive `setup` wizard is not required

```
semaphore users add --admin --login <login> --email <email> --name <name> --password <password>
```

This is a complete, scriptable path to create the first admin account — ansible
can call it directly after the service starts and runs its own DB migration on
first boot, with no need to drive the `semaphore setup` interactive wizard (which
exists for humans doing a manual install, not for an automated playbook).

### F5 — Data model: projects own everything; access keys are the credential store

Schema (table names, not data):

```
project, project__repository, project__inventory, project__template,
project__environment, project__secret_storage, project__schedule,
project__workflow_template, access_key, runner, user, user__token, task, ...
```

One `project` is the top-level container for everything: git repositories,
inventories, environments, and the playbook "templates" that actually get run.
`access_key` stores encrypted (`access_key_encryption`) credentials — SSH keys,
vault passwords — scoped to a project, an environment, or a user. **A clean
install ships zero rows in every one of these tables** — no project, no
repository, no inventory, no template, no access key. That emptiness is the
point: exactly the same shape as `dagster-user-deployments: []` or
`code_locations: []` elsewhere in this product — the mechanism ships, an
application/operator's own wiring does not.

### F6 — API tokens are stored as the token value itself, not a hash

```sql
CREATE TABLE user__token (
  id      VARCHAR(44)   NOT NULL PRIMARY KEY,   -- the token value IS the row's primary key
  created DATETIME      NOT NULL,
  expired INTEGER NOT NULL DEFAULT 0,
  user_id INTEGER NOT NULL REFERENCES user(id) ON DELETE CASCADE,
  expires_at DATETIME NULL,
  name    VARCHAR(255) NOT NULL DEFAULT ''
);
```

No separate hash or secret column — the 44-character `id` column is the bearer
token a client presents, stored in cleartext in the database file. This is
upstream's own design (confirmed by schema inspection, not assumed), not a UIS
defect, but worth stating plainly in the service doc: anyone who can read
`database.sqlite` (or the equivalent Postgres table) can use every issued API
token directly. `semaphore users token create`/`list` manage them per-user via
the CLI.

### F7 — Distributed "runner" mode exists and is unused on the reference instance

The `runner` table (`registration_token`, `webhook`, `max_parallel_tasks`,
`public_key`) backs a real feature: Semaphore can dispatch tasks to separate
`semaphore runner` processes registered against a project, rather than executing
every task on the server itself. **The reference instance has zero rows in this
table** — all task execution happens in-process on the server
(`max_parallel_tasks: 2` globally, not per-runner). Relevant to `#1805`'s
self-hosted-CI question (Part 2, below) but out of scope for a first UIS service
PLAN — nothing here needs it to ship a working `uis deploy semaphore`.

### F8 — Corrected: this is NOT the registry-cache's bootstrap-circularity problem

The reference instance's one project holds dozens of playbook templates — health
checks, patch-ring rollouts, inventory-drift detection, state tracking, pushing
monitor config to a watchdog — run against the lab's own physical hosts and the
guests on them.

**First pass at this finding, wrong, kept here because the correction is the
useful part**: this read as the registry cache's F1 bootstrap-circularity
argument again — "a tool whose job includes recovering infrastructure needs to
run independently of the thing it might need to recover" — and was written up
as a fifth instance of the "components beside the cluster" class named across
three other investigations in this repo. That conclusion did not survive
checking it against the actual evidence already in hand, rather than the shape
of the problem (Terje, 2026-10-05, directly: "that role it can do even if it run
inside the rancher desktop cluster").

**What's actually true, checked against every template name recorded above**:
every one of them targets a *different* host or service reachable over the
network — SSH to a VM or physical machine, HTTP to a watchdog's API. None of
them is "recover the specific cluster this pod's own node depends on." That is
the one case where the registry cache's circularity argument would actually
apply, and it isn't what any of the observed playbooks do. A pod inside a
Rancher Desktop cluster can SSH out and patch a VM, or push config to Uptime
Kuma's API, exactly as capably as a process running anywhere else — it only
needs network egress, which a pod already has. **In-cluster is not a
compromise shape for this tool's actual job; it is the fully-capable one.**

Per the task that opened this investigation, **the reference instance's actual
project, repository, inventory and template wiring is personal to this
installation and is described only generically above** — it is not reproduced
here and must not ship as the default content of a clean install.

### F9 — Resource footprint is small

2 vCPU, 1 GiB RAM, 8 GiB disk (LXC), ~150 MiB RSS for the `semaphore` process at
idle, 51 MB database after weeks of real use. Comfortably fits the UIS laptop
profile if deployed in-cluster.

---

## Part 2: In-cluster by default; where it runs in production is a config choice, not a different build

Not the fork the first pass at F8 framed it as. Terje's own UIS principle,
stated directly (2026-10-05): a developer installs and runs the full thing on
Rancher Desktop while building and testing; moving to production runs the
**same** install, unchanged, just reconfigured for where production actually
puts it. For Semaphore specifically, given production today is a Proxmox LXC:
first it exists in UIS as a service — that's what a developer gets on Rancher
Desktop, and per F8's correction, that shape is genuinely sufficient for the
tool's real job, not a limited stand-in for it — and a config change retargets
*that same service* to run as an LXC instead, for the installation that wants
it there.

**What this PLAN ships**: `uis deploy semaphore` as a standard in-cluster
service — official Docker image, Postgres-backed, no pre-wired projects. Works
fully on Rancher Desktop today; nothing about F8 limits what it can actually do
from there.

**What this PLAN does not build**: the general mechanism to retarget *any* UIS
service's deployment shape via config (in-cluster vs. LXC vs. elsewhere).
Nothing in UIS has that today — `uis deploy <service>` always means "into the
active cluster." Building it generically would also be the real resolution to
the "components beside the cluster" question named across
`INVESTIGATE-system-registry-cache` (F1), `INVESTIGATE-system-backup-and-scheduling`
(Part 4 Q1) and `INVESTIGATE-system-monitor-definitions-with-services` — but
that is a cross-cutting capability worth its own investigation, not something
to invent as a one-off inside this service's PLAN. Semaphore ships fully
functional without it; the LXC-retargeting path is a named follow-up, not a
blocker.

---

## Part 3: What a clean install needs that the reference instance's own setup does not show

1. **Fresh `cookie_hash`/`cookie_encryption`/`access_key_encryption`**, generated
   at deploy time, never reused (F2).
2. **Postgres, not SQLite** — a new database + role via the existing
   `uis configure postgresql` pattern (F3), matching every other stateful UIS
   service.
3. **One non-interactive admin user**, created via `semaphore users add --admin`
   (F4) with a UIS-generated password through the secrets pipeline, not an
   interactive prompt during deploy.
4. **Zero projects, repositories, inventories, templates or access keys** (F5) —
   the empty state is correct and matches this product's existing convention for
   tenant-owned configuration (code locations, code-concurrency rules, etc.).
5. **A documented, explicit statement of scope** (F8) — this service runs
   ansible against things the cluster can reach; it is not a replacement for
   host/platform-level fleet automation.

---

## Part 4: Proposed plans (ordered)

```
PLAN-service-semaphore-001-deploy.md   ← manifest + ansible playbook, clean install
PLAN-service-semaphore-002-docs.md     ← website/docs/services/ page (or folded into 001)
```

### PLAN-001 — Deploy

Helm values / manifest for the official `semaphoreui/semaphore` image, wired to
the shared Postgres (F3), `dagsterWebserver`-style resource requests for a small
footprint (F9), fresh secrets generated per install (F2), first admin user
created non-interactively (F4), Traefik `IngressRoute` matching this product's
existing pattern for internal-only operator tools (same class as the Dagster UI).

*Acceptance:* `uis deploy semaphore` on a clean installation produces a reachable
UI with one working admin login, zero pre-configured projects, and the ansible
playbook idempotent on a second run.

### PLAN-002 — Docs

`website/docs/services/<category>/semaphore.md` describing what it is, the
scope limitation from F8, how to add a first project/repository/credential
(an operator's own task, matching the "application's own installer writes its
entry" convention `dagster-code-locations.yaml` already uses), and the
plaintext-token fact from F6 stated plainly rather than discovered the hard way.

---

## Part 5: Open questions

1. **Does any UIS service actually need the generic deployment-shape-retargeting
   mechanism Part 2 names (in-cluster vs. LXC vs. elsewhere, chosen by config)?**
   Semaphore, corrected (F8), does not strictly need it — in-cluster already
   does its real job fully. Worth checking whether the registry cache / backup
   scheduler / monitor-definitions "beside the cluster" instances have the same
   property before assuming the generic mechanism is actually required anywhere,
   rather than building it on the strength of a pattern-match that didn't hold
   up here. Not blocking PLAN-001.
2. **Does the distributed `runner` mode (F7) matter for `#1805`'s self-hosted-CI
   question later?** Not used by the reference instance, not needed for a
   working `uis deploy semaphore`. Worth revisiting only if a dedicated
   self-hosted-CI investigation happens.
3. **Password handling for the first admin user** — UIS-generated and stored in
   the secrets pipeline, or require the operator to supply one at deploy time?
4. **Which manifest category/namespace** — does this live alongside
   `management/` (ArgoCD, pgAdmin) given its operator-tool nature, or does its
   automation role argue for something else?
5. **TLS/exposure** — internal-only via Traefik like Dagster's UI (no public case
   on any installation), or does a lab owner reasonably want this reachable from
   outside? Default should probably match Dagster's "internal-only, no
   public-facing case" unless a concrete reason surfaces.

---

## Appendix: reference implementation as observed, generically

Debian 13 (trixie) LXC, 2 vCPU / 1 GiB RAM / 8 GiB disk. SemaphoreUI 2.19.12
installed from the project's official `.deb`, running as a systemd service
(`Restart=always`), SQLite storage, port 3000, no reverse proxy. One project
holding dozens of playbook templates for fleet-level health checks, patch-ring
rollouts, inventory-drift detection and state tracking against the lab's own
physical hosts — real, personal infrastructure wiring, described only by shape
above (F8), not reproduced. Zero distributed runners registered; all execution
in-process. ~150 MiB RSS at idle, 51 MB database after weeks of active daily use.
