---
title: PLAN — the eight extensions reach no application database
sidebar_label: PLAN — extensions per app
---

# Plan: make the advertised Postgres extensions reachable from an application

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Done in 1.6.178 — Terje decided against the proposal, and for something simpler

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

## Terje's decision, 2026-09-29

> *"i want the extensions activated so that they can be used by anyone that want the functionality."*

🔵 **Not the `--extensions <list>` flag this plan proposed.** That made every application ask for what the platform already had, which is the same shape as the problem: a capability present but out of reach. The decision is that all eight are simply **on, everywhere**.

## What was built

Two mechanisms, deliberately overlapping, because neither covers everything alone:

| | covers | does not cover |
|---|---|---|
| **`040-database-postgresql.yml` seeds `template1`** | every database created **after** the deploy, by anything — `configure`, a service's own chart, a developer's `CREATE DATABASE` | databases that already exist |
| **`configure` activates them as admin** | the database it creates, **and** an existing one on a re-run | databases nothing ever calls `configure` for |

⚠️ **`template1` alone was rejected as the whole answer** for the reason given below: it takes effect on a fresh data directory only if done at initdb. Doing it in the deploy playbook instead — idempotent, on every `uis deploy postgresql` — is what makes it reach a cluster that already exists.

- [x] The list lives in **one file**, `provision-host/uis/lib/postgres-extensions.conf`, read by both the playbook and the handler
- [x] 🔴 The Helm values file cannot read it, so `test-extensions-are-one-list.sh` asserts the two agree — the drift this design would otherwise invite
- [x] Activated **before** `--init-file`, so init SQL can use the types
- [x] Both tails of `configure-postgresql.sh`, counted by the test rather than checked once
- [x] `ON_ERROR_STOP=on`, and a failure **fails the command** on all four report paths
- [x] Refuses rather than guessing if the list file is unreadable

### Still true, and worth saying

An application **cannot** add a ninth extension itself: `--init-file` runs as the application role and `CREATE EXTENSION` needs superuser (`urb-agents#1446`). UIS now does the eight on its behalf. Anything beyond them is still a platform request — and that is the right place for that boundary, because the eight are what the pinned image ships and can be tested against.

🔴 **A database created before 1.6.178 does not have them.** Re-running `uis configure postgresql` for that application activates them, because the handler covers the already-exists path. Nothing retro-fits a database that `configure` never made.

## The alternative that was rejected, and why it is recorded

`initdb.scripts` could have been pointed at `template1` instead of the default database — a one-line change in the chart values.

🔴 **It would have appeared to work and changed nothing for anyone who already runs UIS.** `initdb` runs once, on a fresh data directory. Every existing cluster — including the one every release is tested on — would have been untouched, while the diff looked correct and the tests passed. That is the defect class this repository spends most of its time on, and it would have been introduced by the fix for it.

⚠️ Recorded because it is the obvious change, and the next person to look at this will think of it first.

## What this costs

Every database now carries eight extensions whether it uses them or not — PostGIS is the substantial one, several thousand catalogue rows.

🔵 Judged worth it: UIS's premise is that a developer gets a working datacentre without filing requests ([Principle 0](../../../contributors/rules/kubernetes-deployment.md)), and per-database opt-in would have meant every application discovering the list, choosing from it, and getting the flag right. ⚠️ If the footprint ever matters, the place to revisit is the list — not the mechanism.

## Documentation, independent of the decision

- [ ] 2.1 Say plainly in `services/databases/index.md` and `postgresql.md` that the extensions are **available in the image** and **created only in the `postgres` database**
- [ ] 2.2 Say that an application database has none of them, and what to do about it
- [ ] 2.3 Keep the `configure --init-file` note that it runs as the app role and cannot `CREATE EXTENSION`

⚠️ These three are worth doing whether or not 1.x is built: today a developer reads the list and models against it.
