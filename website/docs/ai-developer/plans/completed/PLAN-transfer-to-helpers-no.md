# Plan: Transfer urbalurba-infrastructure to helpers-no

**Status:** Completed

**Goal**: Transfer this repo from `terchris/urbalurba-infrastructure` to `helpers-no/urbalurba-infrastructure` with zero downtime.

**Priority**: Medium

**Completed**: 2026-03-19

**Overall plan**: See `/Users/terje.christensen/learn/projects-2026/testing/github-helpers-no/INVESTIGATE-move-repos-to-helpers-no.md`

---

## Prerequisites

- **PLAN-transfer-to-helpers-no** in devcontainer-toolbox must be complete (container image at `ghcr.io/helpers-no/`)
- Recommended: sovereignsky-site and dev-templates transfers complete first

**This repo transfers last** — it is the most complex and depends on devcontainer-toolbox.

---

## Problem

The repo lived under `terchris/urbalurba-infrastructure`. There were 85 references to `terchris` across 41 files. This repo also published its own container images (postgresql) to `ghcr.io/terchris/` and had GitHub Actions workflows that needed updating.

---

## Phase 1: Create branch and fix references

### Tasks

- [x] 1.1 Create branch `move-to-helpers-no`
- [x] 1.2 Replace `ghcr.io/terchris/devcontainer-toolbox` → `ghcr.io/helpers-no/devcontainer-toolbox` in:
  - `.devcontainer/devcontainer.json`
- [x] 1.3 Replace `ghcr.io/terchris/urbalurba-` → `ghcr.io/helpers-no/urbalurba-` in own container images:
  - `containers/postgresql/build.sh`
  - `containers/postgresql/Dockerfile`
  - `manifests/042-database-postgresql-config.yaml`
- [x] 1.4 Update GitHub Actions workflow:
  - `.github/workflows/build-postgresql-container.yml` — update image registry path
- [x] 1.5 Replace `terchris/urbalurba-infrastructure` → `helpers-no/urbalurba-infrastructure` in install/CLI scripts:
  - `uis` script
  - `uis.ps1`
  - `website/static/install.sh`
  - `website/static/install.ps1`
  - `website/static/uis` and `website/static/uis.ps1`
  - `provision-host/uis/manage/uis-cli.sh`
  - `provision-host/uis/manage/uis-backstage-catalog.sh`
- [x] 1.6 Update docs/website references (~15 active doc files):
  - `website/docusaurus.config.ts`
  - `website/docs/` — about, index, getting-started, contributors, services, developing, reference, ai-developer/README
- [x] 1.7 `.gitignore` — `/terchris` entry kept (contains local secrets folder)
- [x] 1.8 Commit all changes to branch — merged as PR #94

### Validation

All references updated. Grep returns zero critical hits.

---

## Phase 2: Transfer repo and update container images

### Tasks

- [x] 2.1 Transfer repo on GitHub: Settings → Transfer → `helpers-no`
- [x] 2.2 Verify GitHub redirect works
- [x] 2.3 ~~Check GH Actions has permissions to publish to `ghcr.io/helpers-no/` (postgresql image)~~ — N/A: custom PostgreSQL container was removed entirely in PR #95 (Bitnami now ships all extensions pre-built)
- [x] 2.4 Merge `move-to-helpers-no` branch (PR #94)
- [x] 2.5 ~~Trigger container image builds~~ — N/A: no custom container images remain

### Validation

Repo is at `https://github.com/helpers-no/urbalurba-infrastructure`.

---

## Phase 3: Re-enable GitHub Pages

### Tasks

- [x] 3.1 GitHub Pages survived the transfer — no re-enable needed
- [x] 3.2 Custom domain: `uis.sovereignsky.no` (was already configured, not `dct.sovereignsky.no` as originally planned)
- [x] 3.3 Site is live at https://uis.sovereignsky.no/

### Validation

Website loads correctly.

---

## Phase 4: Update local clone and Kubernetes manifests

### Tasks

- [x] 4.1 Update local git remote: `git remote set-url origin https://github.com/helpers-no/urbalurba-infrastructure.git`
- [x] 4.2 No running clusters referenced old image paths at time of transfer

### Validation

`git remote -v` shows `helpers-no/urbalurba-infrastructure`.

---

## Bonus: PostgreSQL Container Removal (PR #95)

During the transfer, the custom PostgreSQL container build (`ghcr.io/helpers-no/urbalurba-postgresql`) was failing because Bitnami removed all version-pinned Docker tags. Investigation revealed that Bitnami's current image (PostgreSQL 18.3) now ships all 8 extensions we previously built manually:

| Extension | Version | Purpose |
|-----------|---------|---------|
| pgvector | 0.8.2 | Vector similarity search for AI embeddings |
| PostGIS | 3.6.2 | Geospatial data types and queries |
| hstore | 1.8 | Key-value pairs within a single column |
| ltree | 1.3 | Hierarchical tree-like data |
| uuid-ossp | built-in | UUID generation |
| pg_trgm | 1.6 | Fuzzy text search and trigram matching |
| btree_gin | 1.3 | Additional indexing strategies |
| pgcrypto | 1.4 | Cryptographic functions |

**Resolution**: Removed the custom container entirely (Dockerfile, build script, CI workflow, docs page) and switched to `bitnami/postgresql` pinned by digest. All 8 dependent services verified correct.

---

## Acceptance Criteria

- [x] Repo is at `https://github.com/helpers-no/urbalurba-infrastructure`
- [x] ~~Container images publish to `ghcr.io/helpers-no/`~~ — N/A: no custom container images
- [x] Website is live at `uis.sovereignsky.no`
- [x] Install scripts (`uis`, `uis.ps1`) work from new location
- [x] GitHub Actions workflows run successfully
- [x] No remaining `terchris` references in critical scripts/manifests
- [x] Old URL redirects work
