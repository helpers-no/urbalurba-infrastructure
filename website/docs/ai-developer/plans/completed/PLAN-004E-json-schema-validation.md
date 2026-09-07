# PLAN-004E: JSON Schema Validation Framework

**Status:** Completed — ✅ Completed
**Parent:** PLAN-004 (UIS Orchestration System)
**Created:** 2025-01-22
**Completed:** 2025-01-22

## Overview

Create a validation framework to ensure generated JSON documentation files match their corresponding schemas. This ensures data integrity between the bash-based service definitions and the website's data layer.

## Goals

1. Align all generated JSON files with their schemas
2. Create automated validation script
3. Ensure schema consistency across services, categories, stacks, and tools

## Schema Inventory

| JSON File | Schema | Description |
|-----------|--------|-------------|
| `services.json` | `service.schema.json` | 24 infrastructure services |
| `categories.json` | `category.schema.json` | 10 service categories |
| `stacks.json` | `stack.schema.json` | 3 service stacks |
| `tools.json` | `tool.schema.json` | 7 CLI tools |

## Tasks

### 1. Schema Alignment

#### 1.1 Service Schema (`service.schema.json`)
- [x] Remove obsolete fields: `manifest`, `related`
- [x] Add operational fields: `playbook`, `priority`, `checkCommand`, `removePlaybook`
- [x] Add documentation fields: `tags`, `summary`, `docs`
- [x] Make `logo` optional (allow empty string for test services)

**Required fields:**
```
id, name, description, category, tags, abstract, website, summary, docs
```

**Optional fields:**
```
@type, logo, playbook, priority, checkCommand, removePlaybook, requires
```

#### 1.2 Category Schema (`category.schema.json`)
- [x] Simplify to match generated output
- [x] Remove unused fields: `tags`, `abstract`, `summary`, `logo`, `manifest_range`

**Required fields:**
```
id, name, order, description, icon
```

#### 1.3 Stack Schema (`stack.schema.json`)
- [x] Add new fields: `tags`, `abstract`, `docs`
- [x] Ensure consistency with service schema structure

**Required fields:**
```
identifier, name, description, category, tags, abstract, summary, docs, components
```

#### 1.4 Tool Schema (`tool.schema.json`)
- [x] Create new schema (was missing)
- [x] Use `@type: "SoftwareApplication"` for Schema.org compatibility

**Required fields:**
```
id, name, description, builtin
```

**Optional fields:**
```
@type, category, size, website
```

### 2. Update Data Generators

#### 2.1 Update `stacks.sh`
- [x] Add `tags`, `abstract`, `docs` to data format
- [x] Add getter functions: `get_stack_tags`, `get_stack_abstract`, `get_stack_docs`
- [x] Update `generate_stacks_json_internal` to output new fields

**Data format (pipe-delimited):**
```
id|name|description|category|tags|abstract|services|optional_services|summary|docs|logo
```

#### 2.2 Update `uis-docs.sh`
- [x] Use `@type` instead of `type` for tools
- [x] Ensure proper JSON generation for all file types

### 3. Create Validation Script

- [x] Create `provision-host/uis/tests/validate-schemas.sh`
- [x] Use Python jsonschema for validation
- [x] Validate each item in array-based JSON files
- [x] Provide clear error messages with item ID and field path

**Usage:**
```bash
./provision-host/uis/tests/validate-schemas.sh           # Validate all
./provision-host/uis/tests/validate-schemas.sh services  # Validate specific
```

## Files Modified

| File | Action |
|------|--------|
| `website/src/data/schemas/service.schema.json` | Modified - removed obsolete fields, made logo optional |
| `website/src/data/schemas/category.schema.json` | Modified - simplified to match output |
| `website/src/data/schemas/stack.schema.json` | Modified - added tags, abstract, docs |
| `website/src/data/schemas/tool.schema.json` | Created - new schema |
| `provision-host/uis/lib/stacks.sh` | Modified - added new fields and getters |
| `provision-host/uis/tests/validate-schemas.sh` | Created - validation script |

## Validation Results

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
JSON Schema Validation
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

services.json        → service.schema.json       ✓ PASS (24 items)
categories.json      → category.schema.json      ✓ PASS (10 items)
stacks.json          → stack.schema.json         ✓ PASS (3 items)
tools.json           → tool.schema.json          ✓ PASS (7 items)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
All validations passed (4 files)
```

## Schema Patterns

### Logo Pattern
```regex
^([a-z0-9-]+-logo\.(svg|webp))?$
```
Allows: `prometheus-logo.svg`, `grafana-logo.webp`, or empty string

### ID Pattern
```regex
^[a-z0-9-]+$
```
Examples: `prometheus`, `otel-collector`, `unity-catalog`

### Category Pattern
```regex
^[A-Z]+$
```
Examples: `CORE`, `MONITORING`, `AI`, `DATABASES`

### Docs Path Pattern
```regex
^/docs/
```
Examples: `/docs/services/monitoring/prometheus`, `/docs/stacks/observability`

### Playbook Pattern
```regex
^\d{3}-[a-z0-9-]+\.yml$
```
Examples: `030-setup-prometheus.yml`, `200-setup-openwebui.yml`

## Integration

The validation script can be integrated into:
1. CI/CD pipeline for pull request checks
2. Pre-commit hooks
3. The `uis docs generate` command (add `--validate` flag)

## Future Enhancements

1. Add JSON Schema validation to `uis docs generate --validate`
2. Create schema documentation generator
3. Add cross-reference validation (service IDs in stacks exist in services.json)
4. TypeScript type generation from schemas for website components
