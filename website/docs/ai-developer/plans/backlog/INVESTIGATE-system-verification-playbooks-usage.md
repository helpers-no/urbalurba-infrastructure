# INVESTIGATE: Verification Playbooks Usage and Coverage

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Created**: 2026-03-12
**Status**: Backlog

## Problem Statement

The `ansible/playbooks/utility/` folder contains a mix of verification playbooks, task includes, setup helpers, and one-off utilities. Several of these files appear to have no active caller in the current repo.

That is a problem because these files exist to help prove that what UIS installs actually works. If verification playbooks are present but not wired into active setup or test flows, then service deployments can report success even when no real post-install validation happened. It also becomes hard to know which files are still part of the intended architecture and which are leftovers from earlier iterations.

This investigation should determine:

1. which utility files are part of the active verification strategy
2. which verification files are manual-only but still valuable
3. which files are obsolete, superseded, or misplaced
4. how verification should be standardized so every installed service is actually tested

---

## Finding (2026-08-21): tests are not missing — they are on the deploy gate

Measured across all 34 services: registered verify (`VERIFY_SERVICES`) versus
test tasks embedded in the **setup** playbook.

| | Count | |
|---|---|---|
| Registered verify playbook | 10 | reachable from `uis verify` and `test-all` |
| **Tests only inside the setup playbook** | **22** | run at deploy time, cannot be re-run |
| No tests anywhere | 2 | `traefik`, `jupyterhub` |

The 22 are not lightly tested. Ranked by test tasks on the deploy gate:

```
authentik 28   grafana 14   otel-collector 12   whoami 8   nginx 7   litellm 7
loki 6   tempo 6   prometheus 5   elasticsearch 5   mongodb 4   unity-catalog 4
mysql 3   pgadmin 3   gravitee 3   rabbitmq 3   redisinsight 3
qdrant 2   openwebui 2   redis 1   spark 1   postgrest 1
```

**This inverts the assumption behind the earlier framing of this investigation.**
The risk was stated as "verification playbooks present but not wired into active
setup or test flows → deployments report success when no real validation
happened." That is real. But the larger population is the opposite shape: real
validation that runs **only** at deploy time, on the gate, where a flaky test
fails the *deployment* rather than reporting a *test failure*.

That is exactly OBS-F6. Grafana carries **14** test tasks on its deploy gate; one
of them hit the `kubectl run --rm -i` race, and a healthy stack could not deploy
Grafana. The defect was never Grafana.

~~**Authentik is the same bomb, unexploded, at twice the size**~~ — ⚠️ **retracted
2026-08-21, same day, after actually running it.** Authentik's 28 tasks are not
brittle assertions on a gate. They stand up a protected test app, deploy four SSO
blueprints, and verify the auth redirect flow end to end — external and internal
302s, then an E2E auth suite. `deploy authentik — PASS (10m 43s)` on a clean
Rancher Desktop cluster.

It is arguably the most thorough test in the repo, not the most fragile.
**Task count is not a proxy for risk.** Counting task names instead of reading
them produced a confident wrong answer here, and had already produced one for
Redis in the same survey. Treat every number in the table above as an upper
bound on *what exists*, and no evidence at all about *what it is worth*.

Three services with a registered verify have **zero** in-setup tests — `enonic`,
`nextcloud`, `openmetadata`. That is the shape the guide asks for
([PLAN-service-grafana-deploy-gate-fix](./PLAN-service-grafana-deploy-gate-fix.md)
Phase 4: *E2E belongs in `NNN-test-<id>.yml`, not the deploy gate*), and it
already exists as a worked pattern to copy.

### What this implies for the plans this investigation should produce

Terje's direction, 2026-08-21: *"we should create verify for all services."*
Refined by the measurement above, that is **two different jobs**, and conflating
them would waste most of the work:

1. **Move, don't write** — for the 22, the tests exist and are often thorough.
   The job is relocating them into `NNN-test-<id>.yml`, registering them in the
   three places, and leaving the deploy gate with readiness checks only. Start
   with `authentik` (28) and `grafana` (14): highest blast radius, and Grafana
   already has a plan open.
2. **Write from nothing** — only `traefik` and `jupyterhub`, plus any of the 22
   whose in-setup tests turn out to be readiness checks rather than E2E.

Sequencing note: doing (1) *before*
[PLAN-docs-provisioning-unsafe-test-idiom](./PLAN-docs-provisioning-unsafe-test-idiom.md)
would relocate the broken `kubectl run --rm -i` idiom into 22 new files. Fix the
idiom first, then move the tests, or the sweep has to happen twice.

*Survey produced during the Rancher Desktop validation run — see
[STATUS-rancher-desktop-validation-2026-08-21](../completed/STATUS-rancher-desktop-validation-2026-08-21.md).*


## Finding (2026-08-21): the rules document is the propagation source

The third finding — `kubectl run --rm -i` returning `rc=0` with empty stdout —
has been treated as something found *in* playbooks. It is also **taught**:
[`rules/provisioning.md`](../../../contributors/rules/provisioning.md) presents
that exact idiom as the CORRECT pattern, in two separate sections, complete with
the `until:` on stdout that turns the race into a false failure.

That explains why the idiom "appears across other services' verify playbooks":
contributors are following the documented rule. Fixing playbooks one at a time
while the rule keeps generating new ones is the same shape this investigation
already identified for verify registration — *"the guide's wording is the cause
rather than carelessness."*

Split out as [PLAN-docs-provisioning-unsafe-test-idiom](./PLAN-docs-provisioning-unsafe-test-idiom.md)
so the source is fixed independently of this investigation's sweep. That plan
produces the occurrence list and hands it back here; it deliberately fixes no
individual service.


## Why This Matters

UIS is infrastructure automation. A manifest applying or a Helm release succeeding is not enough on its own. A service is only really installed when:

- pods are healthy
- the service responds on the expected endpoint
- required dependencies are reachable
- basic CRUD or smoke-test flows succeed

If verification playbooks are missing, unused, or inconsistent, then the platform can drift into a state where "deploy succeeded" does not mean "service works."

---

## Current State

### What the utility folder contains today

`ansible/playbooks/utility/` currently contains these files:

| File | Purpose category | Current usage |
|------|------------------|---------------|
| `u01-add-domains-to-tunnel.yml` | utility helper | No active caller found |
| `u02-verify-postgres.yml` | verification playbook | **Used** by `ansible/playbooks/650-setup-backstage.yml` |
| `u03-extract-cluster-config.yml` | utility helper | **Used** by `troubleshooting/export-cluster-status.sh` |
| `u04-test-url.yml` | verification helper | No active caller found |
| `u05-copy-selected-secret-keys.yml` | reusable task include | No active caller found |
| `u06-openwebui-create-postgres.yml` | setup helper | **Used** by `ansible/playbooks/200-setup-open-webui.yml` |
| `u07-setup-unity-catalog-database.yml` | setup helper | No active caller found |
| `u07-verify-qdrant.yml` | verification playbook | No active caller found |
| `u07-verify-qdrant-tasks.yml` | verification task include | **Used** by `ansible/playbooks/044-setup-qdrant.yml` |
| `u08-verify-mysql.yml` | verification playbook | Only referenced from `not-in-use` shell scripts and docs |
| `u09-authentik-create-postgres.yml` | setup helper | **Used** by `ansible/playbooks/070-setup-authentik.yml` |
| `u10-backstage-create-postgres.yml` | setup helper | No active caller found |
| `u10-litellm-create-postgres.yml` | setup helper | **Used** by `ansible/playbooks/210-setup-litellm.yml` |
| `u10-verify-observability-tasks.yml` | verification task include | No active caller found |

### Key observations

1. The folder is not verification-only. It mixes verification, database setup, tunnel utilities, secret-copy helpers, and troubleshooting support.
2. There is at least one clear supersession pattern already:
   - `u07-verify-qdrant.yml` appears unused
   - `u07-verify-qdrant-tasks.yml` is the version actually included by `044-setup-qdrant.yml`
3. `u02-verify-postgres.yml` was recently wired into Backstage setup, which suggests some verification utilities were created before a consistent calling pattern existed.
4. `u08-verify-mysql.yml` may still be useful, but it is not part of the active deployment path right now.
5. `u10-verify-observability-tasks.yml` looks like a substantial verification implementation, but no current playbook includes it.
6. `u10-backstage-create-postgres.yml` exists, but `650-setup-backstage.yml` currently performs the database setup inline instead of calling the utility file.

---

## Questions to Investigate

### Q1: What should count as a verification playbook in UIS?

The folder currently mixes several kinds of files:

- full verification playbooks such as `u02-verify-postgres.yml`
- task fragments intended for `include_tasks`, such as `u07-verify-qdrant-tasks.yml`
- setup helpers such as `u09-authentik-create-postgres.yml`
- generic utilities such as `u03-extract-cluster-config.yml`

The investigation should decide whether these should stay together or be separated by purpose.

### Q2: Which services are supposed to have mandatory post-install verification?

Not every service currently follows the same pattern:

- some setup playbooks run verification directly
- some have dedicated `*-test-*` playbooks
- some appear to have utility verifiers that are never called
- some may rely only on Helm success or pod readiness

We need a clear rule for when verification runs automatically and what minimum checks are required.

### Q3: Which unused files are intentionally manual-only?

Some files may be valid operational tools even if they are not part of automatic deployment. For example:

- manual smoke-test helpers
- troubleshooting utilities
- recovery or migration helpers

If that is the case, the repo should make that explicit so unused does not look accidental.

### Q4: Which files are obsolete or superseded?

Examples to confirm:

- Is `u07-verify-qdrant.yml` replaced by `u07-verify-qdrant-tasks.yml`?
- Is `u10-backstage-create-postgres.yml` the intended reusable implementation, with inline Backstage DB setup now just temporary duplication?
- Is `u10-verify-observability-tasks.yml` unfinished, abandoned, or simply not wired in yet?
- Is `u08-verify-mysql.yml` blocked because MySQL deployment is inactive, or was it forgotten?

### Q5: Should verification live in setup playbooks, dedicated test playbooks, or reusable utility files?

There are at least three patterns in the repo today:

1. inline verification inside a setup playbook
2. dedicated service test playbook such as `650-test-backstage.yml`
3. reusable utility verification playbooks or task includes

The investigation should recommend one primary pattern and when exceptions are acceptable.

### Q6: Should naming and folder structure be made clearer?

Potential sources of confusion today:

- files in `utility/` are not all utilities of the same kind
- some are full playbooks, some are task includes
- some "verify" files are active, some are orphaned
- some setup helpers are named similarly to verification helpers

This may justify splitting into clearer locations such as:

- `utility/verification/`
- `utility/tasks/`
- `utility/database/`

Or a simpler naming convention that distinguishes:

- runnable playbooks
- include-only task files
- manual-only operational helpers

---

## Initial Options

### Option A: Keep the folder, wire the missing verifiers

Use the existing files as the base, then:

- identify which unused verification files should be called automatically
- add missing `include_tasks` or `ansible-playbook` calls
- remove only obviously obsolete files

**Pros:**
- low structural churn
- keeps current paths stable
- fastest path to better coverage

**Cons:**
- folder remains semantically mixed
- naming confusion remains
- dead files may continue to accumulate

### Option B: Standardize verification and reorganize utility files

Create a clearer structure and a standard rule for verification:

- service setup deploys
- service test/verify runs smoke tests
- shared checks live in reusable utility files
- task includes are named and placed differently from standalone playbooks

**Pros:**
- easier to understand and maintain
- makes unused files easier to spot
- improves consistency across services

**Cons:**
- more file movement and refactoring
- requires updating references
- higher short-term effort

### Option C: Keep only active utilities and move the rest to explicit manual/troubleshooting areas

Treat active deployment-time utilities as first-class, and move manual-only helpers elsewhere.

**Pros:**
- clearer signal about what is part of automated deployment
- reduces clutter in the utility folder
- helps separate productized workflow from ad hoc tools

**Cons:**
- still requires investigation to avoid deleting useful files
- may spread related logic across multiple locations

---

## Investigation Tasks

### Phase 1: Classify the utility files

#### Tasks

- [ ] 1.1 Review every file in `ansible/playbooks/utility/` and classify it as verification, setup helper, task include, troubleshooting helper, or obsolete
- [ ] 1.2 Confirm whether each file has an active caller, a manual-only purpose, or no intended use
- [ ] 1.3 Identify superseded pairs where one file replaced another without cleanup
- [ ] 1.4 Document whether each unused file should be wired in, moved, renamed, or removed

### Validation

User confirms the classification looks correct.

---

### Phase 2: Define the UIS verification pattern

#### Tasks

- [ ] 2.1 Review how active services currently verify successful installation
- [ ] 2.2 Define the minimum verification standard for a UIS service
- [ ] 2.3 Decide when verification should run automatically during setup versus through a separate test playbook
- [ ] 2.4 Decide where reusable verification logic should live and how include-only task files should be named

### Validation

User confirms the recommended verification pattern is acceptable.

---

### Phase 3: Turn findings into implementation plans

#### Tasks

- [ ] 3.1 Create a cleanup plan for obsolete or superseded utility files
- [ ] 3.2 Create a plan to wire missing verification into active deployment or test flows
- [ ] 3.3 Create a plan to reorganize or rename utility files if structural changes are needed

### Validation

User confirms the follow-up plans match the investigation outcome.

---

## Desired Outcome

After this investigation, it should be obvious:

- which verification files are actively part of UIS
- which services are actually verified after installation
- which files are manual operational tools
- which files should be deleted or moved
- what the standard UIS verification pattern is going forward

---

## Files Likely In Scope

- `ansible/playbooks/utility/`
- `ansible/playbooks/*-setup-*.yml`
- `ansible/playbooks/*-test-*.yml`
- `provision-host/uis/services/`
- `provision-host/kubernetes/`
- `website/docs/services/`

---

## Next Step

Use this investigation to produce one or more implementation plans, likely including:

- a cleanup plan for unused or superseded utility files
- a plan to wire service verification into active setup/test flows
- an optional plan to reorganize utility file naming and folder structure
