# Upgrade Elasticsearch to 9.3.0

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed

**Completed**: 2026-03-09

**Goal**: Pin Elasticsearch to version 9.3.0, upgrading from the unpinned 8.5.1 default to unblock OpenMetadata deployment and eliminate version drift risk.

**Last Updated**: 2026-03-09

**Priority**: High

**Blocks**: [OpenMetadata deployment](INVESTIGATE-openmetadata-deployment.md) (requires ES 9.x)

**Related**: [INVESTIGATE-elasticsearch-upgrade.md](INVESTIGATE-elasticsearch-upgrade.md), [INVESTIGATE-system-version-pinning.md](../backlog/INVESTIGATE-system-version-pinning.md)

---

## Problem

Elasticsearch is deployed via the `elastic/elasticsearch` Helm chart with no explicit image tag. The chart defaults to 8.5.1. This causes two problems:

1. **OpenMetadata requires ES 9.x** — the ES 9.x client is not backwards-compatible with 8.x servers
2. **No version pinning** — while the archived Helm chart won't change, relying on an implicit default is fragile

Only Gravitee depends on Elasticsearch, and it supports ES 9.2.x+. The upgrade is a single-line config change.

---

## Phase 1: Upgrade Elasticsearch Config and Metadata — ✅ DONE

### Tasks

- [x] 1.1 Add `imageTag: "9.3.0"` to `manifests/060-elasticsearch-config.yaml` (after the `replicas: 1` line) ✓
- [x] 1.2 Update `website/docs/services/databases/elasticsearch.md` — change Helm chart row from `(unpinned)` to `(pinned: 9.3.0)` ✓
- [x] 1.3 Update `website/docs/ai-developer/plans/backlog/INVESTIGATE-system-version-pinning.md` ✓:
  - Change the Elasticsearch row in the Helm Charts table from `UNPINNED` to `PINNED 9.3.0`
  - Remove `elasticsearch` from the "Images controlled by Helm chart" list
  - Add Elasticsearch to the Container Images table as `PINNED` with tag `9.3.0`
  - Update the summary count (3 → 4 pinned, 18 → 17 unpinned)

### Validation

```bash
# Deploy and verify version
./uis deploy elasticsearch

# Check version (should show 9.3.0)
kubectl exec elasticsearch-master-0 -- curl -s http://localhost:9200 | jq '.version.number'

# Check cluster health (yellow or green is OK for single node)
kubectl exec elasticsearch-master-0 -- curl -s http://localhost:9200/_cluster/health | jq '.status'
```

User confirms Elasticsearch 9.3.0 is running and healthy.

---

## Phase 2: Update Investigation and Roadmap Status — ✅ DONE

### Tasks

- [x] 2.1 Update `website/docs/ai-developer/plans/backlog/INVESTIGATE-elasticsearch-upgrade.md` — mark both Next Steps checkboxes as done ✓
- [x] 2.2 Update `website/docs/ai-developer/plans/backlog/STATUS-platform-roadmap.md` — change item #1 status from "Ready for PLAN" to "Complete" ✓

### Validation

User confirms the status updates are correct.

---

## Acceptance Criteria

- [x] `manifests/060-elasticsearch-config.yaml` contains `imageTag: "9.3.0"` ✓
- [x] Elasticsearch pod runs version 9.3.0 ✓
- [x] Cluster health is yellow or green (green) ✓
- [x] Elasticsearch docs page shows pinned version ✓
- [x] Version-pinning investigation shows ES as PINNED ✓
- [x] Elasticsearch upgrade investigation shows next steps done ✓
- [x] Platform roadmap shows item #1 as complete ✓

---

## Implementation Notes

- The `elastic/elasticsearch` Helm chart is archived at chart version 8.5.1, but `imageTag` overrides the Docker image independently of the chart version
- ES 9.x can read indices created by 8.x — no data migration needed
- If the PVC has stale data causing issues, deleting it and letting Gravitee re-index is acceptable (dev data)

---

## Files to Modify

| File | Change |
|------|--------|
| `manifests/060-elasticsearch-config.yaml` | Add `imageTag: "9.3.0"` |
| `website/docs/services/databases/elasticsearch.md` | Update Helm chart row to show pinned version |
| `website/docs/ai-developer/plans/backlog/INVESTIGATE-system-version-pinning.md` | Mark ES as PINNED 9.3.0 |
| `website/docs/ai-developer/plans/backlog/INVESTIGATE-elasticsearch-upgrade.md` | Mark next steps as done |
| `website/docs/ai-developer/plans/backlog/STATUS-platform-roadmap.md` | Mark #1 as complete |
