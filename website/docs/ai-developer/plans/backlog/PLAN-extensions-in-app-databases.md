---
title: PLAN — the eight extensions reach no application database
sidebar_label: PLAN — extensions per app
---

# Plan: make the advertised Postgres extensions reachable from an application

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog — proposal, decision is Terje's

🔵 Filed 2026-09-29 from `urb-agents#1741`, where `atlas` asked whether PostGIS was available before choosing how to model kommune geometry. Answering it properly turned up a gap that is not about PostGIS.

## What is measured

| | |
|---|---|
| the image ships eight extensions | `042-database-postgresql-config.yaml` pins `bitnami/postgresql@sha256:be1c305…` and lists PostGIS 3.6.2, pgvector 0.8.2, hstore, ltree, uuid-ossp, pg_trgm, btree_gin, pgcrypto |
| the `CREATE EXTENSION` statements live in `initdb.scripts` | they run **once**, against a fresh data directory |
| `auth.database` is **not set** | so they run against the **`postgres`** database |
| `configure` runs `CREATE DATABASE "<db>" OWNER "<role>"` with **no `TEMPLATE`** | so an app database is cloned from `template1`, which never received them |

🔴 **So the eight extensions exist in `postgres` and in no application database at all.** Not one database that `uis configure postgresql` has created has any of them.

⚠️ And the application cannot add one: `_pg_apply_init_file` runs `psql -U <app role>`, and `CREATE EXTENSION` needs superuser (`urb-agents#1446`). There is no flag that asks UIS to create one.

## Why this is the usual defect in documentation form

[`services/databases/index.md`](../../../services/databases/index.md) says the image *"includes 8 pre-built extensions: pgvector (AI embeddings), PostGIS (geospatial)…"*. Every word is true. It also reads, to someone choosing a data model, as *"your database can use these"* — and that is false.

🔵 `atlas` drew the distinction itself before asking — *"404 only proves it is not exposed, not that it is absent"* — and the same distinction applies one level down: **available in the image** is not **created in your database**. The documentation does not draw it anywhere.

## Proposal

- [ ] 1.1 `uis configure postgresql --extensions <list>` — create named extensions **as admin**, in the database just created, after `CREATE DATABASE`
- [ ] 1.2 🔴 **Accept only the extensions the pinned image ships.** Anything else is refused by name, listing what is available — never attempted and reported as succeeding
- [ ] 1.3 Idempotent (`IF NOT EXISTS`), and applied on the database-already-exists path too — [both tails](./INVESTIGATE-provisioning-declaration.md), which this file has been caught by twice
- [ ] 1.4 Run **before** `--init-file`, so an init file can use the types
- [ ] 1.5 Report which were created in the `--json` output, so a caller can tell
- [ ] 1.6 A test that the accepted list matches what the image actually contains — in both directions, the shape that caught the `SCRIPT_CONFIGURABLE` drift

### Why not `template1`

Adding `\c template1` to the initdb script would give every future database all eight for free. Rejected as the primary fix:

- ⚠️ **It only takes effect on a fresh data directory**, so every existing cluster — including the one everything is tested on — would be unchanged, and the fix would appear to work while changing nothing for anyone who already has UIS.
- It gives every application all eight whether or not it wants them, including PostGIS.

🔵 Worth doing *as well*, as the default for new clusters, but it cannot be the answer on its own.

## Documentation, independent of the decision

- [ ] 2.1 Say plainly in `services/databases/index.md` and `postgresql.md` that the extensions are **available in the image** and **created only in the `postgres` database**
- [ ] 2.2 Say that an application database has none of them, and what to do about it
- [ ] 2.3 Keep the `configure --init-file` note that it runs as the app role and cannot `CREATE EXTENSION`

⚠️ These three are worth doing whether or not 1.x is built: today a developer reads the list and models against it.
