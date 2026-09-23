---
title: PLAN — an application should declare the extensions it needs
sidebar_label: PLAN — declared extensions
---

# PLAN — an application should declare the extensions it needs

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

🔵 Filed 2026-09-24 from `urb-agents#1446`. An application needed `pg_trgm` and could not install it; the request arrived as "please run this by hand on production".

**Goal**: an application declares the PostgreSQL extensions it needs, and `uis configure postgresql` installs them — from an allowlist — so a rebuild reproduces them.

## The three facts that shape it

**1. The extension is present and simply not installed.** `pg_available_extensions` lists `pg_trgm 1.6` with an empty `installed_version`. Nothing needs adding to the image.

**2. The application role cannot install it.** `rolsuper f`, `rolcreatedb f`, `rolcreaterole f`. `CREATE EXTENSION` needs more than the app has, and that is correct — an application should not be superuser.

🔴 **3. And the obvious workaround does not work either.** `configure --init-file` looks like the place to put it, and it is not: `_pg_apply_init_file` runs `psql -U "$user"` as **the application role**, so `CREATE EXTENSION` fails there for exactly the same reason. Anyone who tries the init file first will lose an hour to it.

✅ **But `configure` already has the channel it needs.** `_pg_exec` runs as `PG_ADMIN_USER` — `postgres`. So this is a declaration plus a few lines, not a new subsystem.

## 🔴 It must be an allowlist, and that is the whole design risk

An extension can run arbitrary C inside the database server. **"An application declares an extension and the platform installs it as superuser" is a privilege-escalation path**, and the application's declaration arrives from an OCI artifact fetched out of a registry.

🔵 This repository already has the precedent and the reasoning: the template allowlist exists because *"a merged typo in the catalogue must not be able to point a platform at a stranger's SQL"*. The same argument applies with more force here, because the payload runs as `postgres`.

So: a short list of extensions UIS will install, shipped as a default and extensible per-installation in `.uis.extend/` — the same relationship as the template allowlist. **An application asking for something outside it is refused, by name, with the list.**

## Shape

- [ ] `extensions:` in the application's postgresql config block, a list of names
- [ ] An allowlist, defaulting to extensions that ship in the image and carry no known escalation (`pg_trgm`, `btree_gin`, `unaccent`), extensible in `.uis.extend/`
- [ ] `configure postgresql` installs the declared-and-allowed set **as the admin role**, with `create extension if not exists`, **before** the init file — the application's own SQL may depend on them
- [ ] ⚠️ A refusal that names the extension and the allowlist, not a silent skip: a missing extension surfaces later as a slow query or a syntax error, never as "the extension is missing"
- [ ] A test asserting an unlisted extension is refused, with a positive control so an empty allowlist cannot pass vacuously

## ⚠️ Until it exists, a hand-run `CREATE EXTENSION` is not free

It works and it is the right unblock. **But UIS provisions this database, so an extension installed by hand is not in anything that rebuilds it** — the next rebuild silently lacks it, and the symptom is a slow query rather than an error.

🔵 That is the same shape as every hand-built thing this fleet has found: correct today, invisible tomorrow, and discovered by someone measuring a page that got slow again. **If it is run by hand, it should be recorded where the rebuild path can see it.**

## Not in scope

The larger lever on the same table — lowering `toast_tuple_target` so a wide column moves out of line — is a storage change to a multi-gigabyte table requiring a full refresh. **It is a different decision with a different owner**, and the index is not a substitute for it: the index solves one query shape, the heap size is the general problem.

## Related

- `urb-agents#1446` — the request, the measurements, and the explicit refusal to work around the privilege
