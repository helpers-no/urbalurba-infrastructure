---
title: INVESTIGATE — Loki's object store is pointed at MinIO, outside UIS's own config
sidebar_label: INVESTIGATE — Loki/Tempo on MinIO
---

# Investigate: a live Loki (and possibly Tempo) instance stores data in MinIO, which UIS does not ship pointed there and cannot reinstall

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog — not started. Filed to not lose the thread, not because a UIS-side fix is known to be needed.

🔵 Filed 2026-10-01 at Terje's instruction, after it came up twice in passing while replacing MinIO with Garage (`urb-agents#1795`/`#1801`/`#1802`) and was never written down.

## What is measured

**UIS's own shipped config does not point Loki or Tempo at MinIO.**

- `manifests/032-loki-config.yaml` sets `object_store: filesystem` (and `delete_request_store: filesystem`) explicitly.
- `manifests/031-tempo-config.yaml` has no `backend`/`trace_storage`/S3 key at all — it relies on the chart's own default, alongside `persistence.enabled: true, size: 10Gi`, consistent with local PVC storage rather than S3.
- Nothing in `ansible/playbooks/*tempo*` or `*loki*` mentions MinIO or S3.

**But `ops` measured a live, S3-backed Loki on the lab host**, reported while scoping the MinIO replacement (`urb-agents#1795`, 2026-10-01):

| bucket | files | state |
|---|---|---|
| `loki` | 1419, newest same-day | **live** — Loki's chunk store, 84 MB |
| `tempo` | 1 | one marker object, nothing since |

🔴 **So the live installation's Loki is configured differently from what UIS ships.** That configuration lives in the lab's own setup, not in anything tracked in this repository — which means the fix, if one is needed, may be entirely on `ops`'s side, not a change to a UIS manifest. This needs confirming with `ops`, not assumed.

## Why it matters now

MinIO's images are withdrawn from every public registry (`urb-agents#1801`). The lab's MinIO container itself keeps running as long as nothing restarts it, but it cannot be rebuilt or reinstalled if it ever does. A live Loki writing 84 MB/day into a bucket that cannot be recreated is a real, dated risk — distinct from "someone should tidy this up eventually."

## What to find out

- [ ] 1.1 Ask `ops`: is this lab-side configuration (a chart values override, a config file edited outside UIS), or does it come from somewhere in this repository that the scan above missed?
- [ ] 1.2 If lab-side: does `ops` want it migrated to Garage, moved to `filesystem` (matching what UIS itself ships), or left as-is with the risk accepted and documented?
- [ ] 1.3 Tempo's single marker object suggests it was never actually writing traces through MinIO in practice, regardless of configuration - worth confirming before spending effort on it specifically
- [ ] 1.4 If a migration is wanted: Garage's S3 API surface is confirmed adequate for this (plain object writes, no bucket policies or lifecycle rules needed for a log/trace sink) — see [INVESTIGATE-service-minio-to-garage](./INVESTIGATE-service-minio-to-garage.md) for what Garage does and does not implement
- [ ] 1.5 If UIS itself should offer an S3-backed Loki/Tempo option (for a production-scale install, as opposed to the single-node dev default) — that is a separate, larger design question, not implied by fixing the lab's current state

## Not in scope here

No manifest change, no migration script, no decision about whether UIS should ever ship an S3-backed observability stack by default. This stays Backlog until `ops` answers 1.1.

## Related

- [INVESTIGATE-service-minio-to-garage](./INVESTIGATE-service-minio-to-garage.md) - the MinIO replacement this was found while scoping
- `urb-agents#1795`, `#1801`, `#1802` - where the bucket measurement and the Garage work live
