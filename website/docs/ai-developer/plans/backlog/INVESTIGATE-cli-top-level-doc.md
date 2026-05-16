# INVESTIGATE: Top-level UIS CLI doc + keeping command examples in sync

**Status:** Investigation needed
**Created:** 2026-05-14
**Updated:** 2026-05-16 — added "Prior art: DCT conventions" subsection answering the question "can UIS help be auto-generated from source like DCT?"
**Surfaced by:** In-session question after the Tailscale CLI port (PRs #169–#181) — "do we have a command that lists all services and their status?" → realisation that the answer requires reading three separate doc sections, and the reference doc itself is stale.
**Related to:** [INVESTIGATE-tailscale-architecture-cleanup](../completed/INVESTIGATE-tailscale-architecture-cleanup.md) (the work that surfaced the drift; now completed), [PLAN-003 Tailscale docs lift-up](../completed/PLAN-003-tailscale-docs-lift-up.md) (shipped), the Cloudflare port (PRs #169–#172).
**Concrete slices already shipped:**
- [PLAN-tools-docs](../completed/PLAN-tools-docs.md) — split tools docs into a user-facing inventory (`reference/tools.md`) + contributor architecture page; first instance of the "consolidation" strategy (B below).
- [PLAN-tool-installer-error-handling](../completed/PLAN-tool-installer-error-handling.md) — hardening the `install-*.sh` scripts whose output `reference/tools.md` describes; shipped via PR #152 and closed 2026-05-15.

**Related (open):**
- [INVESTIGATE-system-provision-host-tools-and-auth](INVESTIGATE-system-provision-host-tools-and-auth.md) — the broader "what tools should the provision-host carry, how do they persist + auth" investigation. The user-facing `./uis tools` surface this CLI doc covers is the same surface that investigation re-designs from a system/persistence angle.

---

## Problem Statement

`./uis` has grown into a ~60-command CLI spanning service, network, platform, secrets, host, tools, stack, and testing surfaces. Command examples are scattered across **88 markdown files** in `website/docs/` (excluding plan history), with the heaviest concentration in `reference/uis-cli-reference.md`, the per-service walkthroughs, and the platform guides. Each command example is a hand-typed string with no link back to the CLI's actual help text.

Two related issues:

1. **No coherent top-level CLI doc.** A user asking "what listing commands exist?" has to read at least three separate doc pages (services, network, platforms) to learn that `./uis list`, `./uis network list`, and `./uis platform list` form a parallel pattern. The reference doc never frames the three command families as a coherent surface.

2. **Doc-vs-code drift.** When a CLI surface changes, every markdown file that mentions an affected command has to be hand-edited. PRs #169–#181 ported Cloudflare and Tailscale to `uis network ...` — the reference doc still shows the deleted `./uis tailscale expose` and `./uis cloudflare verify` verbs as of today; the `getting-started/services.md` table still had `./uis deploy tailscale-tunnel` until PR #178 caught it. **Drift is not a hypothetical — it's the default state.**

---

## Current state

### Reference doc

`website/docs/reference/uis-cli-reference.md` exists (205 lines). It has decent coverage of Container / Platform / Service / Stack / Secrets / Testing / Host but:

- Documents the **deleted** `./uis tailscale expose/unexpose/verify` verbs (PR #177 turned these into redirect stubs)
- Documents the **deleted** `./uis cloudflare verify/teardown` verbs (PR #169 redirected to `network`)
- Has **zero** coverage of the `./uis network ...` family — the load-bearing CLI surface for cloudflare and tailscale, with 8 sub-verbs (`init`, `list`, `up`, `down`, `status`, `verify`, `expose`, `unexpose`)
- No top-of-page overview framing the CLI's structure
- No mention of the parallel pattern across `./uis list` (services), `./uis network list`, `./uis platform list`

### Command-example density (post-survey)

Top 15 files by `./uis ` mentions, excluding plan archive:

```
  68  reference/uis-cli-reference.md
  53  reference/service-dependencies.md
  43  contributors/rules/kubernetes-deployment.md
  31  platforms/azure-aks.md
  31  networking/tailscale-setup.md
  28  getting-started/services.md
  27  services/integration/postgrest.md
  24  networking/tailscale.md
  17  advanced/how-deployment-works.md
  16  reference/tools.md
  16  ai-developer/plans/active/PLAN-tool-installer-error-handling.md
  15  services/integration/gravitee.md
  15  contributors/guides/adding-a-service.md
  14  platforms/rancher-kubernetes.md
  14  networking/cloudflare.md
```

Across 88 files, several hundred `./uis ...` strings. Each is independent. None reference back to the CLI source.

### Help text in `uis-cli.sh`

The CLI's own help is substantial:
- `cmd_help()` prints a 144-line structured help block when the user runs `./uis help`
- ~60 `cmd_*` functions, each potentially exposing usage strings via its own error path
- Network sub-commands have proper `--help` flags (e.g. `./uis network expose tailscale --help` prints a structured usage block)
- The help text is more current than the reference doc (it gets updated as code changes; the reference doc doesn't)

### Existing precedent: `./uis docs generate`

UIS already has a doc-generation pipeline: `./uis docs generate` runs `uis-docs.sh` which produces JSON data files for the website. Services pages are partially generated from `services.json`, not hand-edited per service. **Generation-from-source is an established pattern in this repo, just not applied to CLI examples yet.**

### Prior art: DCT conventions

DCT (`devcontainer-toolbox/.devcontainer/additions/`) is the sibling repo whose command-script pattern we'd be borrowing from. Looking at it directly:

- **Filename convention**: `cmd-*.sh` (interactive commands), `config-*.sh` (one-shot config), `install-*.sh` (installers). 40 files in `additions/` follow this.
- **Inline metadata block** at the top of each file, after a usage comment:
  ```bash
  #-----------------------------
  # SCRIPT METADATA - For dev-setup.sh discovery
  #-----------------------------
  SCRIPT_ID="cmd-logs"
  SCRIPT_NAME="Log Management"
  SCRIPT_VER="1.0.0"
  SCRIPT_DESCRIPTION="View, monitor, and clean devcontainer logs"
  SCRIPT_CATEGORY="INFRA_CONFIG"
  SCRIPT_PREREQUISITES=""
  ```
- **Usage comment block** above the metadata documents `--help`, `--status`, `--clean`, `--tail <source>`, etc. — one line per subcommand. This is what a generator would scrape.

**Where UIS already matches DCT:** every UIS **service script** and **tool script** under `provision-host/uis/services/` and `provision-host/uis/tools/` already carries `SCRIPT_ID` / `SCRIPT_NAME` / `SCRIPT_DESCRIPTION` / `SCRIPT_CATEGORY`. The `services-table` generator (`uis-docs-services.sh`) walks these and produces the services page. **Same pattern, same field names.**

**Where UIS does NOT match DCT:** `provision-host/uis/manage/uis-cli.sh` is the top-level CLI entry point — ~60 `cmd_*` bash functions in one file (no per-file split, no metadata):

```bash
cmd_list() { … }
cmd_deploy() { … }
cmd_platform_init() { … }
cmd_network_expose() { … }
# … ~60 more
```

`cmd_help()` is a hand-written 144-line `cat <<EOF` block. **No SCRIPT_* metadata exists on these verbs**, so today there's nothing for a generator to scrape.

**What this means for the "auto-generate help" question:**

- The metadata-driven approach **already works** in UIS for service/tool surfaces. The services table is regenerated on every PR.
- For the top-level CLI verbs, two paths:

  | Path | Shape | Cost | Comment |
  |---|---|---|---|
  | **Inline metadata on each `cmd_*` function** | Add a `# DOC:` header block above each function with `VERB:`, `USAGE:`, `SUMMARY:`, `EXAMPLES:` keys. Generator parses the function-by-function block. | Medium — ~60 functions × ~10 min header each ≈ 1 day | Minimal disruption; functions stay in one file; matches DCT's "metadata-inside-script" pattern. |
  | **One file per verb** (DCT-style split) | Move each `cmd_*` to its own `manage/cmd-*.sh` file with full SCRIPT_* metadata block. Top-level dispatcher becomes a thin router. | High — major refactor, touches every CLI surface | Strongest separation but probably overkill for a CLI that's already coherent in one file. |

  Strategy C (above) leans on path 1 — generate from the function-level metadata, not from a file split.

**Direct answer to the question**: yes, UIS already uses the DCT-style metadata pattern for **service/tool scripts**, and yes, a similar pattern is feasible for the **top-level CLI verbs** — but the metadata layer doesn't exist on the `cmd_*` functions yet. Adding it is roughly a 1-day refactor that strategy C depends on.

---

## The drift problem — concrete recent examples

1. **PR #169 (Cloudflare CLI port)** — moved `./uis deploy cloudflare-tunnel` → `./uis network up cloudflare`. The reference doc still has the old "Cloudflare verify/teardown" section.
2. **PR #177 (Tailscale CLI port)** — replaced `./uis tailscale expose/unexpose/verify` with `./uis network expose/unexpose/verify tailscale`. The reference doc Tailscale section still describes the deleted verbs.
3. **PR #178 (Tailscale docs rewrite)** — caught the `./uis deploy tailscale-tunnel` reference in `getting-started/services.md` only because we manually swept the docs; it had been broken since #177 merged.
4. **PR #181 (auto-detect namespace)** — the new flag-less expose behavior is documented in `tailscale.md` but nowhere in the reference doc.
5. **talk52 R5 Nit 1** — even the user-facing claim "verify runs 5 checks (was 6)" turned out to be wrong (actual is 4) and ended up in multiple places before someone counted.

Pattern: every CLI-surface change requires touching N markdown files. Some get touched, some don't. The reference doc is consistently the most-forgotten.

---

## Sync-strategy options

Six strategies to consider, in roughly increasing complexity:

### A. Status quo: manual sync

Every CLI change requires hand-editing every affected markdown file.

- **Pro**: no tooling cost
- **Con**: drift is the default outcome (evidence: 5+ post-merge fixes needed since the Cloudflare port)
- **Verdict**: where we are; insufficient

### B. Single source of truth in docs (consolidation)

Pick one doc page per topic and make every other page link to it instead of duplicating. E.g. `tailscale.md` is the only place that shows `./uis network expose tailscale <svc>`; `tailscale-setup.md` says "see tailscale.md for command details" instead of duplicating.

- **Pro**: zero new tooling; one place to edit per surface
- **Con**: link-heavy reading; reader has to jump to learn what a command does; doesn't help reference-doc drift unless we also commit "the reference doc IS the source of truth for command syntax"
- **Verdict**: cheap, partial fix. Should probably happen regardless. Doesn't solve drift on its own.
- **Evidence (shipped)**: PLAN-tools-docs split tools content into a single user-facing inventory at `reference/tools.md` + a contributor architecture page; 5 cross-refs were retargeted in one pass. Approach worked end-to-end — no tooling needed, the consolidation step itself caught two pieces of stale prose (the deleted `oci` reference, the never-mentioned OpenTofu install) that hand-maintenance had missed for months. Validates B's "cheap, real catch" claim for at least one CLI surface.

### C. Generate the CLI reference from `uis-cli.sh` help text

Build `./uis docs cli-reference` (extending the existing `cmd_docs`) that walks every `cmd_*` function, calls its `--help`, and emits markdown. Commit-time hook or CI runs it; reference doc becomes a generated artifact like services.json.

- **Pro**: reference doc literally can't drift from the code — they're regenerated together. Matches the existing `services.json` precedent. The help text already exists.
- **Con**: requires every `cmd_*` to have a `--help` that emits markdown-friendly text. Today many cmd_* error paths don't have structured help. Refactor cost.
- **Con**: only fixes the reference doc, not the 87 other files with command examples.
- **Verdict**: high-leverage for the reference doc. Should combine with another strategy for the broader drift.

### D. Code-block testing — execute the docs in CI

Every fenced code block tagged `bash` (or specifically annotated `uis-example`) gets executed against the local image in CI; broken commands break the build. Mirrors what doctests do for Python.

- **Pro**: catches drift at PR time, before merge. Forces docs to stay executable.
- **Con**: a lot of `./uis` commands need a real cluster, real Tailscale tailnet, real Cloudflare credentials — not feasible in CI. Most blocks would have to be flagged "documentation only, don't execute," eroding the value.
- **Verdict**: too costly for the cluster-touching majority. Maybe useful for a narrow subset (syntax-only checks).

### E. Linting — grep-based command validator

A script greps every `.md` file for `./uis ` strings and validates them against a known-good list of subcommand names (extracted from `uis-cli.sh`). Doesn't execute anything — just checks "this verb exists" and "this flag exists" at a syntactic level.

- **Pro**: cheap, fast, runs in milliseconds. Catches deleted verbs (the #178 case). Doesn't need a cluster.
- **Pro**: handles 88 files just as easily as 1.
- **Con**: only catches syntactic drift (typos, removed commands). Won't catch semantic drift like "the doc says verify runs 5 checks but actually it's 4."
- **Verdict**: high-leverage for the most common drift type. Cheap enough to run on every PR.

### F. Hybrid: B + C + E

Consolidate where reasonable (B), generate the reference doc (C), and run a lint on every PR to catch the rest (E). Each strategy plugs a different hole.

- **Pro**: each piece is independently small; together they cover most drift
- **Con**: three pieces to build instead of one. But each is small.
- **Verdict**: most likely target. Sequence: E first (cheapest, biggest catch), then B (no tooling), then C (last and most work).

---

## Trade-offs analysis

### What kinds of drift matter most?

Three drift types ranked by how often they bite us:

1. **Deleted/renamed commands** (e.g. `./uis tailscale expose` after PR #177). Most common. Most novice-breaking — the user types a command from the doc and gets an error. Linting (E) catches all of these at PR time.

2. **New commands not documented** (e.g. `--with-cluster-funnel`, auto-detect namespace from PR #181). Common during fast iteration. Generation (C) covers structured changes (`--help` output); doesn't catch behavioral changes that don't change syntax.

3. **Semantic claims that drift** (e.g. "verify runs 5 checks"). Less common; only caught by humans reading carefully. Code-block testing (D) might catch *some* (if a verify step disappears, the test would fail), but the cost outweighs the catch rate.

### Reference doc vs. example sprinkles

Two distinct docs jobs:

- **Reference doc** (`uis-cli-reference.md`) — single canonical "what every command does" page. Reader's intent: "I need to look up the exact syntax of X." High value, low daily traffic. **Best fit for generation (C).**
- **Example sprinkles** (the other 87 files) — embedded in walkthroughs, ADRs, troubleshooting guides. Reader's intent: "I'm trying to do task X, what's the command?" Lots of context per example. **Best fit for consolidation (B) + linting (E).**

The two don't need the same strategy.

### Help-text-as-source-of-truth feasibility

Today's help text:
- `cmd_help()` has a structured 144-line top-level banner
- Network sub-commands have proper `--help` flags with usage + examples
- Many other `cmd_*` functions print a one-line usage on missing args

Pre-conditions for generation (C):
- Every cmd needs structured `--help` output (refactor cost: ~60 functions × ~10 min each = ~10 hours, maybe less if done as a batch)
- A documentation extractor (~200-line shell or Python script)
- Build-time integration with Docusaurus (regenerate before `npm run build`)

Estimate: 1–2 contributor days to get the first useful generation pipeline; ongoing maintenance is "keep adding `--help` to new cmd_* as you write them," which is the same discipline contributors already follow for new commands.

### What about talk.md and verification rounds?

Talk.md isn't in `website/docs/` — it's tester instructions in `/testing/uis1/talk/`. Drift there is caught by the tester running the commands. Out of scope for any CI gate; rely on the human in the loop.

---

## Strawman target state

A future PLAN should ship roughly this:

### 1. A reorganised reference doc

`reference/uis-cli-reference.md` replaced by a top-level overview that:
- Opens with the **three parallel listing commands** (`./uis list`, `./uis network list`, `./uis platform list`) explained as one pattern
- Has a "verb matrix" — for each command family (services, network, platform, secrets, ...), shows which verbs apply (`init`, `up`, `down`, `status`, `verify`, ...). One row per family, columns per verb, ✓ if applicable
- Has detailed command tables per family, generated from `--help` output where feasible
- Has a clear "legacy / redirected commands" section that links removed verbs to their new homes (no more silently-broken examples)

### 2. A generation script

`provision-host/uis/manage/uis-docs-cli.sh` (mirror naming of the existing `uis-docs.sh`) that:
- Walks `cmd_*` functions in `uis-cli.sh`
- For each, calls its `--help` (or extracts a `# DOC: ...` block from the function body if `--help` isn't viable)
- Emits markdown tables / sections into `website/docs/reference/uis-cli-reference.md`
- Invoked by `./uis docs generate cli-reference` (new subcommand)
- Run before `npm run build` so the website always has the latest

### 3. A markdown linter for command examples

`provision-host/uis/tests/static/test-doc-commands.sh` (mirror of the existing static tests):
- Walks every `.md` in `website/docs/`
- Extracts `./uis <verb>` patterns
- Validates each `<verb>` exists in the current `uis-cli.sh`'s case dispatcher
- Validates each `<flag>` (where syntactically extractable) appears in the corresponding `--help`
- Returns non-zero on any unknown verb or flag → fails CI's Static Tests gate

### 4. Consolidation pass on the example sprinkles

Audit the top 15 files (by `./uis ` count) and move duplicated walkthroughs into a single canonical home, with the others linking. Net result: ~half the `./uis ` occurrences disappear because they're now one link instead of N copies.

**Status**: First slice already shipped via PLAN-tools-docs (tools surface: `reference/tools.md` is now the canonical inventory; 5 cross-refs retargeted; the old contributor page pivoted to architecture-only). Remaining surfaces to consolidate: services (esp. integration-services like postgrest/gravitee), networking (partially done by PLAN-003 — `tailscale.md` is now canonical), platforms (azure-aks.md heavy duplication with the AKS manual-setup runbook). Tools is the proof point; the remaining surfaces follow the same pattern.

---

## Open questions for the PLAN

1. **Where does the top-level doc live in the sidebar?** Currently it's `reference/uis-cli-reference.md` (a deep nested page). Should it be promoted to `cli.md` at the top level, alongside `getting-started/` / `networking/` / `platforms/`? Or stay in `reference/` as a power-user lookup?
2. **What's the contract between the doc and the `--help` output?** Option: the doc IS the `--help` output (DRY). Option: the doc has additional context + framing the help text can't have. Picking one shapes the generation script.
3. **How aggressive is the linter?** Hard-fail on unknown verbs (catches drift, but blocks PRs on minor doc typos)? Or warn-only with a periodic sweep? Mirrors the `onBrokenLinks: warn` choice Docusaurus already made.
4. **Migration sequence.** Do we start by writing the new doc by hand (one-time effort, then drift starts again), or invest in generation first (slower start, durable result)? Cheap-first vs durable-first.
5. **What's the right granularity for the linter?** Verb-level only? Verb + first flag? Full string match against a regex of known patterns?

---

## Outcomes / what this investigation should decide

Before a PLAN can be written:

- [ ] Decision on which strategy combination to pursue (A/B/C/D/E/F or some subset)
- [ ] Decision on sidebar placement of the top-level doc
- [ ] Decision on linter aggressiveness (hard-fail vs warn)
- [ ] Decision on migration sequence (hand-write first vs generate first)
- [ ] Survey of which existing `cmd_*` functions have decent `--help` today and which need refactoring (the work of (C))
- [ ] Decision on whether the existing `reference/uis-cli-reference.md` is rewritten in place or replaced + redirected

---

## Implementation Contracts (to satisfy a future PLAN)

If/when a PLAN is written from this investigation, it must define:

- **C-1: Top-level CLI doc shape.** What sections, what order, who maintains. Source-of-truth question answered.
- **C-2: Help-text shape per `cmd_*`.** Required format so generation works. Migration steps for cmd_* functions that don't conform today.
- **C-3: Generation script contract.** Inputs (which files to read), outputs (which doc paths to write), invocation point (npm run build prehook? Static Tests step?).
- **C-4: Linter contract.** What it catches, what it ignores, where it runs, how it surfaces failures.
- **C-5: Consolidation map.** Which of the 87 sprinkle-files lose their command examples in favor of links, and where the canonical example lives for each command family.
- **C-6: Legacy-command redirect inventory.** All commands that were deleted/renamed in PRs #169–#181 + earlier, with a single doc location mapping each to its replacement.
