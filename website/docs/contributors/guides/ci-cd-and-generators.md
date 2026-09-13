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

### When a comparison proves nothing

:::note This rule is the residue of a near-miss, not foresight
It is written down because someone made the mistake and something caught it —
not because anyone derived it in advance. Kept in that form at the tester's own
request: *"I made this mistake and here is what caught it"* gets followed; the
same sentence as a derived principle gets skimmed.
:::

A tester verified a UIS release with `UIS_IMAGE=…:1.6.67` three times against a
container that had been up nine hours on 1.6.65, saw the new feature missing
every time, and was one message from reporting the fix broken. `./uis` returns
early when a container is already running — **before** it looks at the image — so
the override was dropped in silence.

What caught it was diffing the output under both versions and getting
**byte-identical text**. If the override had applied, the two runs *must* differ
— that is the entire point of the fix being in the newer one. Identical output
was proof the override never took effect, **not** proof the fix was absent.

**The rule, once you have the story:** two configurations that *must* differ and
don't have told you something about your **instrument**, not about the thing you
measured.

:::tip Suspect the instrument before the thing measured
- identical output from two versions that differ → suspect the override
- a status code where you needed a digest → suspect the tag
- a check that passed without running → suspect the guard

Since 1.6.70 the launcher refuses rather than ignoring: an override a warm
container cannot honour stops the command and names the restart.
:::

### Announcing a release whose change is host-side

`./uis` is a **host-side file**. It does not arrive with the image.

:::danger A digest is the right identity for an image and the wrong instruction for a launcher fix
1.6.70's guard lived entirely in the launcher and was announced by image digest.
Everyone who acted on that got the new runtime and kept the old guard — and
believed they were protected while getting exactly the behaviour the guard
exists to stop. The tester pulled the image, restarted, ran the guard's own
test, got exit 0, and only avoided reporting a working fix broken because it
grepped its own launcher.
:::

So when the change is in `./uis`, announce in this order:

1. **`./uis pull`** — the instruction that actually delivers it.
2. **The A/B that proves it arrived**, e.g. for 1.6.70: run a disagreeing
   `UIS_IMAGE` against a warm container; *if it exits 0, the launcher did not
   update, whatever `docker images` says*.
3. **The image digest**, last, as identity rather than instruction.

Since 1.6.73 `./uis --check` answers this itself: it no longer says *"Up to
date."* about the image while the launcher is stale, and an unreachable check
reads as **could not check**, never as stale.

:::warning Check the command you are about to publish, on the version you are publishing
`--check` was reachable only as `pull --check` until 1.6.74. The release notes
for 1.6.73 told a tester to run `./uis --check` — written by the launcher's own
maintainer — and it fell through to the catch-all, which **starts the container**
and answers with a usage block headed by the version.

The tester ran it on **both** sides of the upgrade and got identical output,
differing only in the version string the same message had told them to distrust.
**The instruction for using the freshness check reproduced the exact failure the
freshness check exists to remove.**

An announcement is a command someone will paste. Run it, on the version you are
announcing, before you send it.
:::

#### Constructing a stale launcher, to test the check that finds one

The behind-path is awkward to test on a real host, and a tester named why:
**the pull that would create a stale launcher is the same pull that fixes it.**

`UIS_LAUNCHER_PATH` is the way in — `update_launcher` already honours it for the
same reason. Make a copy that is genuinely old: a real launcher with one dispatch
label renamed, so it still parses and still passes the *"does this look like the
launcher"* checks, and differs from what `pull` would fetch.

```bash
FIX=$(mktemp -d); cp ./uis "$FIX/uis"
sed -i 's/^    --check|check)/    --check-OLD|check-OLD)/' "$FIX/uis"

UIS_LAUNCHER_PATH="$FIX/uis" ./uis --check      # must NOT say "Up to date"
UIS_LAUNCHER_PATH="$FIX/uis" ./uis pull         # must report what it did
```

To exercise the **offline** path, point the fetch somewhere unreachable — it must
read as *could not check*, never as stale:

```bash
UIS_RAW_BASE="https://unreachable.invalid" ./uis --check
```

:::note Why this is in the guide rather than only in the tests
The unit suite constructs the same fixture, so the behind-path is covered in CI.
This recipe exists because *stub-tested* and *host-tested* are different claims,
and the person who can make the second one is not the person who wrote the stub.
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
