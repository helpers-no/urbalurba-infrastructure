# Plan: UIS assumes its Postgres Service is its own, and cannot tell if it is not

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Backlog

**Goal**: UIS knows whether the Postgres server it is about to write to is a
database it owns or a shared server it is a guest on — and refuses destructive
operations on the second, rather than discovering the difference afterwards.

**Found**: reviewing a request to reinstall an application onto an existing
installation. Nothing is broken today; the hazard is created by the plan that
fixes a different gap, which is why it is filed before that plan is built.

---

## The assumption, in three lines of code

```
PG_ADMIN_USER="postgres"                                 # configure-postgresql.sh:17
PG_CLUSTER_HOST="postgresql.default.svc.cluster.local"   # configure-postgresql.sh:21
PG_CLUSTER_HOST="postgresql.default.svc.cluster.local"   # configure-postgrest.sh:40
```

Hardcoded, with **no override** — no flag, no environment variable, no lookup.
Every database operation UIS performs runs as the **superuser** against whatever
answers on that name, and the admin credential is read from `urbalurba-secrets`
in `default`.

On a laptop that is exactly right: the Service fronts a Postgres this
installation created and nothing else uses it.

🔴 **But the Service name is a name, not a guarantee.** A `Service` in `default`
called `postgresql` can equally front a database server outside the cluster that
several installations share. UIS cannot distinguish the two, and behaves
identically in both: superuser, on a name, with the scope of any destructive
operation bounded only by the identifier it was handed.

## Why this is filed now and not when it bites

Today the blast radius is genuinely small, because **no UIS command drops a
database.** That is not caution, it is the gap recorded in
[PLAN-cli-configure-postgresql-purge](./PLAN-cli-configure-postgresql-purge.md).

So the two plans are coupled in one direction:

> **The plan that closes the purge gap is the plan that arms this one.**

Building `configure postgresql --purge` gives UIS, for the first time, a
superuser path that destroys a database chosen by name, on a server it has never
established that it owns. That is the moment the assumption above stops being
harmless — and it is the moment nobody will be looking at it, because the purge
work will be about purging.

⚠️ **This is the same shape as every defect this quarter**: a guard and the thing
it guards written in the same breath, with only the guarded thing exercised. The
countermeasure is not care later. It is filing the guard *before* the thing, so
the purge plan cannot be picked up without meeting it.

## What needs deciding

1. **Can UIS establish ownership at all, and how?** Candidates, none obviously
   right: a marker table or database UIS creates on first configure and checks
   thereafter; a label on the Service; an explicit `--i-know-this-is-shared`
   acknowledgement recorded in `.uis.extend/`. A marker is the only one that
   cannot be forged by a well-meaning operator recreating a manifest.
2. **What does UIS do when it cannot establish ownership?** Refuse the
   destructive path, or perform it after an unmissable prompt naming every
   database on the server? Enumerating the neighbours is itself informative:
   an operator who sees six unfamiliar databases has learned the thing UIS
   could not.
3. **Should the host be overridable at all?** It is hardcoded twice today. Making
   it configurable is a small change that makes the shared case *easier to reach*
   — so it should land with the ownership check, not before it.
4. **Does the superuser credential need narrowing?** UIS uses `postgres` for work
   that mostly needs `CREATEDB` and `CREATEROLE`. A lesser role would bound the
   damage without any of the detection above, and may be the cheapest real
   mitigation.

## Tasks

- [ ] 1.1 Decide question 1 — how ownership is established, if it can be
- [ ] 1.2 Decide question 2 — refuse, or prompt naming the neighbours
- [ ] 1.3 Implement the check and make every destructive postgresql path consult
      it, not just the new one
- [ ] 1.4 Decide question 4 separately; it stands on its own even if 1.1 stalls
- [ ] 1.5 Cross-reference from the purge plan so it cannot be built past this
- [ ] 1.6 Version bump

## Acceptance

- a destructive `configure postgresql` path on a server UIS cannot show it owns
  either refuses, or prints every database on that server before prompting
- the non-destructive paths (`create database`, `create role`, apply init) are
  **unchanged** — a guest is perfectly entitled to its own database, and making
  install harder would be fixing the wrong thing
- ⚠️ the check is exercised by a test that runs on a server with a database UIS
  did not create. A test where every database is UIS's own tests the branch that
  was always going to pass

## The lesson this plan carries

**A name is not a guarantee of ownership**, and the code that hardcodes a name
is not where you find that out. UIS has been correct here for its whole life by
the accident of only ever running where the assumption held. That is not the same
as being right, and the difference only becomes visible when a destructive verb
arrives.
