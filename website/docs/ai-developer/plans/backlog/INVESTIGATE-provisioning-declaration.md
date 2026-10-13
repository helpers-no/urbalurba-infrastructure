---
title: INVESTIGATE — a declarative Provision applied by ArgoCD
sidebar_label: INVESTIGATE — Provision declaration
---

# Investigate: a declarative `Provision`, applied by ArgoCD, for every UIS service

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog — evaluation only, decision is the maintainer's

🔵 Filed 2026-09-29 from `urb-agents#1695`, a proposal from Terje via `urb-agents-console`, following #1677 and #1692.

**The intent, in Terje's words:** a developer copies the files describing what they want into their repo and deploys; provisioning happens **when ArgoCD syncs after CI**, not in a command someone runs — and it must work for **every** UIS service, not only Postgres.

## The proposal

ArgoCD applies manifests; it cannot create a database. So something in the cluster must turn an applied declaration into a provisioned service. Two shapes were considered and the first was rejected by its author:

| shape | verdict |
|---|---|
| a hook `Job` in each app's manifests | ❌ runs in the app's namespace, so it needs admin credentials there |
| **a UIS provisioner** in UIS's namespace, watching for declarations and calling the service's existing handler | ✅ proposed |

A `Provision` custom resource at sync-wave `-1`, an ArgoCD health check holding the sync until `status: Ready`, and one **handler** per service — `configure-postgresql.sh` and PostgREST today, others joining later.

## 🔴 The premise the shape rests on is false — settled 2026-09-29

The argument for the provisioner over the hook Job is that **only UIS's namespace holds service admin credentials.** When this was filed that needed a cluster to check. It does not: the whole chain is in this repository, in the secrets template.

```
DEFAULT_DATABASE_PASSWORD                    00-common-values.env.template
  └─> PGPASSWORD                             same file, line 140
      └─> urbalurba-secrets/default:PGPASSWORD    00-master-secrets.yml.template:76
          └─> --set auth.postgresPassword=…       040-database-postgresql.yml:66
```

That last line is the **Postgres superuser**. And the same `${PGPASSWORD}` value is written into four other namespaces under different key names:

| namespace | key | value |
|---|---|---|
| `unity-catalog` | `UNITY_CATALOG_DATABASE_PASSWORD` | `${PGPASSWORD}` |
| `unity-catalog` | `UNITY_CATALOG_DATABASE_URL` | `postgresql://postgres:${PGPASSWORD}@…` |
| `openmetadata` | `OPENMETADATA_DATABASE_PASSWORD` | `${PGPASSWORD}` |
| `openmetadata` | `OPENMETADATA_DATABASE_URL` | `postgresql://postgres:${PGPASSWORD}@…` |
| `nextcloud` | `NEXTCLOUD_DATABASE_PASSWORD` | `${PGPASSWORD}` |
| `authentik` | `AUTHENTIK_POSTGRESQL__PASSWORD` | `${PGPASSWORD}` |

⚠️ The filing guessed at "the same key name in two namespaces". That was wrong in detail and understated in substance: **different key names, the same value** — and two of them ship it as a ready-made superuser connection string.

🔴 **So the hook Job was rejected for a property UIS does not have.** Any workload in those four namespaces can already read the Postgres superuser password from its own namespace. A hook Job in `unity-catalog` needing admin credentials is not a new exposure there; it is the exposure that already exists.

**This does not make the provisioner wrong.** It moves what it is *for*. It is not a security improvement today — it is a **workflow** change (provisioning happens on ArgoCD sync rather than in a command someone runs), and it becomes a security improvement only after [item 4](../../../contributors/rules/application-deployment.md) splits the shared Secret. Those are two different justifications with two different urgencies, and only the second was in the proposal.

## Sequence, if it is built

1. **Item 3** — retract `SCRIPT_CONFIGURABLE` where no handler exists. **Eight services declare it; two have handlers.** A provisioner that reads that flag to decide what it can fulfil inherits the false advertisement. Prerequisite, not a tidy-up.
2. **Item 4** — per-workload named secrets. This is what makes the provisioner's security claim **true**; without it the mechanism is clean and the blast radius is unchanged. 🔴 **Now measured, not suspected** — see the section above: four namespaces hold the Postgres superuser password today.
3. **Then** the provisioner has something real to protect.

## ⚠️ The cost that was not in the estimate

The proposal argues it is smaller than a NAIS-style `Application` type because it reuses handlers UIS already runs. That part is fair. What it leaves out is that **UIS has never shipped anything of this kind**:

| | today | with a provisioner |
|---|---|---|
| container images UIS builds | **one** (`Dockerfile.uis-provision-host`) | two — a second build, release cadence and digest-verification surface |
| CRDs UIS owns | **none** | the first |
| long-running control-plane components UIS owns | **none** | the first, with RBAC, upgrades and a failure mode of its own |

🔴 **And its failure mode is new in kind.** Everything UIS ships today either ran to completion or did not. A controller is wrong in *reconciliation* — under concurrency, partial failure, and restart — which is the hardest class to find. The maintainer has no cluster and cannot exercise it; every release is exercised by others afterwards. That is workable for a script and a poor fit for a reconcile loop.

**Verdict: still L**, and better argued than the `Application` type it replaces. Not wrong for UIS.

## Answers to the specific questions

**CRD or ConfigMap — CRD.** `status` and an ArgoCD health check are the whole point, and a ConfigMap has no schema, so a typo is silent. That is the `requires` defect of 1.6.24 again: a field nothing validates looks supported and is not.

**Deletion — retain, and make dropping harder than a field flip.** 🔴 UIS **cannot back up what it deploys** ([INVESTIGATE-system-backup-and-scheduling](./INVESTIGATE-system-backup-and-scheduling.md)). A `Provision` that drops a database when it leaves git turns a revert into unrecoverable data loss.

**Trust — the allowlist is the wrong control here.** The init SQL is already bounded: `_pg_apply_init_file` runs `psql` **as the application role**, not as admin, which is why `CREATE EXTENSION` fails there (`urb-agents#1446`). The real boundary is **who may create a `Provision`** in a namespace — a compromised workload that can create one is asking a component holding admin credentials to act for it. That is RBAC on the CRD, not an allowlist on the SQL.

**Bootstrap — order is CRD, then secrets, then provisioner, then applications.** No circularity: the provisioner needs no database of its own. ⚠️ But an app whose `Provision` is applied before the CRD exists fails its sync with an unhelpful error, so the CRD belongs with the platform install and not with the first app that wants one.

## Related

- [application-deployment](../../../contributors/rules/application-deployment.md) — items 3, 4 and 5, and the two-path fork from `urb-agents#1692`
- [ANALYSIS-nais-uis](./ANALYSIS-nais-uis.md) §4 — the thirteen-item ranking this is measured against
- [INVESTIGATE-secrets-dev-to-production](./INVESTIGATE-secrets-dev-to-production.md) Part 4 — why item 4 precedes the vault question
