# Investigate: `uis deploy litellm` reports success on a broken install

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

**Goal**: Make `uis deploy litellm` produce a working install every time from a
clean state, and make it fail loudly when it does not.

**Last Updated**: 2026-08-06

**Verified on**: Proxmox host `odin` / k3s `asgard`, PostgreSQL 18 running
**outside** the cluster, LiteLLM 1.97.0

---

## Questions to Answer

1. Does `uis deploy litellm` work on a genuinely clean install?
2. If not, why — and why does the playbook report success?
3. Can the install be made deterministic?
4. Is UIS deploying a version of LiteLLM we can reproduce?

---

## Current State

`uis deploy litellm` exits 0, prints `✅ SUCCESS - LiteLLM is running and
verified`, and registers the service for autostart. `/v1/models` answers.

On a clean install none of that means the install worked.

---

## Findings

### F1 — ⚠️ UIS cannot test its own clean install

`210-remove-litellm.yml` line 10:

```
# Note: The PostgreSQL database 'litellm' is NOT deleted.
```

`uis undeploy litellm` removes the Helm release and the ConfigMap but leaves the
database and role. **Every reinstall after the first is therefore an upgrade
onto an existing schema**, which hides first-install failures completely. This
finding is what made the rest of the investigation possible: the bug is
invisible until the database is dropped by hand.

The utility playbook `u10-litellm-create-postgres.yml` already implements
`-e operation=delete` (drop database, drop role, terminate connections). The
remove playbook simply never calls it.

### F2 — On a truly clean install, the schema is never created

With the database and role dropped first:

```
PLAY RECAP  ...  failed=0        <- UIS reports success
tables in litellm db : 0         <- schema never created
models exposed       : 0
virtual key          : FAIL
```

The proxy still serves `/v1/models` because **the model list comes from the
`ai-models-litellm` ConfigMap, not from the database**. So every check UIS
performs passes while virtual keys, spend tracking and budgets are silently
dead. This is the same end state previously seen on the Rancher Desktop host,
where the database was found with zero tables and had to be repaired by hand.

### F3 — The cause is not credentials, ordering, or a race

The chart's migration Job fails with:

```
Error: P1000: Authentication failed against database server at
`postgresql.default.svc.cluster.local`, the provided database credentials
for `litellm` are not valid.
LiteLLM Proxy: Database migration failed but continuing startup.
```

Each of these was tested and ruled out:

| Hypothesis | Test | Result |
|---|---|---|
| Wrong password | `psql` from a pod with the exact secret value | **AUTH OK** |
| Unexpanded `$(VAR)` in DATABASE_URL | read the resolved value inside the pod | correct user, 24-char password, correct host |
| URL-unsafe characters in the password | charset check | alphanumeric only |
| Secrets applied after the DB step | inspect deploy log ordering | secrets → DB → helm, correct |
| Role created too late (race) | pre-create DB+role, verify `AUTH OK`, *then* deploy | **still 0 tables** |

And `prisma migrate deploy` run by hand **inside the same pod, with the same
environment, succeeds every time.**

The failure is also **intermittent** — across five clean cycles the Job produced
4 × P1000 twice and 0 × P1000 twice. Prime remaining suspect is Prisma's own
warning, emitted immediately before the failure:

```
prisma:warn Prisma doesn't know which engines to download for the
Linux distro "wolfi". Falling back to ...
```

i.e. an upstream image/engine problem, not a UIS configuration problem. **Root
cause is not yet proven**, which is why the chosen fix is to detect and repair
rather than to "correct the credentials".

### F4 — The playbook declares success unconditionally

Task 21 prints `✅ SUCCESS - LiteLLM is running and verified` with no `when:`
condition, including the lines "API responding: ✅ Models loaded and verified".
Task 9 (service connectivity) carries `ignore_errors: true`. Nothing anywhere
checks that the database schema exists.

### F5 — The playbook returns before the service is ready

There is no wait between the rollout and the end of the play, so a caller that
immediately queries `/v1/models` gets an empty list from a pod that is still
starting. Observed repeatedly as `models exposed : 0` on an otherwise healthy
install.

### F6 — The image is an unpinned rolling tag

`220-litellm-config.yaml`:

```yaml
image:
  repository: ghcr.io/berriai/litellm-database
  tag: "main-latest"          # <- rolling main-branch build
  pullPolicy: Always
```

This currently resolves to **LiteLLM 1.97.0**, while the latest *stable* upstream
release is **v1.95.0**. So UIS is not behind — it is running pre-release code
from the main branch, and **the version can change on any pod restart**. The
Helm chart is likewise unpinned (`helm show chart oci://...` with no `--version`).
This breaks reproducibility and the dev/prod parity promise: two installs a week
apart are not the same platform.

The tag also carries a stale comment: `# Back to latest - should have the fix`.

### F7 — The default ConfigMap is Docker-Desktop-only

When no `ai-models-litellm` ConfigMap exists, task 3.1 creates one pointing at:

```yaml
api_base: "http://host.docker.internal:11434"
```

`host.docker.internal` resolves under Docker Desktop / Rancher Desktop and
**nowhere else**. On a real k3s node the default model is unreachable, so a
first-time install on a server has a model list that cannot answer.

### F8 — Model verification reads the wrong ConfigMap

Task 13 reads a ConfigMap named `litellm-config`, but tasks 3/3.1 create
`ai-models-litellm`. Guarded by `when: litellm_configmap.resources | length > 0`,
so it silently skips and the "expected model count" check never runs.

---

## How to reproduce

`uis undeploy` is not sufficient — the database must be dropped:

```bash
# 1. remove the release
./uis undeploy litellm

# 2. drop what undeploy leaves behind (see F1)
psql -c "drop database if exists litellm"
psql -c "drop role if exists litellm"

# 3. reinstall
./uis deploy litellm

# 4. the check UIS does not do
psql -d litellm -c "select count(*) from information_schema.tables
                    where table_schema='public'"   # -> 0 on a failed install
```

A working install has **69+ tables**.

---

## Options

### Option A: Fix the credentials passed to the migration Job

**Pros:** addresses a root cause, if that is the root cause.
**Cons:** the credentials were proven correct (F3). There is nothing to fix, and
the failure is intermittent and appears to originate in the upstream image.

### Option B: Detect and repair — verify the schema, run the migration if absent, fail loudly if it cannot be created

**Pros:** deterministic outcome regardless of the upstream cause; turns a silent
failure into either a working install or a loud error; the repair
(`prisma migrate deploy` in-pod) is proven to work every time.
**Cons:** treats a symptom; carries an extra step that becomes dead code if
upstream is fixed.

### Option C: Wait for upstream

**Pros:** no local change.
**Cons:** ships a platform whose database silently does not initialise.

---

## Recommendation

**Option B**, plus the independent defects F1, F5, F6, F7, F8.

Detect-and-repair is the right call even though it is not a root-cause fix,
because the verification step is *itself* missing functionality: no UIS service
currently checks that the database it depends on was actually initialised. The
repair is a bonus; the check is the real deliverable. If upstream later fixes
the Job, the check stays valuable and the repair simply never fires.

**Generalises beyond LiteLLM:** every UIS service backed by a database has this
same blind spot. Worth considering a shared post-install schema assertion.

---

## Next Steps

- [x] Create `PLAN-service-litellm-001-schema-verify.md` — verify/repair/fail loudly
- [ ] Create `PLAN-service-litellm-002-version-pinning.md` — pin chart + image
- [ ] Create `PLAN-service-litellm-003-undeploy-purge.md` — allow a true clean removal
- [ ] Create `PLAN-service-litellm-004-config-portability.md` — F7 + F8

**Related:**
[INVESTIGATE-system-observability](./INVESTIGATE-system-observability.md) —
a failing install that reports success is the same class of problem as a
monitoring stack that cannot alert.
