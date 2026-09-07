# PLAN-004: Backstage API Entities

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed

**Goal**: Add API entities to the Backstage catalog so that services show "Provided APIs" and "Consumed APIs" tabs with dependency relationships

**Last Updated**: 2026-03-13

**Investigation**: [INVESTIGATE-service-backstage-enhancements.md](../backlog/INVESTIGATE-service-backstage-enhancements.md) — Enhancement 1

**Prerequisites**: PLAN-002 complete (Backstage deployed with catalog)

---

## Overview

The Backstage catalog currently has Components and Resources linked via `dependsOn`. This plan adds `kind: API` entities so developers can see which services provide and consume APIs. The dependency graph becomes richer — showing actual integration boundaries, not just infrastructure dependencies.

**Scope:** Text descriptions only for API definitions. No OpenAPI spec URLs — that's a future enhancement when we build our own integrations with `openapi.yaml` files in repos.

**Service definition field schema:** `provision-host/uis/schemas/service.schema.json` — single source of truth for all field definitions.

---

## Phase 1: Add New Fields to Service Definitions

### Tasks

- [x] 1.1 Add `SCRIPT_PROVIDES_APIS` and `SCRIPT_CONSUMES_APIS` to `provision-host/uis/schemas/service.schema.json`
- [x] 1.2 Add fields to service definitions that provide APIs
- [x] 1.3 Add fields to service definitions that consume APIs
- [x] 1.4 Update docs files to match schema (`adding-a-service.md`, `naming-conventions.md`, `kubernetes-deployment.md`)

### Implementation Details

**New fields:**
```bash
# === Extended Metadata (Optional) ===
SCRIPT_PROVIDES_APIS=""         # space-separated: "litellm-api"
SCRIPT_CONSUMES_APIS=""         # space-separated: "litellm-api"
```

**Services that provide APIs:**

| Service | SCRIPT_PROVIDES_APIS | API Description |
|---------|---------------------|-----------------|
| litellm | `litellm-api` | OpenAI-compatible LLM proxy REST API |
| authentik | `authentik-api` | Identity provider OAuth/OIDC/SAML API |
| openmetadata | `openmetadata-api` | Data governance and metadata REST API |
| gravitee | `gravitee-api` | API management and gateway REST API |
| grafana | `grafana-api` | Dashboard and datasource query REST API |
| tika | `tika-api` | Document text extraction REST API |
| openwebui | `openwebui-api` | AI chat web interface and REST API |

**Services that consume APIs:**

| Service | SCRIPT_CONSUMES_APIS |
|---------|---------------------|
| openwebui | `litellm-api` |

**Note:** Most services consume database Resources (already modeled via `dependsOn`). Only model explicit API consumption where it adds clarity — not every HTTP call needs an API entity.

### Validation

- [x] Schema validates with new fields
- [x] Service definitions have correct field values

---

## Phase 2: Update Catalog Generator

### Tasks

- [x] 2.1 Extract `SCRIPT_PROVIDES_APIS` and `SCRIPT_CONSUMES_APIS` in `extract_all_metadata()`
- [x] 2.2 Add `providesApis` and `consumesApis` to `generate_service_entity()` spec section
- [x] 2.3 Create `generate_api_entity()` function for `kind: API` entities
- [x] 2.4 Update `generate_all_yaml()` to include API entity references
- [x] 2.5 Update static entity for tika to include `providesApis`

### Implementation Details

**API entity generation approach:**

- API registry collects metadata from all services during scanning
- Each unique API name generates one `kind: API` entity
- `spec.type` is `description` (not `openapi` — avoids renderer error since definitions are text)
- API entities inherit K8s annotations (namespace, label-selector) from parent service
- Tika API registered as a static entry alongside its static component

**Example generated API entity (litellm-api):**
```yaml
apiVersion: backstage.io/v1alpha1
kind: API
metadata:
  name: litellm-api
  description: "Unified API gateway for LLM providers"
  annotations:
    backstage.io/techdocs-ref: url:https://uis.sovereignsky.no/docs/services/ai/litellm
    backstage.io/kubernetes-namespace: ai
    backstage.io/kubernetes-label-selector: "app.kubernetes.io/name=litellm"
    uis.sovereignsky.no/docs-url: "https://uis.sovereignsky.no/docs/services/ai/litellm"
  links:
    - url: https://uis.sovereignsky.no/docs/services/ai/litellm
      title: "litellm-api Docs"
      icon: docs
spec:
  type: description
  lifecycle: production
  owner: app-team
  system: ai
  definition: "Unified API gateway for LLM providers"
```

**Updated Component entity (litellm):**
```yaml
spec:
  type: service
  lifecycle: production
  owner: app-team
  system: ai
  providesApis:
    - litellm-api
  dependsOn:
    - resource:postgresql
```

**Updated Component entity (openwebui):**
```yaml
spec:
  type: service
  lifecycle: production
  owner: app-team
  system: ai
  providesApis:
    - openwebui-api
  consumesApis:
    - litellm-api
  dependsOn:
    - resource:postgresql
```

### Validation

- [x] `./uis catalog generate` completes without errors
- [x] Generated API entity files appear in `generated/backstage/catalog/apis/`
- [x] Generated component files include `providesApis`/`consumesApis` where appropriate
- [x] `all.yaml` references the new API entity files

---

## Phase 3: Deploy and Verify

### Tasks

- [x] 3.1 Build container with updated generator
- [x] 3.2 Regenerate catalog: `./uis catalog generate`
- [x] 3.3 Redeploy backstage: `./uis undeploy backstage && ./uis deploy backstage`
- [x] 3.4 Verify in browser: check litellm entity page → "Provided APIs" tab shows litellm-api
- [x] 3.5 Verify in browser: check openwebui entity page → "Consumed APIs" tab shows litellm-api
- [x] 3.6 Verify in browser: check litellm-api entity page → shows provider and consumer
- [x] 3.7 Verify dependency graph shows API relationships

### Validation

- [x] API entities visible in Backstage catalog (7 entities at /api-docs)
- [x] Provided/Consumed APIs tabs populated on component pages
- [x] Dependency graph includes API relationships

### Issues found and fixed during testing

1. **API page URL**: Backstage uses `/api-docs` not `/apis` for the API list page
2. **Definition tab rendering**: Changed `spec.type` from `openapi` to `description` to avoid OpenAPI renderer error on text definitions
3. **K8s annotations on API entities**: Added namespace and label-selector inheritance from parent service to fix "Missing Annotation" on API entity Kubernetes tabs

---

## Phase 4: Cleanup

### Tasks

- [x] 4.1 Update `INVESTIGATE-service-backstage-enhancements.md` — note Enhancement 1 is complete
- [ ] 4.2 Move this plan to `completed/`

---

## Acceptance Criteria

- [x] `SCRIPT_PROVIDES_APIS` and `SCRIPT_CONSUMES_APIS` fields added to schema and relevant service definitions
- [x] Catalog generator produces `kind: API` entities with text descriptions
- [x] Component entities include `providesApis`/`consumesApis` in spec
- [x] API relationships visible in Backstage UI (tabs and dependency graph)
- [x] Docs files updated to match schema

---

## Files Modified

| File | Change |
|------|--------|
| `provision-host/uis/schemas/service.schema.json` | Added `providesApis` and `consumesApis` fields |
| `provision-host/uis/manage/uis-backstage-catalog.sh` | Extract new fields, `providesApis`/`consumesApis` in spec, `generate_api_entities()` with K8s annotation inheritance |
| `provision-host/uis/services/ai/service-litellm.sh` | Added `SCRIPT_PROVIDES_APIS="litellm-api"` |
| `provision-host/uis/services/ai/service-openwebui.sh` | Added `SCRIPT_PROVIDES_APIS="openwebui-api"` and `SCRIPT_CONSUMES_APIS="litellm-api"` |
| `provision-host/uis/services/identity/service-authentik.sh` | Added `SCRIPT_PROVIDES_APIS="authentik-api"` |
| `provision-host/uis/services/analytics/service-openmetadata.sh` | Added `SCRIPT_PROVIDES_APIS="openmetadata-api"` |
| `provision-host/uis/services/integration/service-gravitee.sh` | Added `SCRIPT_PROVIDES_APIS="gravitee-api"` |
| `provision-host/uis/services/observability/service-grafana.sh` | Added `SCRIPT_PROVIDES_APIS="grafana-api"` |
| `website/docs/contributors/guides/adding-a-service.md` | Added new fields to example and reference table |
| `website/docs/contributors/rules/naming-conventions.md` | Added new fields to example |
| `website/docs/contributors/rules/kubernetes-deployment.md` | Added new fields to example and metadata groups table |
