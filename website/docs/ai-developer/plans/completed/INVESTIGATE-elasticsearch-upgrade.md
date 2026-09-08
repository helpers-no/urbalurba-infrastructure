# Investigate: Elasticsearch Upgrade and Version Pinning

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed

**Goal**: Upgrade Elasticsearch to 9.x and pin the version to prevent unexpected changes

**Last Updated**: 2026-03-09

**Related**:
- [INVESTIGATE-openmetadata-deployment.md](INVESTIGATE-openmetadata-deployment.md) — OpenMetadata requires ES 9.x
- [INVESTIGATE-system-version-pinning.md](../backlog/INVESTIGATE-system-version-pinning.md) — Elasticsearch is listed as unpinned. This upgrade also pins the version. Update that investigation after this work is complete.

---

## Questions to Answer

1. What version of Elasticsearch is currently deployed in UIS? → **8.5.1 (unpinned)**
2. What services depend on Elasticsearch? → **Only Gravitee**
3. Is Gravitee compatible with ES 9.x? → **Yes — supports 7.17.x, 8.16.x, and 9.2.x**
4. What is the upgrade path from 8.5.1 to 9.x?
5. Should we pin the version in the Helm values?

---

## Current State

### Elasticsearch deployment

- **Helm chart**: `elastic/elasticsearch` (official Elastic chart, archived at chart version 8.5.1)
- **Image version**: 8.5.1 (unpinned — the chart default)
- **Config**: `manifests/060-elasticsearch-config.yaml`
- **Namespace**: `default`
- **Service**: `elasticsearch-master:9200`
- **Settings**: Single-node, security disabled, HTTP protocol, 512MB JVM heap, 1Gi memory limit

The version is **not pinned** in the config. The chart's `values.yaml` defaults to `imageTag: "8.5.1"`. Since the Elastic Helm chart repository is archived and will not receive updates, the unpinned version will stay at 8.5.1 indefinitely — but this is fragile and should be explicitly set.

### Services that depend on Elasticsearch

| Service | How it uses ES | ES version requirement |
|---|---|---|
| **Gravitee** (API Management) | Analytics, request tracking, metrics storage. Connects to `elasticsearch-master.default.svc.cluster.local:9200` | Supports 7.17.x, 8.16.x, **9.2.x** |

**No other UIS services use Elasticsearch.** OpenWebUI, LiteLLM, PostgreSQL, MongoDB, Redis, Authentik, ArgoCD — none depend on ES.

### Why upgrade is needed

OpenMetadata (1.12.x) requires **ES 9.x** (minimum 9.0.0, recommended 9.3.0). The ES 9.x client is not backwards-compatible with 8.x servers. The current ES 8.5.1 does not work with OpenMetadata.

---

## Compatibility Matrix

| Service | ES 8.5.1 (current) | ES 9.3.0 (target) |
|---|---|---|
| **Gravitee** | Works (supports 8.16.x) | Works (supports 9.2.x) |
| **OpenMetadata** (planned) | Does NOT work | Works (requires 9.x) |

Upgrading to ES 9.x is compatible with all current and planned services.

---

## Upgrade Approach

### The Helm chart situation

The `elastic/elasticsearch` Helm chart is **archived** — Elastic handed maintenance to the community. The chart version is frozen at 8.5.1, but the Docker image tag can be overridden independently.

The chart templates are generic Kubernetes resource definitions (StatefulSet, Service, etc.) that are not tightly coupled to a specific ES version. Overriding `imageTag` to a 9.x image should work without chart changes.

### What needs to change

**1. Pin the version in `manifests/060-elasticsearch-config.yaml`:**

```yaml
# Pin Elasticsearch version explicitly
imageTag: "9.3.0"
```

This is the only change needed for the upgrade. The rest of the config (single-node, security disabled, HTTP protocol) is already correct for both Gravitee and OpenMetadata.

**2. Verify after upgrade:**

```bash
# Check ES is running with correct version
kubectl exec -n default elasticsearch-master-0 -- curl -s http://localhost:9200 | jq '.version.number'

# Check Gravitee still works
kubectl logs -n default -l app.kubernetes.io/name=gravitee-apim --tail=50

# Test ES health
curl http://elasticsearch.localhost/_cluster/health?pretty
```

### Data migration consideration

Elasticsearch 9.x can read indices created by 8.x. However, for a dev environment:
- If the ES PVC has data, the upgrade should handle it automatically
- If there are issues, deleting the PVC and letting Gravitee re-index is acceptable (dev data is not critical)

---

## Recommendation

1. **Pin the version** — add `imageTag: "9.3.0"` to `060-elasticsearch-config.yaml`
2. **Upgrade in place** — redeploy with the new image tag
3. **Verify Gravitee** — check that API analytics still work after upgrade
4. **Unblocks OpenMetadata** — resolves the ES version mismatch

This is a low-risk change: only one service (Gravitee) depends on ES, and Gravitee explicitly supports ES 9.2.x+.

---

## Proposed Files to Modify

| File | Change |
|------|--------|
| `manifests/060-elasticsearch-config.yaml` | Add `imageTag: "9.3.0"` to pin the version |
| `provision-host/uis/services/databases/service-elasticsearch.sh` | Update website metadata to reflect the pinned version (used by `uis-docs.sh` to generate JSON for the documentation website) |

---

## Next Steps

- [x] Create PLAN to upgrade and pin Elasticsearch version ✓
- [x] After upgrade: update `INVESTIGATE-system-version-pinning.md` — change Elasticsearch row from UNPINNED to PINNED with version `9.3.0` ✓
