# Plan: a template can install an application that spans several services

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Active — all five phases implemented; end-to-end install needs a cluster (tester task)

**Goal**: `uis template install <app>` can deploy and configure a multi-instance
service, pass every `uis configure` flag an application needs, and apply a
directory of ordered migrations — so the first real application's declaration
installs as written instead of failing on its second step.

**Parent**: [INVESTIGATE-templates-multi-surface-application](../backlog/INVESTIGATE-templates-multi-surface-application.md)
— closes **TPL-F3**, **TPL-F4** and **TPL-F7**.

**Decided**: the application-deployment rule
([Rules for Deploying Applications](../../../contributors/rules/application-deployment.md))
puts provisioning on the `uis` side, which is what this plan builds. Nothing here
touches the ArgoCD path.

**Not in scope**: TPL-F5 (a `provides:` entry for a Dagster code location) and
TPL-F8 (intra-application ordering, deferred — see TPL-F9 for why it is off the
critical path). Both are named in *Out of scope* below with what that costs.

---

## Why these three and not the others

TPL-F3 is a latent defect for **any** multi-instance service, not just this
tenant: `template.sh:405` deploys without `--app` while the configure call two
lines below passes it, so the two halves of one loop disagree about whether a
service is multi-instance. That is worth fixing regardless of templates.

TPL-F7 is what blocks the first application **today** — its `init:` is a
directory of 50 numbered files and the code takes exactly one file.

TPL-F4 is the vocabulary without which a declaration cannot say what it needs.

---

## Design decisions, made here so implementation is mechanical

### D1 — the plan line stops carrying configuration

`_resolve_provides` currently emits `<priority>|<service_id>|<database>|<init_file>`
and the executor reads it with `IFS='|' read -r priority svc db init`. TPL-F4
adds five fields; a nine-field pipe line is brittle, and `read -r` silently
mis-binds if a value ever contains `|`.

**Decision:** the plan line becomes `<priority>|<service_id>` only. Per-service
configuration is written to `$plan_dir/<service_id>.conf` as `key=value` lines
and read back at execution.

Why this shape:
- extending it later is adding a key, not changing a format — TPL-F5's
  `code_location_*` keys drop in without touching the executor's parsing
- **bash 3.x is a hard constraint** (macOS default; `categories.sh` and
  `service-scanner.sh` both say so), so associative arrays are unavailable and
  files are the natural keyed store
- one file per service is greppable when an install goes wrong, which a
  pipe-delimited line is not

### D2 — `--app` on deploy is driven by data, not a list

`services.json` already carries `multiInstance` (`true` for `postgrest`). The
executor passes `--app "$app_name"` to `uis deploy` **iff** that field is true.
No hardcoded service list, and a future multi-instance service works without
editing `template.sh`.

⚠️ `configure` keeps `--app` unconditionally. That is correct and not an
inconsistency: a non-multi-instance service can still hold per-app resources —
`postgresql` creates a per-app database in a shared instance.

### D3 — `init:` accepts a file or a directory, and order is part of the contract

A directory is concatenated in `LC_ALL=C sort` order — the tenant's files are
numbered (`001_…`, `050_…`) precisely so that order is meaningful, and DDL is
order-dependent.

- only `*.sql` is included; anything else in the directory is ignored, and the
  count of included files is logged so a typo'd extension is visible
- an empty or unreadable directory **fails**, and does not silently install
  nothing
- `{{ params.* }}` substitution happens on the concatenated content, so a param
  can appear in any file
- the file list and its order are printed before applying. A partial apply is
  what `configure-postgresql`'s rollback exists to undo, so which files were in
  play must be recoverable from the log

### D4 — `provides.services[]` stays canonical, and I am walking back what I told the tenant

On `urb-agents#159` I said the tenant's bare-list `provides:` was "the better
shape and I would rather change the parser". **Retracting that.** `provides` must
also express `stacks[]`, so it needs to be a mapping; a bare list cannot carry
the full vocabulary, and accepting both would mean two syntaxes for one concept
with no gain. The declaration needs one key added, and the docs should show the
canonical form.

---

## Tasks

### Phase 1 — the plan format (D1)

- [ ] 1.1 `_resolve_provides` writes `$plan_dir/<service_id>.conf` per service and
      emits only `<priority>|<service_id>`. `$plan_dir` is created under the
      template's fetch directory and removed with it
- [ ] 1.2 Read `config.database` and `config.init` into the conf file — behaviour
      unchanged, format changed. **Land this with no new fields**, so a
      regression here is separable from the new vocabulary
- [ ] 1.3 The executor and the "Deployment plan" preview both read the conf file.
      The preview keeps showing `deploy` vs `deploy + configure`
- [ ] 1.4 Stack-expanded services (`provides.stacks[]`) get a conf file with no
      config keys — deploy-only, as today

### Phase 2 — the missing `config:` fields (TPL-F4)

- [ ] 2.1 Read and pass `schemas` and `url_prefix` (PostgREST)
- [ ] 2.2 Read and pass `namespace` and `secret_name_prefix`. ⚠️ `configure.sh`
      **requires these two together** — validate in the template and fail with
      which one is missing, rather than letting `configure` reject it later with
      less context
- [ ] 2.3 `{{ params.* }}` substitution applies to every string field, not only
      `database` and `init`
- [ ] 2.4 Reject unknown `config:` keys with a message naming the supported set.
      A typo'd `url-prefix` must not be silently ignored — silence is the failure
      mode this investigation exists to document

### Phase 3 — multi-instance deploy (TPL-F3)

- [x] 3.1 Pass `--app "$app_name"` to `uis deploy` when `services.json` says the
      service is `multiInstance`
- [x] 3.1b 🔴 **The flag was only half of TPL-F3.** A multi-instance install still
      failed after 3.1, because the runner deployed *before* configuring and
      `088-setup-postgrest.yml` needs the per-app secret `configure` creates —
      it says so itself. Found end-to-end by the tester on `urb-agents#335`,
      after 1.6.8 had shipped claiming F3 closed. Deploy/configure order is now
      per-service: single-instance deploys then configures, multi-instance
      configures then deploys. **Lesson: the symptom had two causes and finding
      one made the claim look proven.**
- [ ] 3.2 A unit test asserting the flag is added for `postgrest` and omitted for
      `postgresql`, driven by fixture JSON rather than the live file

### Phase 4 — directory `init:` (TPL-F7)

- [ ] 4.1 Accept a directory; concatenate `*.sql` in `LC_ALL=C sort` order
- [ ] 4.2 Fail on an empty/unreadable directory, and on a path that is neither
      file nor directory
- [ ] 4.3 Log the count and the ordered file list before applying
- [ ] 4.4 Unit tests: single file unchanged; three files apply in numeric order;
      empty directory fails; non-`.sql` ignored and the count reflects it

### Phase 5 — docs and the declaration

- [ ] 5.1 Document the full `config:` vocabulary and the file-or-directory `init:`
      on the template page, with the canonical `provides.services[]` form (D4)
- [ ] 5.2 Update the parent investigation: F3, F4, F7 closed; F5 and F8 still open
- [ ] 5.3 ⚠️ Version bump in the same PR — `1.6.x` PATCH per WORKFLOW.md. **This
      was missed on the PostgREST fix and cost a release**; it is not optional

---

## Acceptance

- `uis template install <app>` on a declaration using `database`, `init` (a
  directory), `namespace`, `secret_name_prefix`, `schemas` and `url_prefix`
  provisions the database with migrations applied in order, writes the secret
  into the named namespace, and deploys a per-app PostgREST instance
- a declaration with a typo'd `config:` key fails naming the supported keys
- `namespace` without `secret_name_prefix` fails in the template, naming the
  missing one
- unit tests pass; `test-all` unaffected

🔴 **What this does NOT achieve, stated so nobody reads the acceptance as
"applications install now":** the Dagster code location is still a manual
`.uis.extend` edit plus `uis deploy dagster` (TPL-F5). So an install of the first
real application is **two commands, not one** — the template, then the code
location. That is a smaller gap than the four hand-sequenced steps it replaces,
and it is honest about what remains.

---

## Out of scope, with the cost of leaving it

| | Why not here | What it costs |
|---|---|---|
| **TPL-F5** — code location in `provides:` | Needs TPL-Q1/Q2 answered: whether a template may contribute to another service's `.uis.extend` file, and what removal does | The install stays two commands |
| **TPL-F8** — intra-application ordering | Deferred per TPL-F9: priority order already satisfies the first application once its schema exists at install time. Build it when a second application's real dependency can define the syntax | A future app with a genuine cross-surface dependency hits it |
| **TPL-Q3** — app-owned templates | A supply-chain decision, not a design one; needs the platform owner | Templates still come from the central registry |
| Handlers for the six stubbed `configure` services | [PLAN-cli-configure-retract-unimplemented](../backlog/PLAN-cli-configure-retract-unimplemented.md) retracts them instead | An app needing Redis or Mongo cannot be provisioned by a template |

---

## Testing

Unit tests cover the plan format, the `--app` decision and the `init:` directory
handling — all string-level, no cluster.

🔴 **The install itself needs a cluster and I do not test my own work.** The
end-to-end acceptance above is a tester task, and it should be run against a
declaration with a real multi-file `init:`, because the ordering guarantee in D3
is the part that fails silently if it is wrong: DDL applied out of order can
succeed and leave the wrong schema.
