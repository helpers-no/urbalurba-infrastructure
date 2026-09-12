# CI/CD Pipelines and Generators

This page documents the repository's GitHub Actions workflows and the generator scripts they call. If you're adding or modifying services, you need to know what's automated — so you don't manually edit auto-generated files or break the pipeline.

## GitHub Actions Workflows

The repository has 4 workflows in `.github/workflows/`:

| Workflow | File | Triggers on |
|----------|------|-------------|
| [Generate UIS Documentation](#generate-uis-documentation) | `generate-uis-docs.yml` | Push to main (service/tool/plan changes) |
| [Test UIS Scripts](#test-uis-scripts) | `test-uis.yml` | PRs and pushes (UIS code changes) |
| [Deploy Documentation](#deploy-documentation) | `docs.yml` | Push to main (website changes) |
| [Build UIS Container](#build-uis-container) | `build-uis-container.yml` | Push to main (provisioning changes) |

All workflows also support manual dispatch via the GitHub Actions UI.

---

### Generate UIS Documentation

**File**: `generate-uis-docs.yml`

**Triggers when these paths change on main:**
- `provision-host/uis/services/**` — service definitions
- `provision-host/uis/tools/**` — tool definitions
- `provision-host/uis/lib/categories.sh` — category definitions
- `provision-host/uis/lib/stacks.sh` — stack definitions
- `provision-host/uis/manage/uis-docs.sh` — JSON generator
- `provision-host/uis/manage/uis-docs-markdown.sh` — Markdown generator
- `provision-host/uis/manage/uis-docs-plan-indexes.sh` — plan index generator
- `website/docs/ai-developer/plans/**` — plan files

**What it does (3 jobs):**

1. **Generate** — runs the 3 generator scripts in order:
   - `uis-docs.sh` → generates JSON files
   - `uis-docs-markdown.sh` → generates Markdown service pages
   - `uis-docs-plan-indexes.sh` → generates plan index pages
   - Validates JSON with `jq`
   - Auto-commits changes back to `main` if anything changed
2. **Build** — runs `npm run build` in `website/` to verify the site builds
3. **Deploy** — deploys the built site to GitHub Pages

**Key detail:** This workflow has `contents: write` permission and **commits directly to main**. If you push a service definition change, you'll see an automatic commit like `chore: regenerate UIS documentation` appear shortly after.

---

### Test UIS Scripts

**File**: `test-uis.yml`

**Triggers when `provision-host/uis/**` changes** (PRs and pushes to main).

**What it does (4 parallel jobs):**

| Job | What it runs | When |
|-----|-------------|------|
| `static-tests` | `provision-host/uis/tests/run-tests.sh static` | Always |
| `unit-tests` | `provision-host/uis/tests/run-tests.sh unit` | Always |
| `json-generation` | `uis-docs.sh` + `jq` validation | Always |
| `deploy-tests` | `provision-host/uis/tests/run-tests.sh deploy` | Manual dispatch only (requires kind cluster) |

Static and unit tests run on every PR that touches UIS code. Deploy tests require a Kubernetes cluster (kind) and are only triggered manually.

---

### Deploy Documentation

**File**: `docs.yml`

**Triggers when `website/**` changes** on main.

Builds and deploys the Docusaurus site to GitHub Pages. This is the standard deployment for manual documentation changes (as opposed to auto-generated changes which go through `generate-uis-docs.yml`).

Both workflows use the same `pages` concurrency group, so they won't run simultaneously.

---

### Build UIS Container

**File**: `build-uis-container.yml`

**Triggers when these paths change on main:**
- `ansible/**`, `manifests/**`, `hosts/**`, `cloud-init/**`, `networking/**`
- `provision-host/**`, `scripts/**`
- `Dockerfile.uis-provision-host`

Builds a **multi-architecture** (linux/amd64 + linux/arm64) container image and pushes to:

```
ghcr.io/<owner>/uis-provision-host:latest
```

This is the container that users pull when they run `./uis start`.

---

---

## Before you tell anyone a version is ready

**Releasing is the maintainer's job, not the pipeline's.** GitHub Actions runs
the build; it does not own the outcome. A merge hands the work to a machine and
hands none of the responsibility with it — if you announce a version, you are
asserting that the image exists, and that assertion is yours to check.

:::danger `version.txt` cannot answer "what did we ship"
It is bumped when the PR **merges**, and reads identically whether the container
build finished, is still running, or failed. It is the most natural thing to
check and it is the wrong one.
:::

A release commit reaches `main` **10–15 minutes before its image does** (median
12, measured across ten consecutive successful builds) — and never at all if the
build breaks. So a green merge is not a shipped version.

Check the **digest**, not the tag, before handing work to anyone:

```bash
VERSION=$(cat version.txt)
TOK=$(curl -s "https://ghcr.io/token?scope=repository:helpers-no/uis-provision-host:pull&service=ghcr.io" \
  | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
curl -sI -H "Authorization: Bearer $TOK" \
  -H 'Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json' \
  "https://ghcr.io/v2/helpers-no/uis-provision-host/manifests/$VERSION" \
  | grep -i docker-content-digest
```

**Empty output means the image is not there yet — do not pass the ball.**

:::note Why the digest and not the status code
A status code says a tag *resolves*. A digest says *which image*. Both matter,
and they fail differently: a 404 means the build has not finished, while a 200
on `:latest` can mean the tag has moved to a different version since you looked.
:::

### Why this is a documented step

It has cost two round trips. A tester measured `1.6.58` during its build window,
found a 404, and filed it as a **release blocker** — correctly, because from the
far end a 404 and a broken release are identical. Nobody was slow and nothing was
broken. The same thing happened again with `1.6.63`, and was only absorbed
because the tester recognised the shape from the previous night.

If you hit the 404 anyway, `./uis --check` and `./uis pull` both now tell you how
long a build takes and whether to wait or go looking — but the cheaper fix is not
to hand over an unpublished version in the first place.

## Generator Scripts

Four scripts in `provision-host/uis/manage/` generate documentation from service metadata:

### uis-docs.sh — JSON Data Files

**Reads:** service definitions, categories, stacks, tools
**Writes:**

| Output file | Content |
|-------------|---------|
| `website/src/data/services.json` | All services with full metadata |
| `website/src/data/categories.json` | Category definitions |
| `website/src/data/stacks.json` | Stack definitions with components |
| `website/src/data/tools.json` | Optional CLI tools |

These JSON files are consumed by the Docusaurus website to render the services page, stack pages, and other dynamic content.

### uis-docs-markdown.sh — Service Documentation Pages

**Reads:** service definitions
**Writes:** `website/docs/services/<category>/<id>.md` for each service

**Modes:**
- Default (safe mode): skips files that already exist — only creates new pages
- `--force`: overwrites existing files
- `--dry-run`: shows what would be generated without writing
- `--service <id>`: generates only for a specific service

Pages include deployment commands, dependency info, and metadata pulled from the service script. Manual content can be preserved in sections marked with `<!-- MANUAL: ... -->` comments.

### uis-backstage-catalog.sh — Backstage Catalog YAML

**Reads:** service definitions, API metadata
**Writes:** `generated/backstage/catalog/` directory with:
- Domain, system, component, resource, API, group, and user entities
- `all.yaml` master Location file

**Modes:**
- `--dry-run`: preview without writing
- `--output-dir <dir>`: custom output directory

:::note
This script is **not yet called by any CI/CD workflow**. It must be run manually when you need to regenerate the Backstage catalog.
:::

### uis-docs-plan-indexes.sh — Plan Index Pages

**Reads:** plan files in `website/docs/ai-developer/plans/`
**Writes:**
- `plans/index.md`
- `plans/active/index.md`
- `plans/backlog/index.md`
- `plans/completed/index.md`

Each index page contains a sorted table of plans with metadata extracted from the files.

---

## Auto-Generated Files — Do Not Edit

The following files are auto-generated by CI/CD. Do not manually edit them — your changes will be overwritten on the next push to main:

| File | Generated by |
|------|-------------|
| `website/src/data/services.json` | `uis-docs.sh` |
| `website/src/data/categories.json` | `uis-docs.sh` |
| `website/src/data/stacks.json` | `uis-docs.sh` |
| `website/src/data/tools.json` | `uis-docs.sh` |
| `website/docs/ai-developer/plans/*/index.md` | `uis-docs-plan-indexes.sh` |

Service Markdown pages (`website/docs/services/`) are only overwritten if you run `uis-docs-markdown.sh --force`. In safe mode (default in CI/CD), existing pages are preserved.

---

## Running Generators Locally

You can run the generators locally to preview changes before pushing:

```bash
# Generate JSON files
bash provision-host/uis/manage/uis-docs.sh

# Generate Markdown pages (safe mode — won't overwrite existing)
bash provision-host/uis/manage/uis-docs-markdown.sh

# Generate Markdown for one service
bash provision-host/uis/manage/uis-docs-markdown.sh --service postgresql

# Preview without writing
bash provision-host/uis/manage/uis-docs-markdown.sh --dry-run

# Generate plan indexes
bash provision-host/uis/manage/uis-docs-plan-indexes.sh

# Generate Backstage catalog
bash provision-host/uis/manage/uis-backstage-catalog.sh
```

---

## Related Documentation

- **[Adding a Service](./adding-a-service.md)** — How service metadata feeds into generators
- **[Kubernetes Deployment Rules](../rules/kubernetes-deployment.md)** — Service metadata specification
- **[Integration Testing](./integration-testing.md)** — How `test-uis.yml` relates to local testing
