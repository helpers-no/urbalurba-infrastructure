# Investigate: Documentation Restructuring for Docusaurus

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed

**Goal**: Determine what documentation improvements are needed and prioritize them.

**Last Updated**: 2026-02-18

**Related Plan**: [PLAN-002-json-generator](PLAN-002-json-generator.md) - Implements metadata extraction and JSON generation

**Outcome**: Investigation identified the data-driven documentation approach (from DCT). Key findings:
- JSON data files created (`services.json`, `categories.json`, `stacks.json`)
- Brand assets structure established
- Data-driven React components implemented
- CI/CD pipeline generates JSON from script metadata
- Implementation delivered via PLAN-002 and PLAN-004D/E/F series

---

## Questions to Answer

1. What is the current state of all documentation files?
2. Which documents are missing proper frontmatter (title, description)?
3. Are there broken internal links?
4. Which services in `manifests/` lack documentation?
5. Is the sidebar navigation logical and consistent?
6. Are there any outdated or incorrect documents?
7. What content improvements would have the highest impact?

---

## Current State

The documentation has been migrated from MkDocs to Docusaurus with the following structure:

```
website/docs/
├── ai-developer/     # AI-assisted development workflow
├── getting-started/    # Installation and overview
├── hosts/              # Infrastructure host setup
├── networking/         # Tailscale, Cloudflare configuration
├── packages/           # Service documentation (AI, databases, etc.)
├── provision-host/     # Provisioning scripts and tools
├── reference/          # Technical reference
├── rules/              # Configuration rules
└── index.md            # Homepage
```

### Known Issues (to investigate)

- Unknown: Which `_category_.json` files need position updates
- Unknown: Documents missing frontmatter
- Unknown: Broken links between documents
- Unknown: Services without documentation
- Unknown: Outdated content

---

## Investigation Tasks

- [ ] Audit all `_category_.json` files and their positions
- [ ] List all documents and check frontmatter completeness
- [ ] Run link checker to find broken internal links
- [ ] Compare `manifests/` folder with `packages/` docs to find gaps
- [ ] Review each section's index.md for completeness
- [ ] Test build and note any warnings/errors
- [ ] Check sidebar navigation flow

---

## Findings: Data-Driven Documentation

### Discovery

The DevContainer Toolbox project uses JSON files to drive documentation generation:
- `website/src/data/tools.json` - Individual tool/service metadata
- `website/src/data/categories.json` - Category definitions

These files enable:
- Auto-generated service cards on homepage
- Consistent metadata across documentation
- Dynamic navigation and filtering
- Related service suggestions

### UIS Adaptation

For UIS, we need similar files adapted for Kubernetes services:

**Categories identified** (from `website/docs/services/`):
1. AI - OpenWebUI, Ollama, LiteLLM
2. Authentication - Authentik
3. Databases - PostgreSQL, MySQL, MongoDB, Qdrant
4. Monitoring - Grafana, Prometheus, Loki, Tempo
5. Queues - Redis, RabbitMQ
6. Search - Elasticsearch
7. DataScience - Spark, JupyterHub, Unity Catalog
8. Core - Traefik, storage
9. Management - pgAdmin, RedisInsight
10. Development - ArgoCD

**Proposed file structure:**
```
website/src/data/
├── categories.json    # Service category definitions
└── services.json      # Individual service metadata
```

**Service metadata fields:**
- id, name, description, category
- tags, abstract, summary
- logo, website
- manifest (reference to YAML file)
- docs (link to documentation)
- related (links to related services)

### Terminology Issue: "Packages" vs "Categories"

**Current state:**
- DCT uses "categories" for grouping tools
- UIS uses "packages" in documentation (`website/docs/services/`)
- This creates inconsistency between projects

**Locations using "packages":**
- `website/docs/services/` - folder name
- Sidebar navigation
- Documentation links
- Homepage references

**Decision:**
- JSON files should use "categories" (consistent with DCT, more generic term)
- Documentation harmonization (packages → categories) is a larger task for a separate plan
- The JSON structure is prepared for future harmonization

### Initial Files Created (Draft)

Draft JSON files have been created at:
- `website/src/data/categories.json` - 10 categories
- `website/src/data/services.json` - 23 services

**Note:** These are drafts and need review before being used. The JSON uses "categories" terminology to align with DCT and prepare for future documentation harmonization.

### Asset Structure: Brand and Logos

**DCT asset structure:**
```
website/static/img/
├── brand/                    # Brand assets
│   ├── cube-code.svg         # Logo variants
│   ├── cube-code-green.svg
│   ├── social-card-*.png     # Social media cards
│   └── mit-svg/              # MIT-licensed base components
│       ├── code.svg
│       ├── cube.svg
│       └── shield.svg
├── categories/               # Category logos
│   ├── ai-tools-logo.webp
│   ├── cloud-tools-logo.webp
│   └── src/                  # SVG sources
│       └── *.svg
├── tools/                    # Service/tool logos
│   ├── dev-python-logo.webp
│   ├── tool-kubernetes-logo.webp
│   └── src/                  # SVG sources
│       └── *.svg
└── illustrations/            # Feature illustrations
    └── *.png
```

**UIS current state:**
```
website/static/img/
├── docs/                     # Empty
└── logo.svg                  # Main logo only
```

**UIS needs:**
```
website/static/img/
├── brand/                    # Brand assets (SovereignSky)
├── categories/               # Category logos (10 categories)
│   └── src/
├── services/                 # Service logos (23+ services)
│   └── src/
└── illustrations/            # Feature illustrations
```

**Logo requirements:**
- 10 category logos (AI, Authentication, Databases, etc.)
- 23+ service logos (OpenWebUI, PostgreSQL, Grafana, etc.)
- Format: SVG source + WebP for web
- Style: Consistent with SovereignSky branding (green #3a8f5e / teal #25c2a0)

### Brand Assets Created

**Main logo created:**
- Source: `~/Downloads/uis-branding/uis-logo-pyramid-clean.svg`
- Destination: `website/static/img/brand/uis-logo-green.svg`
- Colors adjusted to SovereignSky brand (#3a8f5e, #4fb87b)
- Docusaurus config updated to use new logo

**Logo design:**
- Cloud outline (represents cloud infrastructure)
- Pyramid of 6 cubes (represents building blocks/services)
- Green gradient matching SovereignSky branding

**Branding folder structure created:**
```
website/static/img/brand/
└── uis-logo-green.svg    # Main site logo
```

**Still needed:**
- Category logos (10)
- Service logos (23+)
- Social card image
- Favicon update

---

## Options

### Option A: Quick Fixes Only

Focus only on critical issues:
- Fix broken links
- Add missing frontmatter
- Correct navigation positions

**Pros:**
- Fast to implement
- Minimal disruption
- Low risk

**Cons:**
- Doesn't address content gaps
- May miss important improvements

### Option B: Comprehensive Restructure

Full documentation overhaul:
- Fix all technical issues
- Add missing service documentation
- Improve cross-references
- Add troubleshooting guides

**Pros:**
- Complete solution
- Better user experience
- Future-proof

**Cons:**
- More time required
- Larger scope of changes

### Option C: Phased Approach

Start with quick fixes, then address content in follow-up plans:
1. First plan: Technical fixes (links, frontmatter, navigation)
2. Second plan: Content additions (missing docs, guides)
3. Third plan: Enhancements (cross-references, examples)

**Pros:**
- Manageable chunks
- Can pause between phases
- Progressive improvement

**Cons:**
- Multiple PRs needed
- Takes longer overall

---

## Recommendation

[To be filled after investigation]

---

## Next Steps

- [ ] Complete investigation tasks above
- [ ] Document findings in this file
- [ ] Choose approach (A, B, or C)
- [ ] Create PLAN-*.md file(s) with chosen approach
