# PLAN-001: Backstage Metadata Enrichment and Catalog Generator

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed

**Goal**: Add `SCRIPT_KIND`, `SCRIPT_TYPE`, `SCRIPT_OWNER` metadata fields to all service definitions and build a catalog generator that produces Backstage-compatible YAML from them

**Last Updated**: 2026-03-12

**Investigation**: [INVESTIGATE-backstage.md](./INVESTIGATE-backstage.md)

**Blocks**: PLAN-002-backstage-deployment cannot load a catalog without this

**Priority**: Medium — no cluster needed, no risk, pure code

---

## Overview

UIS service definitions (`provision-host/uis/services/*/service-*.sh`) are the single source of truth for service metadata. The docs website is already generated from them via `uis-docs.sh`. This plan extends that pattern to Backstage:

1. Add three new metadata fields to all 29 service definitions
2. Update documentation and schema for the new fields
3. Build a generator script that produces Backstage catalog YAML
4. Validate output against the draft catalog in the investigation

No cluster is needed. All work is local code and can be tested without deploying anything.

### Reference patterns

- **`uis-docs.sh`** + **`service-scanner.sh`** — existing generator pattern to follow
- **Draft catalog** at `plans/backlog/catalog/` — validation reference for generator output

---

## Phase 1: Add Metadata Fields to Service Definitions — ✅ DONE

Add `SCRIPT_KIND`, `SCRIPT_TYPE`, and `SCRIPT_OWNER` to all 29 service definitions.

### Tasks

- [x] 1.1 Add fields to all **DATABASES** category services (6 scripts — these are `Resource` kind): ✓

  | Service | `SCRIPT_KIND` | `SCRIPT_TYPE` | `SCRIPT_OWNER` |
  |---------|---------------|---------------|-----------------|
  | `service-postgresql.sh` | `Resource` | `database` | `platform-team` |
  | `service-mysql.sh` | `Resource` | `database` | `platform-team` |
  | `service-mongodb.sh` | `Resource` | `database` | `platform-team` |
  | `service-elasticsearch.sh` | `Resource` | `database` | `platform-team` |
  | `service-redis.sh` | `Resource` | `cache` | `platform-team` |
  | `service-qdrant.sh` | `Resource` | `database` | `platform-team` |

- [x] 1.2 Add fields to **INTEGRATION** category services (3 scripts):

  | Service | `SCRIPT_KIND` | `SCRIPT_TYPE` | `SCRIPT_OWNER` |
  |---------|---------------|---------------|-----------------|
  | `service-rabbitmq.sh` | `Resource` | `message-broker` | `platform-team` |
  | `service-gravitee.sh` | `Component` | `service` | `app-team` |
  | `service-enonic.sh` | `Component` | `service` | `app-team` |

- [x] 1.3 Add fields to **OBSERVABILITY** category services (5 scripts):

  | Service | `SCRIPT_KIND` | `SCRIPT_TYPE` | `SCRIPT_OWNER` |
  |---------|---------------|---------------|-----------------|
  | `service-grafana.sh` | `Component` | `service` | `platform-team` |
  | `service-prometheus.sh` | `Component` | `service` | `platform-team` |
  | `service-loki.sh` | `Component` | `service` | `platform-team` |
  | `service-tempo.sh` | `Component` | `service` | `platform-team` |
  | `service-otel-collector.sh` | `Component` | `service` | `platform-team` |

- [x] 1.4 Add fields to **AI** category services (2 scripts):

  | Service | `SCRIPT_KIND` | `SCRIPT_TYPE` | `SCRIPT_OWNER` |
  |---------|---------------|---------------|-----------------|
  | `service-openwebui.sh` | `Component` | `service` | `app-team` |
  | `service-litellm.sh` | `Component` | `service` | `app-team` |

- [x] 1.5 Add fields to **ANALYTICS** category services (4 scripts):

  | Service | `SCRIPT_KIND` | `SCRIPT_TYPE` | `SCRIPT_OWNER` |
  |---------|---------------|---------------|-----------------|
  | `service-openmetadata.sh` | `Component` | `service` | `app-team` |
  | `service-unity-catalog.sh` | `Component` | `service` | `app-team` |
  | `service-jupyterhub.sh` | `Component` | `service` | `app-team` |
  | `service-spark.sh` | `Component` | `service` | `app-team` |

- [x] 1.6 Add fields to **IDENTITY** category services (1 script):

  | Service | `SCRIPT_KIND` | `SCRIPT_TYPE` | `SCRIPT_OWNER` |
  |---------|---------------|---------------|-----------------|
  | `service-authentik.sh` | `Component` | `service` | `platform-team` |

- [x] 1.7 Add fields to **MANAGEMENT** category services (5 scripts):

  | Service | `SCRIPT_KIND` | `SCRIPT_TYPE` | `SCRIPT_OWNER` |
  |---------|---------------|---------------|-----------------|
  | `service-argocd.sh` | `Component` | `tool` | `platform-team` |
  | `service-pgadmin.sh` | `Component` | `tool` | `platform-team` |
  | `service-redisinsight.sh` | `Component` | `tool` | `platform-team` |
  | `service-whoami.sh` | `Component` | `tool` | `platform-team` |
  | `service-nginx.sh` | `Component` | `service` | `platform-team` |

- [x] 1.8 Add fields to **NETWORKING** category services (2 scripts):

  | Service | `SCRIPT_KIND` | `SCRIPT_TYPE` | `SCRIPT_OWNER` |
  |---------|---------------|---------------|-----------------|
  | `service-cloudflare-tunnel.sh` | `Component` | `service` | `platform-team` |
  | `service-tailscale-tunnel.sh` | `Component` | `service` | `platform-team` |

- [x] 1.9 Add fields to **APPLICATIONS** category services (1 script):

  | Service | `SCRIPT_KIND` | `SCRIPT_TYPE` | `SCRIPT_OWNER` |
  |---------|---------------|---------------|-----------------|
  | `service-nextcloud.sh` | `Component` | `service` | `app-team` |

  Note: `service-nextcloud.sh` lives in `services/management/` but has `SCRIPT_CATEGORY="APPLICATIONS"`. The category field is what matters for the catalog, not the directory.

### Implementation Details

Add a new `# === Extended Metadata (Optional) ===` section after `# === Deployment Details (Optional) ===` in each script:

```bash
# === Extended Metadata (Optional) ===
SCRIPT_KIND="Component"        # Component | Resource
SCRIPT_TYPE="service"          # service | tool | library | database | cache | message-broker
SCRIPT_OWNER="platform-team"   # platform-team | app-team
```

### Validation

- [x] All 29 service scripts have the three new fields ✓
- [x] `./uis list` still works — new optional fields don't affect the scanner (verified: scanner only reads known fields line-by-line) ✓
- [x] `./uis docs generate` still works — new fields are ignored by the JSON generator (it only reads its own set of SCRIPT_* variables) ✓

---

## Phase 2: Update Documentation and Schema — ✅ DONE

Update the docs and JSON schema to reflect the new fields.

### Tasks

- [x] 2.1 Update `provision-host/uis/schemas/service.schema.json` — add `kind`, `type`, `owner` properties ✓
- [x] 2.2 Update `website/docs/contributors/guides/adding-a-service.md` — add new fields to the service definition example (Step 2) and field reference table ✓
- [x] 2.3 Update `website/docs/contributors/rules/kubernetes-deployment.md` — add new fields to the service metadata reference section ✓
- [x] 2.4 Update `website/docs/contributors/rules/naming-conventions.md` — add naming conventions for allowed values (`Component`/`Resource`, `service`/`tool`/`library`/`database`/`cache`/`message-broker`, `platform-team`/`app-team`) ✓

### Implementation Details

**2.1 Schema update** — add to `service.schema.json`:

```json
"kind": {
  "type": "string",
  "description": "Whether this is a software component or infrastructure resource",
  "enum": ["Component", "Resource"],
  "default": "Component"
},
"type": {
  "type": "string",
  "description": "What kind of component or resource",
  "enum": ["service", "tool", "library", "database", "cache", "message-broker"],
  "default": "service"
},
"owner": {
  "type": "string",
  "description": "Which team owns this service",
  "enum": ["platform-team", "app-team"],
  "default": "platform-team"
}
```

These are NOT added to the `required` array — they are optional with sensible defaults.

### Validation

- [x] Schema includes `kind`, `type`, `owner` as optional properties with enums and defaults ✓
- [x] Adding-a-service guide shows Extended Metadata in example and field reference ✓
- [x] Kubernetes deployment rules show Extended Metadata in groups table and example ✓
- [x] Naming conventions document allowed values for all three fields ✓

---

## Phase 3: Build the Catalog Generator — ✅ DONE

Create the script that generates Backstage catalog YAML from service definitions.

### Tasks

- [x] 3.1 Create `provision-host/uis/manage/uis-backstage-catalog.sh` — the generator script ✓
- [x] 3.2 Implement service scanning using single-pass `extract_all_metadata()` (optimized — reads all fields in one pass per file) ✓
- [x] 3.3 Implement component/resource YAML generation — one file per service in `components/` or `resources/` ✓
- [x] 3.4 Implement static entity generation — Domain (`uis-infrastructure`), Systems (one per category that has services — skip STORAGE which has none), Groups (`platform-team`, `app-team`, `business-owners`), Users ✓
- [x] 3.5 Implement `all.yaml` Location entity generation — references all generated files ✓
- [x] 3.6 Add Tika and OnlyOffice as hardcoded static component entries (bundled services without their own service definitions) ✓
- [x] 3.7 Implement `dependsOn` mapping — convert `SCRIPT_REQUIRES` to Backstage references (`resource:postgresql`, `component:litellm`, etc.) using `SCRIPT_KIND` to determine prefix ✓
- [x] 3.8 Add `--output-dir` flag (default: `generated/backstage/catalog/`) ✓
- [x] 3.9 Add `--dry-run` flag to show what would be generated without writing files ✓
- [x] 3.10 Wire into CLI: add `catalog generate` subcommand registered in `uis-cli.sh` ✓

### Implementation Details

**Generator structure** — follows the `uis-docs.sh` pattern:

```bash
#!/bin/bash
# uis-backstage-catalog.sh - Generate Backstage catalog YAML from service definitions

source "$LIB_DIR/logging.sh"
source "$LIB_DIR/categories.sh"
source "$LIB_DIR/service-scanner.sh"
```

**Generated file structure:**

```
generated/backstage/catalog/
├── all.yaml                    ← Location entity referencing everything
├── domains/
│   └── uis-infrastructure.yaml
├── systems/                    ← 9 systems (one per category with services)
│   ├── ai.yaml
│   ├── analytics.yaml
│   ├── applications.yaml       ← Nextcloud (SCRIPT_CATEGORY="APPLICATIONS")
│   ├── databases.yaml
│   ├── identity.yaml
│   ├── integration.yaml
│   ├── management.yaml
│   ├── networking.yaml
│   └── observability.yaml
├── components/
│   ├── openwebui.yaml
│   ├── grafana.yaml
│   └── ...
├── resources/
│   ├── postgresql.yaml
│   ├── redis.yaml
│   └── ...
└── groups/
    ├── platform-team.yaml
    ├── app-team.yaml
    └── business-owners.yaml
```

**Per-component YAML template** (generated from service definition fields):

```yaml
apiVersion: backstage.io/v1alpha1
kind: ${SCRIPT_KIND}
metadata:
  name: ${SCRIPT_ID}
  description: "${SCRIPT_DESCRIPTION}"
  annotations:
    backstage.io/kubernetes-id: ${SCRIPT_ID}
    backstage.io/kubernetes-namespace: ${SCRIPT_NAMESPACE}
    uis.sovereignsky.no/docs-url: "https://uis.sovereignsky.no${SCRIPT_DOCS}"
    uis.sovereignsky.no/business-owner: "business-owners"
  links:
    - url: https://uis.sovereignsky.no${SCRIPT_DOCS}
      title: "${SCRIPT_ID} Docs"
      icon: docs
spec:
  type: ${SCRIPT_TYPE}
  lifecycle: production
  owner: ${SCRIPT_OWNER}
  system: ${SCRIPT_CATEGORY_LOWERCASE}
  dependsOn:
    # Generated from SCRIPT_REQUIRES
```

**Default values** when fields are missing:
- `SCRIPT_KIND`: `Component` (except `DATABASES` category → `Resource`)
- `SCRIPT_TYPE`: `service`
- `SCRIPT_OWNER`: `platform-team`
- `backstage.io/kubernetes-id`: defaults to `SCRIPT_ID`

**Grafana annotations** — since the Grafana plugin is required (PLAN-002), include Grafana dashboard annotations in generated entities where applicable. The generator can add a default `grafana/dashboard-selector` annotation based on `SCRIPT_ID` (e.g., `"tag:postgresql"`). Services without Grafana dashboards get the annotation but it simply shows no dashboards — no harm.

**dependsOn mapping** — for each ID in `SCRIPT_REQUIRES`, look up the required service's `SCRIPT_KIND` to determine prefix:
- `SCRIPT_KIND="Resource"` → `resource:postgresql`
- `SCRIPT_KIND="Component"` → `component:litellm`

**Categories and Systems** — there are 10 categories defined in `categories.sh`, but STORAGE has no services. The generator should only create System entities for categories that have at least one service (currently 9: OBSERVABILITY, AI, ANALYTICS, IDENTITY, DATABASES, MANAGEMENT, APPLICATIONS, NETWORKING, INTEGRATION).

**Performance note** — the existing `get_service_value()` function reads the file once per field. For the generator, which needs ~10 fields per service, consider reading all fields in a single pass (similar to how `extract_script_metadata` works, but extracting more fields). This is an implementation detail — `get_service_value` works correctly, just slower.

### Validation

- [x] Generator produces YAML for all 29 services + 2 static (Tika, OnlyOffice) — 31 total ✓
- [x] Generated output matches the structure of the draft catalog in `plans/backlog/catalog/` ✓
- [x] `all.yaml` references all generated entity files ✓
- [x] Domain, Systems, and Groups are generated correctly ✓
- [x] `dependsOn` references use correct `resource:` or `component:` prefixes ✓
- [x] `--dry-run` shows output without writing files ✓
- [x] Generated YAML is valid (no syntax errors) ✓
- [x] Script is bash 3.2 compatible (macOS default bash — no associative arrays or `${var,,}`) ✓

---

## Phase 4: Validate and Clean Up — ✅ DONE

Compare generator output with draft catalog and finalize.

### Tasks

- [x] 4.1 Run generator and diff output against `plans/backlog/catalog/` ✓
- [x] 4.2 Discrepancies identified and explained (see below) ✓
- [x] 4.3 Added `generated/` to `.gitignore` (generated files should not be version-controlled) ✓
- [x] 4.4 Update `INVESTIGATE-backstage.md` — note that PLAN-001 is complete ✓

### Diff Results

Structural differences from draft catalog (all explained):
- `spark.yaml` vs `apache-spark.yaml` — generator uses `SCRIPT_ID="spark"` (correct)
- `enonic.yaml` vs `enonic-xp.yaml` — generator uses `SCRIPT_ID="enonic"` (correct)
- `otel-collector.yaml` vs `otlp-collector.yaml` — generator uses `SCRIPT_ID="otel-collector"` (correct)
- Draft has `sovdev-logger.yaml` — no service definition exists (it's a library, not a deployed service)
- Generator adds `grafana/dashboard-selector` annotation — enhancement from this plan
- Minor description text differences — generator uses `SCRIPT_DESCRIPTION` (source of truth)

### Validation

- [x] Generator output matches the draft catalog structure (differences are explained above) ✓
- [x] User confirms the generated catalog is ready for use by PLAN-002 ✓

---

## Acceptance Criteria

- [x] All 29 service definitions have `SCRIPT_KIND`, `SCRIPT_TYPE`, `SCRIPT_OWNER` fields ✓
- [x] JSON schema (`service.schema.json`) includes the new fields ✓
- [x] Documentation updated (adding-a-service.md, kubernetes-deployment.md, naming-conventions.md) ✓
- [x] Generator script exists and runs without errors ✓
- [x] Generator produces valid Backstage catalog YAML for all services (31 entities: 29 + 2 static) ✓
- [x] Static entities (Domain, Systems, Groups, Users, Tika, OnlyOffice) are generated ✓
- [x] `dependsOn` references use correct `resource:`/`component:` prefixes ✓
- [x] `all.yaml` Location entity references all files ✓
- [x] Existing CLI commands (`./uis list`, `./uis docs generate`) still work — new optional fields are ignored by existing parsers ✓
- [x] Generator can be invoked via `./uis catalog generate` ✓

---

## Files to Create

| File | Purpose |
|------|---------|
| `provision-host/uis/manage/uis-backstage-catalog.sh` | Backstage catalog generator script |
| `generated/backstage/catalog/` | Output directory (generated files) |

## Files to Modify

| File | Change |
|------|--------|
| 29 service scripts in `provision-host/uis/services/*/` | Add `SCRIPT_KIND`, `SCRIPT_TYPE`, `SCRIPT_OWNER` |
| `provision-host/uis/schemas/service.schema.json` | Add `kind`, `type`, `owner` properties |
| `website/docs/contributors/guides/adding-a-service.md` | Add new fields to Step 2 example and reference table |
| `website/docs/contributors/rules/kubernetes-deployment.md` | Add new fields to metadata reference |
| `website/docs/contributors/rules/naming-conventions.md` | Add allowed values for new fields |
| `provision-host/uis/manage/uis-docs.sh` or `uis-cli.sh` | Wire in the new generator command |
