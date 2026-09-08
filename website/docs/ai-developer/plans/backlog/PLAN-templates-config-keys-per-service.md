# Plan: reject a valid `config:` key on the wrong service, at parse time

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Backlog

**Goal**: A template declaring a supported `config:` key on a service that does
not accept it fails when the declaration is parsed, naming the service and the
key — not after the first service has already been deployed.

**Found**: imac, `urb-agents#335`, while testing templates-001 end to end. Its
first fixture put `namespace` and `secret_name_prefix` on `postgrest`.

**Related**: [PLAN-templates-001](../active/PLAN-templates-001-multi-instance-deploy.md)
introduced `TEMPLATE_CONFIG_KEYS` and its unknown-key rejection, which this
extends from "is this a key at all" to "is this a key *here*".

---

## The problem

`TEMPLATE_CONFIG_KEYS` is one flat list, checked identically for every service:

```
database init schemas url_prefix namespace secret_name_prefix
```

`_write_service_conf` accepts any of them for any service, and the runner then
appends `--namespace`/`--secret-name-prefix` whenever present. But
`configure postgrest` refuses those two, correctly and with a good message:

> `--namespace and --secret-name-prefix are not supported for postgrest.`
> `PostgREST manages its own namespace (postgrest) and secret name (<app>-postgrest).`

So a template with a valid key on the wrong service passes validation, passes
the preview, **deploys postgresql**, and only then dies.

⚠️ **Severity dropped once `set -e` was fixed** (1.6.11): that failure used to
print *nothing at all*. It now surfaces `configure`'s own message, which is most
of the harm gone. What remains is that it fails **late**, after a cluster change.

## Why this was not fixed in 1.6.11

The obvious fix — a per-service key table in `template.sh` — creates **a second
list that must agree with `configure`'s own validation**. That is the exact
hazard this repository has hit three times:

- `ansible/**` missing from `test-uis.yml`'s paths (a hardcoded pod name shipped green)
- `version.txt` missing from `docs.yml`'s paths (the navbar badge stayed a release behind)
- the shipping paths missing from the version-bump guard's own trigger, caught pre-merge

Adding a fourth deliberately, to fix a late error that is now merely late rather
than silent, is the wrong trade. **The right fix asks the service, rather than
keeping a copy of its rules.**

## Options

| | Approach | Cost | Risk |
|---|---|---|---|
| **A** | `uis configure <svc> --validate-only` — parse and validate args, touch nothing, exit non-zero with the same JSON error | one flag per handler, but the validation already exists and already emits the right message | handlers must guarantee no side effects before the check; needs auditing per handler |
| **B** | Declare accepted keys in service metadata (`SCRIPT_CONFIGURE_KEYS`), generated into `services.json` | data-driven, no second prose list | still two places that must agree — metadata and handler — just closer together |
| **C** | Per-service table in `template.sh` | smallest diff | the fourth two-lists-that-must-agree; rejected above |

**A is preferred**: it makes `configure` the single authority, which is what it
already is at runtime. The work is a `--validate-only` that returns before any
mutation, plus a template-layer call per configured service before the plan runs.

⚠️ **A has a real prerequisite**: `configure`'s handlers must be shown to do
nothing before argument validation. `configure-postgrest.sh` rejects at usage
phase (`:369`), which looks safe; `configure-postgresql.sh` needs the same check.
That audit is the first task, and if it fails, B is the fallback.

## Tasks

- [ ] 1.1 Audit both handlers: does anything mutate before argument validation?
      Record the answer per handler; it decides A vs B
- [ ] 1.2 Add `--validate-only` to `configure`: parse, validate, emit the same
      JSON on failure, exit 0 on success, touch nothing
- [ ] 1.3 Call it per configured service in `_resolve_provides`, before the plan
      is printed, so a bad declaration fails before any deploy
- [ ] 1.4 The error must name the service, the key and the reason — `configure`
      already produces this; pass it through rather than rewording it
- [ ] 1.5 Unit test with the exact fixture that found it: `namespace` on
      `postgrest` fails at parse time, and the same key on `postgresql` passes
- [ ] 1.6 Version bump in the same PR

## Acceptance

- a template declaring `namespace` on `postgrest` fails **before** any service is
  deployed, quoting `configure`'s own message
- the same template with those keys on `postgresql` installs
- no per-service key list exists in `template.sh`

## Out of scope

Whether `configure` should accept `--namespace` for PostgREST at all. It should
not — PostgREST owns its namespace and secret name, and that is a decided design
([INVESTIGATE-postgrest](../completed/INVESTIGATE-postgrest.md) Decisions #3, #16,
#19). This plan is about *where* the refusal happens, not whether.
