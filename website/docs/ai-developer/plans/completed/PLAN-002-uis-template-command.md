# Plan: UIS Template Command + PostgreSQL Demo Template

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Completed

**Goal**: Build the `uis template` command in UIS and the first UIS stack template (PostgreSQL demo) in TMP. The two together validate the end-to-end template flow.

**Last Updated**: 2026-04-05

**Investigation**: [INVESTIGATE-templates-first-uis-template.md](../backlog/INVESTIGATE-templates-first-uis-template.md) — decisions on template selection and format

**Specs**: `helpers-no/dev-templates` → `INVESTIGATE-unified-template-system.md` — `template-info.yaml` format (especially `provides` with stack refs per 26MSG and per-service config per 28MSG)

**Dependencies**:
- [PLAN-001-uis-configure-expose.md](../completed/PLAN-001-uis-configure-expose.md) — `uis configure` + `uis expose` (completed, shipped in urbalurba-infrastructure#116)
- TMP template registry is published — confirmed (DCT Phase A merged, registry fetchable)

**Priority**: Medium

---

## Overview

Two deliverables in one plan:

1. **`uis template` command** (in UIS repo) — fetches the TMP template registry, filters `context: uis`, shows menu, sparse-checkouts selected template, reads `template-info.yaml`, resolves `provides` (stacks + services), deploys and configures each service.

2. **PostgreSQL Demo template** (in TMP repo, via PR) — minimal stack template that deploys PostgreSQL and creates a sample `tasks` table with seed data. Validates the full pipeline with minimum surface area.

Both are needed to validate each other — the command needs a template to run, the template needs a command to run it.

---

## Phase 1: `uis template` command — registry fetch and browse

### Tasks

- [ ] 1.1 Create `provision-host/uis/lib/template.sh` with registry fetching:
  - Fetch `template-registry.json` from primary URL: `https://raw.githubusercontent.com/helpers-no/dev-templates/main/website/src/data/template-registry.json`
  - Fallback URL: `https://tmp.sovereignsky.no/data/template-registry.json`
  - Cache locally at `/tmp/uis-template-registry.json` with 1-hour TTL
  - Filter by `context: uis`

- [ ] 1.2 Add `template` subcommand to `uis-cli.sh`:
  ```
  uis template              # Interactive menu (dialog/fzf)
  uis template list         # List available UIS templates
  uis template info <id>    # Show template details
  uis template install <id> # Install a specific template
  ```

- [ ] 1.3 Interactive menu (using `dialog` like `dev-template` does, or simple numbered selection):
  - Show categories (filtered by context: uis) with emoji + name
  - Show templates within selected category
  - Show template summary + confirm installation

### Validation

- `uis template list` shows UIS templates from the registry
- `uis template info postgresql-demo` prints name, description, summary, services
- Registry cache works (second call is fast, no network)

---

## Phase 2: `uis template install` — fetch template and deploy

### Tasks

- [ ] 2.1 Sparse-checkout the selected template folder from the TMP repo:
  - Clone `helpers-no/dev-templates` to `/tmp/uis-templates/` (shallow, sparse)
  - Checkout only the selected template folder (e.g., `uis-stack-templates/postgresql-demo/`)
  - Read `template-info.yaml` from the checked-out folder

- [ ] 2.2 Validate `template-info.yaml`:
  - `context` matches `uis`
  - `install_type: stack`
  - `provides` is present
  - All referenced service IDs exist in `services.json` with `configurable: true` for services with config
  - All referenced stack IDs exist in `stacks.json`
  - All referenced init files exist in the template folder

- [ ] 2.3 Resolve `provides` into a deployment plan:
  - Expand stacks via `stacks.json` → list of services
  - Collect services from `services` list (both plain strings and `service+config` objects)
  - Deduplicate
  - Sort by `priority` field from `services.json` (lower = first)
  - Result: ordered list of `{service_id, config?}` entries

- [ ] 2.4 Substitute `{{ params.* }}` references:
  - Read `params` from `template-info.yaml`
  - If any param is unset and has no default, prompt the user (or accept `--param key=value` flags)
  - Substitute in `config.database`, `config.init`, etc.

- [ ] 2.5 Execute the deployment plan:
  - For each entry: call `uis deploy <service>` (idempotent, skips if running)
  - For entries with config: call `uis configure <service> --app <name> --database <db> --init-file <path> --json`
  - Collect all JSON responses

- [ ] 2.6 Report results to user:
  - Show what was deployed and configured
  - Show connection details for each configured service
  - Print the template's README content (usage instructions)

### Validation

- `uis template install postgresql-demo` deploys PostgreSQL and applies the init file
- Returns JSON with connection details
- Idempotent: second run returns `already_configured` for services already set up

---

## Phase 3: PostgreSQL Demo template (PR to TMP)

### Tasks

- [ ] 3.1 Create PR to `helpers-no/dev-templates` adding:
  ```
  uis-stack-templates/
  ├── template-categories.yaml          # context=uis, defines DEMO + ORGANISATION_STACK
  └── postgresql-demo/
      ├── template-info.yaml
      ├── README-postgresql-demo.md
      ├── postgresql-demo-logo.svg
      └── config/
          └── init-database.sql
  ```

- [ ] 3.2 `template-categories.yaml`:
  ```yaml
  context: uis
  name: Infrastructure Stacks
  description: Multi-service infrastructure compositions deployed via UIS
  order: 0
  emoji: "🏢"
  categories:
    - id: DEMO
      order: 0
      name: Demo Stacks
      description: Minimal demonstration templates for getting started with UIS
      tags: demo getting-started
      logo: demo-stacks-logo.svg
      emoji: "🎯"
  ```

- [ ] 3.3 `template-info.yaml`:
  ```yaml
  id: postgresql-demo
  version: "1.0.0"
  name: PostgreSQL Demo
  description: Deploys PostgreSQL and creates a sample database with seed data
  category: DEMO
  install_type: stack
  abstract: >
    A minimal UIS template that deploys PostgreSQL and creates a sample
    tasks table with seed data.
  tools: ""
  readme: README-postgresql-demo.md
  tags:
    - postgresql
    - database
    - demo
    - getting-started
  logo: postgresql-demo-logo.svg
  website: ""
  docs: https://github.com/helpers-no/dev-templates/tree/main/uis-stack-templates/postgresql-demo
  summary: >
    A minimal demonstration template that deploys PostgreSQL to the UIS
    cluster and creates a sample database with a tasks table and seed data.
    Shows the uis template flow from registry to deployed, configured service.
  related: []
  params:
    app_name: "demo-app"
    database_name: "demo_db"
  provides:
    services:
      - service: postgresql
        config:
          database: "{{ params.database_name }}"
          init: "config/init-database.sql"
  ```

- [ ] 3.4 `config/init-database.sql`:
  ```sql
  -- PostgreSQL Demo — sample schema with seed data
  CREATE TABLE IF NOT EXISTS tasks (
      id SERIAL PRIMARY KEY,
      title VARCHAR(255) NOT NULL,
      status VARCHAR(20) DEFAULT 'pending',
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
  );

  INSERT INTO tasks (title, status) VALUES
      ('First task', 'done'),
      ('Second task', 'pending'),
      ('Third task', 'pending')
  ON CONFLICT DO NOTHING;
  ```

- [ ] 3.5 `README-postgresql-demo.md`:
  - Describes what the template deploys
  - Explains the schema
  - Shows how to query the database from DCT devcontainer

### Validation

- PR merged to TMP
- Registry generator picks up the new template
- `template-registry.json` includes `postgresql-demo` with `context: uis`

---

## Phase 4: End-to-end test

### Tasks

- [ ] 4.1 Local integration test:
  - Run `uis template install postgresql-demo` from provision-host
  - Verify PostgreSQL deploys
  - Verify database `demo_db` is created
  - Verify `tasks` table exists with 3 rows
  - Verify JSON output has valid connection details

- [ ] 4.2 Add integration test to `provision-host/uis/tests/deploy/test-template-integration.sh`

- [ ] 4.3 Document in `website/docs/developing/uis-templates.md`

### Validation

- End-to-end test passes
- Documentation explains how to use `uis template`

---

## Files Changed (UIS repo)

| File | Change |
|------|--------|
| `provision-host/uis/lib/template.sh` | New — registry fetch, parse, install logic |
| `provision-host/uis/manage/uis-cli.sh` | Add `template` subcommand routing, help text |
| `provision-host/uis/tests/deploy/test-template-integration.sh` | New — E2E test |
| `website/docs/developing/uis-templates.md` | New — user documentation |

## Files Changed (TMP repo — separate PR)

| File | Change |
|------|--------|
| `uis-stack-templates/template-categories.yaml` | New — defines DEMO category |
| `uis-stack-templates/postgresql-demo/template-info.yaml` | New — template metadata |
| `uis-stack-templates/postgresql-demo/README-postgresql-demo.md` | New — user docs |
| `uis-stack-templates/postgresql-demo/config/init-database.sql` | New — schema + seed |
| `uis-stack-templates/postgresql-demo/postgresql-demo-logo.svg` | New — logo |

## References

- PLAN-001-uis-configure-expose — prerequisite commands
- INVESTIGATE-templates-first-uis-template — template selection rationale
- TMP `INVESTIGATE-unified-template-system.md` — format spec (26MSG stack refs, 28MSG per-service config, 29MSG format finalized)
