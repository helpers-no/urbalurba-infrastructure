# PLAN: Auto-Generate Service Documentation from Script Metadata

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Related**: [INVESTIGATE-documentation-generation](INVESTIGATE-documentation-generation.md), [INVESTIGATE-documentation-rewrite](INVESTIGATE-documentation-rewrite.md)
**Created**: 2026-03-02
**Status:** Completed
**Completed**: 2026-03-02

**Goal**: Build a bash script that auto-generates service documentation pages from script metadata, using the manually written PLAN-014 pages as the template specification.

**Last Updated**: 2026-03-02

**Priority**: Medium — eliminates doc drift, makes adding new services zero-friction

---

## Problem Summary

PLAN-014 manually rewrote all 26+ service pages using a standard template. The result is good, but:
- Adding a new service requires manually writing a doc page
- Metadata changes in service scripts (deps, descriptions) don't update docs automatically
- `uis-docs.sh` already generates JSON from script metadata but does not generate markdown pages

### What Exists Today

| Component | Status |
|-----------|--------|
| 16 SCRIPT_* metadata variables in all 26 service scripts | Done |
| `uis-docs.sh` — scans scripts, generates JSON (services.json, categories.json, stacks.json) | Done |
| `service-scanner.sh` — library with query functions | Done |
| `categories.sh` — centralized category definitions | Done |
| Standard service page template (from PLAN-014) | Done — redis.md, whoami.md, authentik.md as examples |
| Markdown page generator | **Missing** |

### Auto-Generatable vs Manual Content

| Template Section | Auto-generate? | Source |
|---|---|---|
| Frontmatter (title, sidebar_label) | Yes | `SCRIPT_NAME` |
| One-line description | Yes | `SCRIPT_DESCRIPTION` |
| Info table: Category | Yes | `SCRIPT_CATEGORY` via `categories.sh` |
| Info table: Deploy/Undeploy | Yes | `SCRIPT_ID` |
| Info table: Depends on | Yes | `SCRIPT_REQUIRES` |
| Info table: Required by | Yes | Reverse lookup across all `SCRIPT_REQUIRES` |
| Info table: Helm chart | Partial | New field `SCRIPT_HELM_CHART` needed |
| Info table: Default namespace | Partial | New field `SCRIPT_NAMESPACE` needed |
| "What It Does" section | Partial | `SCRIPT_SUMMARY` gives 2-3 sentences, rest is manual |
| Deploy section | Yes | Template with `SCRIPT_ID` and `SCRIPT_REQUIRES` |
| Verify section | Partial | `SCRIPT_CHECK_COMMAND` for manual check, rest is template |
| Configuration section | No | Service-specific, manual |
| Troubleshooting section | No | Service-specific, manual |
| Learn More | Partial | `SCRIPT_WEBSITE` for first link, rest is manual |

### Approach: Generated + Manual Sections

The generator produces a complete page with all auto-generatable content filled in. Manual sections get placeholder markers:

```markdown
## Configuration

<!-- MANUAL: Service-specific configuration details -->
_No configuration documentation yet. Edit this section to add details._

## Troubleshooting

<!-- MANUAL: Common issues and solutions -->
_No troubleshooting documentation yet. Edit this section to add details._
```

**Key design decision**: The generator does NOT overwrite existing manual content. If a page already exists with manual sections filled in, the generator either:
- Skips that page (safe mode)
- Regenerates only the auto-generated sections while preserving manual sections (smart mode)

Phase 1 implements safe mode. Smart mode (preserving manual content) is a future enhancement.

---

## Phase 1: Add Missing Metadata Fields

Add `SCRIPT_HELM_CHART` and `SCRIPT_NAMESPACE` to all service scripts that use Helm charts. These are needed for the info table.

### Tasks

- [ ] 1.1 Survey all 26 service scripts — identify which use Helm charts vs raw manifests
- [ ] 1.2 Check Ansible playbooks to find Helm chart names and namespaces for each service
- [ ] 1.3 Add `SCRIPT_HELM_CHART` to each service script (e.g., `SCRIPT_HELM_CHART="bitnami/redis"`)
- [ ] 1.4 Add `SCRIPT_NAMESPACE` to each service script (e.g., `SCRIPT_NAMESPACE="default"`)
- [ ] 1.5 For manifest-only services (no Helm), add `SCRIPT_IMAGE` instead (e.g., `SCRIPT_IMAGE="nginx:alpine"`)
- [ ] 1.6 Update `uis-docs.sh` to extract the new fields into services.json

### Validation

- [ ] All 26 service scripts have either `SCRIPT_HELM_CHART` or `SCRIPT_IMAGE`
- [ ] All 26 service scripts have `SCRIPT_NAMESPACE`
- [ ] `uis-docs.sh` generates valid JSON with new fields
- [ ] Existing CLI commands still work (`./uis list`, `./uis deploy`)

---

## Phase 2: Build the Markdown Generator

Create `uis-docs-markdown.sh` (or extend `uis-docs.sh`) that generates markdown pages from service metadata.

### Tasks

- [ ] 2.1 Create `provision-host/uis/manage/uis-docs-markdown.sh` bash script
- [ ] 2.2 Implement `generate_service_page()` function that produces markdown from metadata:
  - Frontmatter from `SCRIPT_NAME`
  - Info table from `SCRIPT_ID`, `SCRIPT_CATEGORY`, `SCRIPT_REQUIRES`, `SCRIPT_HELM_CHART`, `SCRIPT_NAMESPACE`
  - "Required by" via reverse lookup across all scripts
  - "What It Does" from `SCRIPT_SUMMARY`
  - Deploy section with dependency commands from `SCRIPT_REQUIRES`
  - Verify section with `SCRIPT_CHECK_COMMAND`
  - Learn More with `SCRIPT_WEBSITE`
  - Placeholder markers for manual sections (Configuration, Troubleshooting)
- [ ] 2.3 Implement `generate_category_index()` function for category/package index pages
  - Uses package vs category templates from INVESTIGATE-documentation-rewrite
  - Lists services with descriptions and links
  - Package indexes include deploy sequence
- [ ] 2.4 Add safe mode: skip generation if target file already exists (don't overwrite manual content)
- [ ] 2.5 Add `--force` flag to regenerate even if file exists (for fresh generation)
- [ ] 2.6 Add `--dry-run` flag to show what would be generated without writing files

### Output Structure

```
website/docs/services/
├── databases/
│   ├── index.md          ← generated category index
│   ├── postgresql.md     ← generated service page
│   ├── redis.md          ← generated service page
│   └── ...
├── observability/
│   ├── index.md          ← generated package index
│   ├── prometheus.md     ← generated service page
│   └── ...
└── ...
```

### Validation

- [ ] Generator produces valid markdown for all 26 services
- [ ] Generated pages match the template from PLAN-014 (compare with redis.md prototype)
- [ ] Index pages are correct for both package and category types
- [ ] `--dry-run` shows output without writing files
- [ ] Safe mode skips existing files
- [ ] `--force` overwrites existing files
- [ ] Docusaurus builds cleanly with generated pages

---

## Phase 3: Validate Against Prototypes

Compare generated output with the 3 PLAN-014 prototypes to ensure quality.

### Tasks

- [ ] 3.1 Generate pages for redis, whoami, authentik with `--force`
- [ ] 3.2 Diff generated output against existing manually written pages
- [ ] 3.3 Identify gaps — what manual content is missing from the generated version
- [ ] 3.4 Adjust template or metadata to close gaps where possible
- [ ] 3.5 Document remaining manual-only sections

### Validation

- [ ] Generated info tables match the prototypes exactly
- [ ] Auto-generated sections (deploy, verify, learn more) are correct
- [ ] Manual sections are clearly marked with placeholder text
- [ ] User confirms generated quality is acceptable

---

## Phase 4: Integration

Wire the generator into the existing tooling and CI/CD.

### Tasks

- [ ] 4.1 Add `docs-markdown` subcommand to `uis-docs.sh` (or call `uis-docs-markdown.sh` from it)
- [ ] 4.2 Add documentation to `reference/uis-cli-reference.md` for the new command
- [ ] 4.3 Test full generation: `./uis-docs-markdown.sh website/docs/services/`
- [ ] 4.4 Update GitHub Actions workflow to regenerate docs on push (when service scripts change)

### Validation

- [ ] `uis-docs.sh` can generate both JSON and markdown in one run
- [ ] CI/CD regenerates docs when service scripts change
- [ ] Docusaurus builds cleanly after full generation
- [ ] User confirms integration works

---

## Acceptance Criteria

- [ ] All 26 service pages can be generated from metadata
- [ ] 9 category/package index pages can be generated
- [ ] Generated pages follow the PLAN-014 template exactly
- [ ] Manual sections have clear placeholder markers
- [ ] Existing manually written content is not overwritten (safe mode)
- [ ] `--force` and `--dry-run` flags work
- [ ] New services only need a service script — doc page is auto-generated
- [ ] CI/CD regenerates docs when service metadata changes
- [ ] Docusaurus builds cleanly with zero broken links

---

## Files to Modify

### New Files

| File | Purpose |
|------|---------|
| `provision-host/uis/manage/uis-docs-markdown.sh` | Markdown page generator |

### Modified Files

| File | Change |
|------|--------|
| 26 service scripts in `provision-host/uis/services/*/` | Add `SCRIPT_HELM_CHART`, `SCRIPT_NAMESPACE`, `SCRIPT_IMAGE` |
| `provision-host/uis/manage/uis-docs.sh` | Extract new metadata fields, optionally call markdown generator |
| `website/docs/reference/uis-cli-reference.md` | Document new generation command |
| `.github/workflows/deploy-docs.yml` | Add markdown generation step |

### Reference Files (Read Only)

| File | Purpose |
|------|---------|
| `website/docs/services/databases/redis.md` | Template prototype (medium complexity) |
| `website/docs/services/management/whoami.md` | Template prototype (simple) |
| `website/docs/services/identity/authentik.md` | Template prototype (complex) |
| `provision-host/uis/lib/service-scanner.sh` | Existing metadata extraction library |
| `provision-host/uis/lib/categories.sh` | Category definitions and helpers |
