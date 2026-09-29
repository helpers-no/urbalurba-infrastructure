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

## 🔴 The premise the shape rests on is not established

The argument for the provisioner over the hook Job is that **only UIS's namespace holds service admin credentials.** That needs checking before it is designed around.

What is measured in this repository:

- `_pg_get_admin_password()` reads **`urbalurba-secrets` → `PGPASSWORD`** in namespace **`default`**. That is the Postgres admin credential.
- `ANALYSIS-nais-uis` (2026-08-15) measured `urbalurba-secrets` as **one Secret shape replicated across 13 namespaces, 54 keys**, and recorded the blast radius as *"every workload in 13 namespaces"*.
- `320-unity-catalog-deployment.yaml` reads **`PGPASSWORD` from `urbalurba-secrets` in its own namespace** — the same Secret name and the same key name as the admin credential.

⚠️ **The same key name in two namespaces is not proof the values match**, and the secrets manifest lives outside this repository, so it cannot be settled here. **One command settles it:**

```bash
kubectl get secret urbalurba-secrets -n default        -o jsonpath='{.data.PGPASSWORD}'
kubectl get secret urbalurba-secrets -n unity-catalog  -o jsonpath='{.data.PGPASSWORD}'
```

🔴 **If those match, the hook Job was rejected for a property UIS does not yet have** — every workload in those namespaces can already reach Postgres as admin, and the provisioner protects nothing until [item 4](../../../contributors/rules/application-deployment.md) splits the shared Secret.

## Sequence, if it is built

1. **Item 3** — retract `SCRIPT_CONFIGURABLE` where no handler exists. **Eight services declare it; two have handlers.** A provisioner that reads that flag to decide what it can fulfil inherits the false advertisement. Prerequisite, not a tidy-up.
2. **Item 4** — per-workload named secrets. This is what makes the provisioner's security claim **true**; without it the mechanism is clean and the blast radius is unchanged.
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
