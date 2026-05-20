# INVESTIGATE: Harmonise the UIS CLI grammar — `uis <noun> <verb> [target]` everywhere

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Investigation needed
**Created:** 2026-05-16
**Surfaced by:** In-session discussion (2026-05-16) while scoping a small `uis connect <service>` → `uis service connect <service>` change. Realisation that the rename is one slice of a broader pattern: `uis network <verb>` and `uis platform <verb>` already follow `<noun> <verb>`, but ~12 top-level legacy verbs (`deploy`, `undeploy`, `connect`, `configure`, `expose`, `list`, `status`, `verify`, `enable`, `disable`, `sync`, plus per-service one-offs like `enonic verify`) don't.

**Related (open):**
- [INVESTIGATE-cli-connect-add](./INVESTIGATE-cli-connect-add.md) — proposes `uis service connect <service> [arg]` as the first concrete migration; this investigation is the umbrella it slots into.
- [INVESTIGATE-cli-top-level-doc](./INVESTIGATE-cli-top-level-doc.md) — doc-drift / auto-generated help. Once the grammar locks, that work has a stable target. The two investigations feed each other.
- [INVESTIGATE-docs-services-in-cluster-port](./INVESTIGATE-docs-services-in-cluster-port.md) — extends the SCRIPT_* metadata block on per-service scripts with an `inClusterPort` field. Same metadata-as-source-of-truth pattern; benefits from the grammar work locking the script-as-canonical-source principle but doesn't gate it.

**Related (closed):**
- PR #169–#172 ([PLAN-network-cloudflare-port-and-docs-lift-up](../completed/PLAN-network-cloudflare-port-and-docs-lift-up.md)) — first time we promoted a legacy top-level verb (`uis cloudflare …`) into the `uis network <verb> cloudflare` umbrella.
- PR #177–#181 (Tailscale CLI port, completed) — same shape for Tailscale.

---

## Problem statement

UIS has organically grown two CLI shapes side-by-side:

1. **`<noun> <verb>` umbrella verbs** — coherent, kubectl-like. Five umbrellas exist today:

   | Umbrella | Verbs |
   |---|---|
   | `uis platform <verb> [provider]` | init, list, up, down, status, use |
   | `uis network <verb> [provider]` | init, list, up, down, status, verify, expose, unexpose |
   | `uis secrets <verb>` | init, status, edit, generate, apply, validate |
   | `uis tools <verb> [tool]` | list, install |
   | `uis stack <verb> [stack]` | list, info, install, remove |
   | `uis host <verb> [host]` | add, list, generate, create |

2. **Top-level legacy verbs** — flat, predate the umbrella pattern. ~12 of these still operate without a noun:

   ```
   uis deploy <service>             uis configure <service>
   uis undeploy <service>           uis expose <service>
   uis connect <service>            uis list
   uis enable <service>             uis status
   uis disable <service>            uis verify
   uis list-enabled                 uis sync
   uis enonic verify                uis tailscale … (already aliased to network)
   uis nextcloud verify             uis cloudflare … (already aliased to network)
   uis backstage verify             uis argocd <verb>  (own umbrella, scoped to argocd only)
   uis openmetadata verify
   ```

The mismatch costs us:

- **Cognitive load.** "What's the verb for working with a service vs. a platform vs. a network?" requires reading 88 doc pages to learn.
- **Doc drift.** Top-level verbs get aliased or renamed (Tailscale, Cloudflare ports already did this), each rename forcing a sweep of dozens of markdown files. See [INVESTIGATE-cli-top-level-doc](./INVESTIGATE-cli-top-level-doc.md) for the drift evidence.
- **Help text fragmentation.** `uis platform --help` and `uis network --help` produce coherent verb lists. There's no parallel `uis service --help` because no `service` umbrella exists yet, so the per-service operations are scattered across `uis help`'s 144-line block.
- **No precedent for new surfaces.** A contributor adding a new noun (e.g., `uis backup`, `uis logs`) has no canonical "this is how UIS CLI surfaces work" reference.

## Goal

Lock in a single grammar — **`uis <noun> <verb> [target] [args]`** — across every command family, with a migration sequence that ships incrementally without leaving the CLI in a half-migrated state for extended periods.

This investigation produces a **target grammar table** (which nouns, which verbs per noun, which legacy verbs map where) and a **migration sequencing decision** (which PLAN goes first, what's the alias / cutover policy per migration). It does NOT produce the migrations themselves — each is a separate PLAN.

## The 9-noun target grammar (strawman)

| Noun | Verbs | Notes |
|---|---|---|
| `service` | deploy, undeploy, connect, configure, port (was `expose`), list, status, verify, enable, disable, sync, logs, describe, exec | New umbrella. Receives most of the legacy top-level verbs. |
| `network` | init, list, up, down, status, verify, expose, unexpose | Unchanged — already canonical. |
| `platform` | init, list, up, down, status, use | Unchanged — already canonical. |
| `secrets` | init, status, edit, generate, apply, validate | Unchanged. |
| `tools` | list, install | Unchanged. |
| `stack` | list, info, install, remove | Unchanged. |
| `host` | add, list, generate, create | Unchanged. Existing-shape decision; cloud-VM provisioning surface. |
| `argocd` | register, remove, list, verify | Unchanged. Could fold into `service`-style argocd subcommands later; out of scope here. |
| `docs` | generate | Existing meta-noun used to regenerate website data files (`uis-docs.sh`, `uis-docs-services.sh`, etc.). The grammar already fits — kept as the 9th noun rather than buried in "meta commands." |

Top-level non-noun commands that stay top-level (meta only):
```
uis help / --help / -h           # global help
uis version / --version / -v     # version string
uis setup                        # entry to the TUI (see TUI section + M-3 below for naming)
uis init                         # first-run bootstrap; distinct from `uis <noun> init`, see below
uis test-all                     # CI integration test runner
uis template                     # template runner; legacy, revisit (likely future `uis service template` or `uis stack template`)
uis catalog                      # legacy; revisit
uis cluster                      # legacy; revisit
```

### `uis init` vs `uis <noun> init` — they're different concepts

`uis init` is the **first-run bootstrap** — sets up the `.uis.secrets/` tree, copies default templates, registers the user's identity. It's a once-per-machine operation, idempotent on re-run. Per-noun `init` (`uis platform init azure-aks`, `uis network init cloudflare`, `uis secrets init`) is **per-noun-instance setup** — runs once per cluster / provider / secrets-set. Different scope; the name collision is unfortunate but the semantics are distinct.

Resolution options:
- **Keep both, document the distinction** in the CLI reference — `uis init` is bootstrap, `uis <noun> init` is per-instance. Lowest disruption.
- **Rename top-level to `uis bootstrap`** — clearer at the surface, breaks every existing first-run walkthrough doc.
- **Promote to `uis self init`** — treat the meta-utility as its own noun. Cleaner namespace but adds a one-verb noun.

The decision can be deferred until the rest of the grammar lands; nothing earlier blocks on it. Tracked as part of D-10 below.

### Legacy meta-commands — `uis catalog` and `uis cluster`

Both are marked "legacy; revisit" but the investigation owes a concrete plan:

- **`uis catalog`** — built the Backstage software catalog YAML (per `manage/uis-backstage-catalog.sh`). With Backstage moving to `uis service backstage` operations + a generic `uis service describe` surface, `catalog` is a candidate for absorption into `uis service catalog` (still single-verb, but namespaced) or deletion if nobody calls it.
- **`uis cluster`** — appears to be a thin wrapper around kubectl context operations, predating `uis platform use`. Likely deletable; investigate call sites before removing.

Both deferred to D-11 below — needs a usage survey before deciding.

## Mapping table — every legacy verb's future home

| Today | Future | Notes |
|---|---|---|
| `uis deploy <service>` | `uis service deploy <service>` | Most-typed legacy verb. Alias retention is the big question. |
| `uis undeploy <service>` | `uis service undeploy <service>` | Same shape. |
| `uis connect <service>` | `uis service connect <service> [arg]` | The cli-connect-add migration. First concrete slice. |
| `uis configure <service>` | `uis service configure <service> [opts]` | |
| `uis expose <service>` | `uis service port <service>` | **Renamed verb** — `expose` collides with `network expose` (publishing). `port` is shorter + clearer for port-forward. Alternative: `forward`. |
| `uis list` | `uis service list` | |
| `uis status` | `uis service status` | |
| `uis verify` | `uis service verify [<name>]` | When no name, runs all known service-verifies. |
| `uis enable <service>` | `uis service enable <service>` | |
| `uis disable <service>` | `uis service disable <service>` | |
| `uis list-enabled` | `uis service list --enabled` | Becomes a flag. |
| `uis sync` | `uis service sync` | |
| `uis enonic verify` | `uis service verify enonic` | Dispatched by service-script metadata; no per-service hardcoded verbs. |
| `uis nextcloud verify` | `uis service verify nextcloud` | Same. |
| `uis backstage verify` | `uis service verify backstage` | Same. |
| `uis openmetadata verify` | `uis service verify openmetadata` | Same. |
| `uis tailscale …` | `uis network <verb> tailscale` | Already done (PRs #177–#181). Top-level alias still exists today; review removal. |
| `uis cloudflare …` | `uis network <verb> cloudflare` | Already done (PRs #169–#172). Same. |

## Verb consistency across nouns — the shared core

Across the umbrellas, five verbs appear repeatedly:

```
init    — per-noun setup / scaffolding (platform, network, secrets)
list    — enumerate instances          (platform, network, tools, stack, host, service)
up      — bring instance into service  (platform, network)
down    — tear instance down           (platform, network)
status  — health / state               (platform, network, secrets, service)
```

These should keep **structurally consistent shape** across nouns — same usage pattern (`uis <noun> <verb>`), same exit-code conventions, same output shape where applicable. Interactivity varies by domain: `platform init` and `network init` are interactive wizards; `secrets init` is a non-interactive one-shot template copy. That's an acceptable per-domain difference, not a grammar break.

One important caveat on the related verbs:

- **`up / down` vs. `deploy / undeploy`.** `up/down` fit when the noun owns infrastructure (a cluster, a tunnel). `deploy/undeploy` fit when the noun is software running on someone else's infrastructure (a service in a cluster). Don't unify these — the semantic distinction is load-bearing.

Verbs unique to one noun (and why):

- `use` — platform-only. Sets the active kubectl context (per [INVESTIGATE-active-cluster-visibility-ux](../completed/INVESTIGATE-active-cluster-visibility-ux.md)).
- `expose / unexpose` — network-only. Publishes a service via the provider's tunnel.
- `verify` — network + service. Already shared.
- `connect / port / configure / enable / disable / sync / logs / describe / exec` — service-only. Per-pod / per-deployment operations.
- `edit / generate / apply / validate` — secrets-only. The render-and-apply pipeline.
- `install / remove` — tools, stack. The package-manager pattern.

## Script structure — the developer-facing reflection of the grammar

**The script split is a required outcome of this investigation, not an option.** Best practice is to keep scripts in manageable units organised by responsibility; a 2731-line monolith with ~60 functions spanning 8+ command families is the anti-pattern this investigation closes. D-8 below decides *when* the split lands relative to the verb migrations; it does not decide *whether* the split happens.

The user-facing grammar restructure has a natural mirror in the code: today `provision-host/uis/manage/uis-cli.sh` is **2731 lines** and carries ~60 `cmd_*` functions for every command family in one file. It's the only file in the repo that's genuinely too large; most other lib/manage files sit at 250–550 lines, and service-metadata scripts are 35–60 lines by design. Data:

| File | Lines | Notes |
|---|---|---|
| `manage/uis-cli.sh` | **2731** | The outlier. ~60 cmd_* functions across 8+ command families. |
| `manage/uis-backstage-catalog.sh` | 877 | Single-service catalog builder; bounded scope. |
| `lib/configure-postgrest.sh` | 786 | Per-service configure handler — sibling pattern, one file per multi-instance service. |
| `lib/integration-testing.sh` | 760 | Test runner — single responsibility. |
| Most lib/ files | 250–550 | Normal bash territory. |
| `services/**/service-*.sh` (metadata) | 35–60 | Already tiny by design. |

### The split

Once the grammar is locked, the noun boundaries become the natural file split:

```
manage/
├── uis-cli.sh            # thin dispatcher: 200 lines max, just routes verb → handler file
├── cmd-service.sh        # all cmd_service_* functions
├── cmd-network.sh        # all cmd_network_* functions (already coherent, just extract)
├── cmd-platform.sh       # all cmd_platform_* functions
├── cmd-secrets.sh        # all cmd_secrets_* (the dispatcher; logic still in lib/secrets-management.sh)
├── cmd-tools.sh          # all cmd_tools_*
├── cmd-stack.sh          # all cmd_stack_*
├── cmd-host.sh           # all cmd_host_*
├── cmd-argocd.sh         # all cmd_argocd_* (if kept as its own umbrella per D-5)
└── cmd-meta.sh           # help, version, setup, init, docs, catalog, template, test-all
```

Each `cmd-*.sh` file carries its own metadata block at the top — the same SCRIPT_* convention that service/tool scripts already use:

```bash
#!/bin/bash
SCRIPT_ID="cmd-service"
SCRIPT_NAME="Service Commands"
SCRIPT_DESCRIPTION="Per-service operations: deploy, undeploy, connect, configure, logs, status, verify"
SCRIPT_GROUP="cli-noun"
```

And each `cmd_<noun>_<verb>` function inside the file carries a `# DOC:` block (per [INVESTIGATE-cli-top-level-doc](./INVESTIGATE-cli-top-level-doc.md)'s strategy C) that feeds both `--help` output and the generated reference doc. Three concerns — grammar lock-in, file-size, doc-generation — close together with one consistent split.

### Why this scales

- **Mechanical mapping.** "Which file holds `cmd_service_deploy`?" → `manage/cmd-service.sh`. No surprise.
- **Per-file context window.** `cmd-service.sh` will end up around 400–600 lines, well within readability. `cmd-network.sh` is already ~250 lines worth of code (the existing `cmd_network_*` block) and would extract cleanly.
- **Aligned with the doc-generation pipeline.** A generator walks the `cmd-*.sh` files and produces one section per file in the reference doc. The file boundary IS the section boundary in the rendered doc.
- **Test isolation.** A bug in service-deploy logic only touches `cmd-service.sh`; merging concurrent CLI work becomes less conflict-prone.

### Tradeoffs

- **More files to grep when looking for a verb.** Mitigated by the mechanical noun-prefix mapping (the verb name itself tells you which file). A `grep -rn "cmd_service_" manage/` is still fast.
- **Cross-cutting helpers must move to `lib/`.** Functions like `_uis_cluster_banner` (currently nestled in `uis-cli.sh`) are used by multiple noun-handlers. The split forces them into a shared `lib/cli-helpers.sh` — a healthy consequence, not a cost.
- **One refactor of ~2700 lines.** The split itself is a single mechanical PR (extract function blocks; verify dispatcher still routes correctly; tests still pass). Not zero cost; not large either.

### Sequencing options (when, not whether)

The script split **will** land; D-8 picks one of three points relative to the user-facing grammar migration:

- **Before any verb migration** — split first along the existing CLI shape (the file split mirrors the verb names as they exist today, e.g. `cmd-deploy.sh` for the top-level `cmd_deploy`). Subsequent grammar migrations move functions between files as verbs are renamed. **Most "structural plumbing first" approach.**
- **With each verb migration** — every grammar migration PR also pulls its functions into the right `cmd-<noun>.sh` file. Migration PRs grow slightly but the split happens organically. **Most incremental approach.**
- **After all verb migrations** — keep `uis-cli.sh` monolithic through the grammar restructure, then split once the grammar is stable. **Least disruption to in-flight grammar work, but the 2731-line file stays a maintenance burden longer.**

The PLAN that follows this investigation needs to pick one (D-8 in Open Decisions, below).

## TUI — the visual reflection of the grammar

A third reflection of the grammar shows up at the user-interaction layer: an interactive terminal UI for users who'd rather click through menus than memorise verb names. **UIS already has the foundation** — `provision-host/uis/lib/menu-helpers.sh` (253 lines) wraps `dialog` (with `whiptail` fallback) into reusable primitives (`show_menu`, `show_checklist`, `show_yesno`, `show_inputbox`, `show_msgbox`), and `./uis setup` opens a 4-option main menu today (Services / Tools / Status / Exit) that drills into category-based service checklists. Coverage is limited to service-enablement + tools + status; it doesn't span network, platform, secrets, stacks, or per-service action verbs.

The prior art is DCT's `dev-setup.sh` (2802 lines, ~70 `dialog` calls). Same `dialog`-based stack, same SCRIPT_* metadata-driven menu generation, but scaled across more nouns and with per-item action drill-downs. UIS's nascent TUI is the same shape, just less complete.

### The structural alignment

Once the grammar is locked, the TUI structure mirrors the noun list:

```
UIS Main Menu
├── Services      → category menu → per-service action menu (deploy / undeploy / connect / configure / status / verify)
├── Networking    → provider menu → per-provider action menu (init / up / down / status / verify / expose / unexpose)
├── Platforms     → provider menu → per-platform action menu (init / up / down / status / use)
├── Secrets       → flat action menu (init / status / edit / generate / apply / validate)
├── Tools         → tool list with install actions
├── Stacks        → stack list with install / remove actions
├── Hosts         → host list with add / generate / create
├── ArgoCD        → cluster list with register / remove / list / verify  (kept or folded per D-5)
└── Quit
```

Each top-level menu entry is one noun. Each drill-down menu's items come from walking the corresponding directory for SCRIPT_* metadata — services from `provision-host/uis/services/`, platforms from `platforms/`, networking providers from `networking/`, etc. Per-item action menus are the verbs from the grammar.

### Why this scales

- **No parallel content to maintain.** The TUI's menu items are SCRIPT_NAME / SCRIPT_DESCRIPTION (already there). The action verbs match the grammar exactly. Adding a new service auto-appears in the TUI; renaming a verb in the grammar renames the TUI label.
- **The TUI becomes a thin renderer.** ~80% of the TUI code is layout calls into `menu-helpers.sh`; the data is the SCRIPT_* metadata. DCT's 2802-line `dev-setup.sh` has roughly 1900 lines of layout + 900 of action wiring; UIS would land somewhere similar.
- **One metadata model, four surfaces.** Same SCRIPT_* blocks that feed (1) the CLI `--help` text, (2) the generated reference doc, (3) the script-split file boundaries, drive the TUI menu hierarchy too. Cohesion across surfaces is the point.

### Tradeoffs

- **Substantial new code.** A full per-noun TUI is ~1000–1500 lines on top of the existing 253-line `menu-helpers.sh`. The grammar/script-split work doesn't pay for this — it's additive scope.
- **Another doc surface.** Users need to know the TUI exists; the CLI reference needs to mention it; the getting-started flow probably should default to it. Modest doc-debt.
- **`dialog` is a runtime dependency.** Already met in the dev container (`provision-host`), and `menu-helpers.sh` falls back to `whiptail`, then to text prompts. Worth confirming the fallback chain actually works before scoping a full TUI rollout.
- **Discoverability tension.** A TUI is great for new users (no need to know verb names); it's friction for power users who want to script. Keep both surfaces; let the TUI be opt-in (`uis setup` or `uis --tui`), not default.

### Sequencing options

The TUI extension can land at any of three points:

- **Before grammar migrations** — extend `cmd_setup` to cover all 8 nouns now, against today's CLI shape. Then each grammar migration touches both the CLI and the TUI labels. **Highest in-flight churn.**
- **In parallel with grammar migrations** — each grammar migration PR also extends the TUI for that noun (e.g., the `service connect` PR adds Services → per-service → Connect to the TUI). **Most incremental, naturally bounded per-PR.**
- **After grammar migrations** — defer TUI work until the grammar is fully migrated. Build it once, against the final shape. **Cleanest result, latest delivery.**

The PLAN that follows this investigation needs to pick one (D-9 in Open Decisions, below).

## Migration scope — what every per-verb PLAN owns

A migration is not just "rename the verb." Each migration PLAN owns six surfaces. The first concrete PLAN (cli-connect-add) is the prototype; later migrations copy the discipline.

### 1. The CLI surface

- Add the new `cmd_<noun>_<verb>` function (in `cmd-<noun>.sh` if the script split has happened, else inside `uis-cli.sh`).
- Wire the dispatcher so the new form works.
- For aliased migrations: keep the old `cmd_<verb>` function delegating to the new one. For hard-cutover migrations: delete the old function and remove its case-arm from the top-level dispatcher.

### 2. Internal callers

`./uis <legacy-verb>` is invoked from several non-user places that the doc-sweep won't catch:

- **Ansible playbooks** under `ansible/playbooks/` — any `command: ./uis deploy …` task.
- **Lifecycle scripts** under `platforms/*/scripts/` (e.g. `02-post-apply.sh` chains `./uis secrets apply`).
- **Stack install** (`uis stack install`) — calls `./uis deploy <service>` for each member service. After the service-deploy migration, the stack-install code in `lib/stacks.sh` must call the new form.
- **CI workflows** under `.github/workflows/` — `test-uis.yml` and any others invoking the CLI.
- **Tester walkthroughs** under `testing/uis1/talk/*.md` — for archived rounds, leave alone; for the active round, update.

Each migration PLAN's scope MUST `grep -rn "uis <legacy-verb>" --include='*.sh' --include='*.yml' --include='*.yaml'` and list every hit. Hard-cutover migrations break every uncaught caller.

### 3. Documentation

Per G-3 (doc-sweep scope is declared). Migration PLAN states big-bang sweep, lazy sweep, or linter-gated. Specific files affected listed in the PLAN's "Files to Modify" section.

### 4. Tests

- **Aliased migrations**: tests cover both `uis <legacy>` and `uis service <new>` forms until the alias is removed (per G-5).
- **Hard-cutover migrations**: tests for the legacy form are deleted in the same PR. New tests for the new form ship in the same PR. The static-test files under `provision-host/uis/tests/static/` are the owner's responsibility — the migration PLAN lists which test files change.

### 5. Help text + reference doc

Per G-4. `cmd_help()`'s legacy block is updated. If the help-text generator has shipped (D-6), the new function's `# DOC:` block is added in the same PR.

### 6. Rollback discipline

Each migration PR has a defined rollback path:

- **Aliased migrations** — rollback is "tell users to keep using the legacy form." The new form coexisting doesn't break anyone.
- **Hard-cutover migrations** — rollback is `git revert <PR-merge-commit>`. The PLAN's summary names the commit hash that gets reverted if the tester finds a regression. The CI pipeline must allow reverting a docs PR without breaking the build (i.e., the docs that referenced the new form get reverted alongside).

For hard-cutovers, the migration PLAN also lists what symptom signals a revert vs. what signal is a fix-forward. Default: anything that breaks the tester's reasonable expectation of the previous shape is a revert candidate.

### `uis <noun>` no-verb behavior

When a user types `uis service` with no verb, behavior should be consistent across all umbrellas:

- **Default contract**: print structured help for the noun (the equivalent of `--help`), exit code 1 (signals "you didn't complete the command"). Mirrors what `cmd_platform` and `cmd_network` already do.
- **Exception**: `uis secrets` (no verb) currently defaults to `status` — this is a documented convenience that's been in the wild long enough to keep. The exception is enumerated in the help text.

The migration that introduces `cmd_service` must follow the default contract.

## Open decisions

The PLAN that follows this investigation needs to answer:

1. **D-1: Alias retention policy.** Three options:
   - **Hard cutover** (no aliases) — clean grammar from day one, but breaks every walkthrough doc, every CI script, every tester's muscle memory at once.
   - **Permanent aliases** — `uis deploy <service>` works forever, `uis service deploy <service>` is the documented form.
   - **One-release alias window** — alias prints a deprecation warning, removed in the next release.

   Default recommendation (per-verb, not global):
   - **Permanent aliases** for high-traffic legacy verbs typed by humans daily: `deploy`, `undeploy`, `list`, `status`, `verify`. The doc-sweep can lag; muscle memory is preserved indefinitely.
   - **Hard cutover** for low-traffic verbs: `connect` (locked 2026-05-16; cli-connect-add precedent), `configure`, `enable`, `disable`, `sync`, `list-enabled`, `expose` (will be renamed to `port`), and the per-service one-offs (`enonic verify`, `nextcloud verify`, `backstage verify`, `openmetadata verify`).

   This is a guideline. Each migration PLAN's summary states the final decision per G-2; the per-verb call can deviate from the default if the migration author has reason.

2. **D-2: Migration order.** Default: the 7-step sequence in "Migration sequence — strawman" below (which serves as the worked example for this decision). D-2's job is to confirm the ordering or propose an alternative; the table below is what the PLAN cites if D-2 is accepted as-is.

3. **D-3: `uis expose` → `uis service port`?** The verb rename is contentious. Three options:
   - **Rename to `port`** — short, clear, no collision with `network expose`.
   - **Rename to `forward`** — verbose but matches `kubectl port-forward`.
   - **Keep `expose`** — accept ambiguity with `network expose`; rely on noun-prefixing for disambiguation.

4. **D-4: Per-service verify field shape.** Location is resolved by the doc-in-script principle — the SCRIPT_* metadata block in the per-service script is the source of truth; `services.json` is generated from it. The real open question is the field's *shape*:
   - **Single-command form** — `SCRIPT_VERIFY_COMMAND="curl -fs http://localhost:8080/health"`. Cheap; can be eval'd directly. Fits simple cases but not multi-step verify (e.g. Authentik's "check pod up → call /api/v3/admin/system/ → assert version").
   - **Multi-step form** — `SCRIPT_VERIFY_COMMAND="$(cat <<'EOF' ... EOF)"`. A small shell block. More expressive but verifies become opaque to static analysis.
   - **Path to script form** — `SCRIPT_VERIFY_SCRIPT="../verify-<name>.sh"`. The per-service verify lives in its own file, the metadata just points at it. Cleanest separation, more files.
   
   Pick one in the PLAN that ships `uis service verify` (migration #2). The existing per-service verify functions (`cmd_enonic_verify`, etc.) are roughly 50–150 lines each — closer to "path to script" than "single command" in practice.

5. **D-5: `argocd` umbrella as-is or fold in.** `uis argocd <verb>` is per-cluster-management (register, remove, list, verify clusters with ArgoCD). It's coherent on its own. Question: leave it alone, or fold into `uis service argocd <verb>`? The former preserves a tight namespace; the latter is more uniform.

6. **D-6: Help text generation.** Once the grammar is locked, [INVESTIGATE-cli-top-level-doc](./INVESTIGATE-cli-top-level-doc.md)'s strategy C (auto-generate from source) has a stable target. Decide whether to gate the first migration on shipping the help-generation infrastructure, or do migrations and help-gen in parallel.

7. **D-7: Doc-sweep policy per migration PR.** Each migration touches dozens of markdown files. Strategies:
   - **Big-bang sweep per migration** — the PR that migrates `connect` also rewrites every `./uis connect …` reference in docs.
   - **Lazy sweep** — leave old references; rely on aliases. Sweep when convenient.
   - **Linter-gated** — the markdown linter from [INVESTIGATE-cli-top-level-doc](./INVESTIGATE-cli-top-level-doc.md) (strategy E) catches stale references at PR time, forcing the sweep.

   Default recommendation: lazy sweep with linter as backstop, once the linter ships.

8. **D-10: `uis init` vs `uis <noun> init` resolution.** Three options laid out in "The 9-noun target grammar" above. Default recommendation: keep both, document the distinction. Cleanest UX after migration would be `uis bootstrap` (or `uis self init`), but the disruption is not worth it pre-migration.

9. **D-11: `uis catalog` and `uis cluster` fate.** Both marked legacy. PLAN that migrates them must first run a usage survey (`grep` across ansible playbooks, CI workflows, the website, internal scripts). Most likely outcome: `uis catalog` absorbs into `uis service catalog` (or becomes a verb on a "backstage-cataloged" service); `uis cluster` deletes if it's just a kubectl wrapper.

10. **D-12: TUI entry-point name.** Today the TUI is reached via `uis setup`. After the grammar migration, the TUI is the visual reflection of the noun grammar (every noun appears as a top-level menu entry). `uis setup` is semantically misleading — it implies first-run bootstrap, not a navigation tool for ongoing use. Options:
   - **Keep `uis setup`** — established muscle memory; rename later if at all.
   - **Add `uis tui` as an alias** — both work; the new name is documented.
   - **Rename to `uis tui` (hard cutover)** — name matches function; breaks anyone who'd been typing `uis setup` daily.
   
   Defer until the TUI extension ships per D-9.

## Migration sequence — strawman

| Order | Migration | Why this slot |
|---|---|---|
| 1 | `uis service connect` (cli-connect-add) | Smallest blast radius. Establishes the alias-vs-cutover precedent. |
| 2 | `uis service verify` (folds in enonic/nextcloud/backstage/openmetadata) | Cleans up 4 per-service one-offs in one shot. Validates the SCRIPT_* metadata dispatch pattern. |
| 3 | `uis service logs` + `uis service describe` (new verbs, no legacy) | Fills out the umbrella with siblings that have no legacy form to alias. Coherence win for `--help`. |
| 4 | `uis service list` + `uis service status` | Touches the most user-visible commands. Permanent aliases recommended. |
| 5 | `uis service enable / disable / list-enabled / sync` | The enablement subsystem. Self-contained. |
| 6 | `uis service deploy / undeploy / configure` | The big one. Permanent aliases. Doc sweep is large. |
| 7 | `uis service port` (rename from `expose`) | Resolve the `expose` collision last, once the grammar is consistently noun-prefixed everywhere else. |

After step 7, every legacy top-level verb has a home in `uis service <verb>`, and `uis help` is dominated by the noun-prefixed shape.

## Early-exit clause

The grammar table above can be revised by the first migration PLAN. Do not block the first PLAN on having every edge case resolved. The grammar must be **plausible and stable enough** that the first migration's choices won't need to be reversed — that's the bar.

Specifically:

- The noun list (`service / network / platform / secrets / tools / stack / host / argocd / docs`) must be locked.
- The verbs `init / list / up / down / status` must have structurally consistent shape across umbrellas where they appear (interactivity may vary by domain — see Verb consistency section).
- The first migration's noun (`service` for `service connect`) must be the right umbrella.
- The Migration scope section (6 surfaces per PR + no-verb behavior) must be agreed; G-1 through G-9 are the contracts.
- D-1's per-verb default must be agreed (the hard-cutover-for-low-traffic / aliased-for-high-traffic split, with `connect` already locked as hard-cutover).
- **The script split is a committed outcome** (not an option). D-8 governs only its timing relative to the verb migrations; the monolith does not persist past the grammar restructure.

Everything else (D-3, D-4, D-5, D-6, D-7, D-8, D-9, D-10, D-11, D-12) can be refined during individual PLAN drafting.

## Out of scope

- **The auto-generated help-doc infrastructure** — that's [INVESTIGATE-cli-top-level-doc](./INVESTIGATE-cli-top-level-doc.md)'s job. This investigation locks the grammar; that one wires the docs to it.
- **kubectl plugin shape (`kubectl uis …`)** — interesting future direction but orthogonal to fixing the bare `uis` CLI grammar.
- **Shell completion (`uis completion bash|zsh`)** — also out of scope; flows naturally from a coherent grammar but doesn't gate the migration.
- **Bash → Go rewrite.** Whatever language `uis-cli.sh` is, the grammar question is the same.

## Outcomes / what this investigation should decide

Before any migration PLAN can be written:

- [ ] Lock the 8-noun list (or revise it).
- [ ] Lock the shared verb core (`init / list / up / down / status`) and its per-noun applicability.
- [ ] D-1 (alias policy): tiered (high-traffic permanent, low-traffic cutover) or uniform.
- [ ] D-2 (migration order): the 7-step sequence above, or a different ordering.
- [ ] D-3 (`expose` rename): port, forward, or stay.
- [ ] D-4 (per-service verify dispatch): metadata location.
- [ ] D-5 (argocd umbrella): fold or keep.
- [ ] D-6 (help-gen sequencing): gate first migration on help-gen, or parallel.
- [ ] D-7 (doc-sweep policy per PR): big-bang, lazy, or linter-gated.
- [ ] D-8 (script-split sequencing — *when*, not whether): before any verb migration (structural plumbing first) / with each verb migration (organic) / after all verb migrations (least disruption to in-flight work). The split itself is a locked outcome per the Script structure section.
- [ ] D-9 (TUI extension sequencing): before / in-parallel-with / after the grammar migrations. Also: scope question — does the TUI cover all 9 nouns or only a subset (services + networking + platforms as the first slice)?
- [ ] D-10 (top-level `uis init` vs per-noun `init`): keep both with doc-distinction / rename top-level to `uis bootstrap` / promote to `uis self init`.
- [ ] D-11 (`uis catalog` and `uis cluster` fate): defer to a usage-survey PLAN; most likely outcome is absorb-or-delete.
- [ ] D-12 (TUI entry-point name): keep `uis setup` / add `uis tui` alias / hard-rename. Defer until TUI extension lands.

## Implementation contracts (to satisfy each migration PLAN)

- **G-1: Grammar table is the contract.** Every migration PLAN must cite the target row from the mapping table; no migration may deviate without revising this investigation first.
- **G-2: Alias-or-cutover is declared upfront.** Each migration PLAN states D-1's outcome for its specific verb in its summary.
- **G-3: Doc-sweep scope is declared.** Each migration PLAN lists which markdown files it touches and whether the sweep is big-bang or deferred.
- **G-4: Help text reflects the new shape.** Wherever help text lives — today's hand-written `cmd_help()`, tomorrow's auto-generated reference doc from `# DOC:` blocks, or both during transition — gets updated on every migration PR. Implementation-agnostic.
- **G-5: Tests for both forms during alias window.** If a verb is aliased, the test suite covers both forms until the alias is removed. For hard-cutover migrations, legacy-form tests are deleted in the same PR.
- **G-6: New `cmd_*` functions land in the right `cmd-<noun>.sh` file.** The script split is committed (per Script structure section); D-8 only governs timing. Every migration PLAN that lands after the split places new or moved functions in the correct file. Migration PLANs landing before the split note in their summary that follow-up extraction is owed once D-8's chosen split-PR ships.
- **G-7: TUI labels match the CLI shape.** Once the TUI extension lands (per D-9), every grammar migration PR updates both the CLI verb and the TUI menu label so the two surfaces never drift.
- **G-8: Migration scope is exhaustive.** Each migration PLAN's "Files to Modify" section lists every hit from a `grep -rn` for the legacy verb across `provision-host/`, `ansible/`, `platforms/`, `.github/`, and `website/docs/` — not just the CLI files. Internal callers (per the Migration scope section above) are first-class scope.
- **G-9: Rollback path is named.** Each migration PLAN's summary states the rollback strategy (live with alias / `git revert <commit>` for hard-cutovers) and the trigger conditions for invoking it.
