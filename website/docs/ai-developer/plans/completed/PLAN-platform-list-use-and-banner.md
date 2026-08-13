# Plan: `./uis platform list / use` + per-command platform banner

## Status: Completed — shipped 2026-05-12

**Shipped**: PRs #161 (initial implementation) + #162 (F15 kubeconf-all seeding) + #163 (F16 legacy lockstep sync) + #164 (F18 pre-merge seed) + #165 (F17 destroyed-context cleanup). All seven Phases of this plan delivered.

**Verified end-to-end** in `testing/uis1/talk/talk.md` round-by-round across talks 48–51:
- talk48: initial verification — surfaced F14 (no-TTY exit in apply prompt), F15 (kubeconf-all not seeded), F16 (silent wrong-cluster deploy via legacy kubeconfig divergence), F17 (post-destroy `✗ unreachable` cosmetic), F18 (seeder gate too narrow → recycle→up→use cascade).
- talk49–50: each F-finding fixed in its own PR, with the lockstep mechanic re-verified each round.
- talk51 (final): full novice path (`./uis tools install azure-aks` → `init` → `up` → `deploy nginx` → `use rancher-desktop` round-trip → `down`) ran end-to-end without manual intervention. All four locations (in-container kubeconf-all, legacy kubeconf-all, `cluster-config.sh` CLUSTER_TYPE + TARGET_HOST) stayed in lockstep. F14/F15/F16/F18 closed; F17 closed in PR #165.

**User-facing documentation** lives in `website/docs/platforms/index.md` (the platform hub) and `website/docs/platforms/azure-aks.md` (the novice walkthrough). The CLI reference at `website/docs/reference/uis-cli-reference.md` carries the full subcommand list.

**Source investigation** (also moved to `completed/` in the same docs PR): [INVESTIGATE-active-cluster-visibility-ux.md](./INVESTIGATE-active-cluster-visibility-ux.md).

---

> **IMPLEMENTATION RULES (historical):** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Active (historical — kept for the plan record below)

**Goal**: Add `./uis platform list` (potential platforms + status), `./uis platform use <name>` (refuse-unless-initialized-and-reachable + lockstep flip), and a per-command banner at the top of every cluster-touching `./uis` command — so a user with 2+ platforms can see what they have, switch safely between them, and tell what platform any command is targeting before it runs. **Layer 4 + Layer 1 of [INVESTIGATE-active-cluster-visibility-ux.md](./INVESTIGATE-active-cluster-visibility-ux.md), bundled per Q2 / C-9.**

**Last Updated**: 2026-05-12 — work started on branch `feat/platform-list-use-and-banner`.

**Source**: [INVESTIGATE-active-cluster-visibility-ux.md](./INVESTIGATE-active-cluster-visibility-ux.md) — design questions Q1–Q5 + implementation contracts C-1 through C-9, locked through three gap-and-contradiction sweeps. This PLAN drafts the implementation against those contracts; design decisions don't get revisited here.

**Related (context)**:
- [INVESTIGATE-platform-aks-novice-onboarding.md](./INVESTIGATE-platform-aks-novice-onboarding.md) — sibling investigation that shipped `./uis platform init / up / status / down` via PRs #154–#159. This PLAN extends the `./uis platform` family with `list` + `use` and threads the banner through every cluster-touching command in the same image.

---

## Problem Summary

talk47 closed the AKS novice-onboarding sequence with one operational gap: once the user has `azure-aks` + `rancher-desktop` both potentially in play (and eventually `google-gke` / `aws-eks` / `azure-microk8s`), there's no command that answers either *"what platforms do I have here and what state is each in?"* or *"let me switch to a different one"* without `cat`-ing config files by hand. And even when the user *knows* which platform they're on, no `./uis` command surfaces it before running — so the talk41 stale-port-forward / talk44 phantom-replay class of bug remains live.

This PLAN closes both:

- **`./uis platform list`** — directory-listing-driven inventory of every platform UIS knows how to onboard (plus the always-present rancher-desktop row). Each row shows a state from the C-1 enum (`not-initialized` / `configured-not-running` / `running` / `unreachable`) plus an inline recovery pointer when the platform isn't ready to use.
- **`./uis platform use <name>`** — lockstep flip of `kubectl current-context` + `cluster-config.sh` for a `running`-and-reachable platform. Refuses with a pointer otherwise. `--offline` escape for the "I know it's broken, switch anyway" case.
- **Per-command platform banner** — every cluster-touching `./uis` command (`deploy`, `expose`, `configure`, `undeploy`, `status`, `list`, `stack install`, `test-all`, plus the `./uis platform` family itself) emits a one-line banner before its first action, naming the active platform and confirming reachability. Aborts with a recovery banner if the cluster is unreachable.

The lockstep flip (Q4) is the most invasive piece — it extracts the existing `sed -i` writes from `02-post-apply.sh` (auto-flip on `up`) and `03-destroy.sh` (auto-reset on `down`) into a single shared writer in `provision-host/uis/lib/platform-switching.sh`, then routes all three call sites (`up` / `down` / new `use`) through it. The investigation's "lockstep, never read independently" guarantee for `cluster-config.sh` only holds if all three writers converge.

---

## Out of Scope

- **Layer 2 — coloured PS1 inside `./uis shell`.** Deferred to a separate PLAN (`PLAN-ps1-cluster-tag.md`) — touches the container's bashrc and the Dockerfile, lower priority because Layer 1's banner covers in-shell users too.
- **Layer 3 — `./uis status` cluster header.** Deferred to `PLAN-uis-status-cluster-header.md` — trivial once banner machinery exists, but distinct enough to ship after Layer 4+1 verifies.
- **Host-side kubectl integration** (`k9s`, `lens`, raw `kubectl` from macOS Terminal). The lockstep flip targets only `kubeconf-all` inside the container — host's `~/.kube/config` is the user's environment. See the investigation's "Out of scope" section.
- **Removing `cluster-config.sh` entirely.** Q4's lockstep design makes it a cached projection; a future PLAN could drop it outright once nothing reads it independently. Out of scope here.
- **Cross-cluster broadcasts** (deploying once to multiple platforms). UIS stays single-cluster-per-invocation.
- **Production-vs-sandbox enforcement / typed-name confirms** for `use`. Future PLAN once Layer 2's colour scheme tags platforms by sensitivity.
- **Provisioning new platforms from `list`.** `list` shows what exists; provisioning is `./uis platform up <name>`. No "click to provision" affordance.

---

## Phase 1: Shared helper `provision-host/uis/lib/platform-switching.sh`

The single source of truth for: (1) the reachability probe primitive, (2) the lockstep writer, (3) inventory enumeration, (4) parsing per-platform `status.sh --summary` output. Consumers: `list`, `use`, the per-command banner, `02-post-apply.sh`'s auto-flip-on-up, `03-destroy.sh`'s auto-reset-on-down.

Before writing this file, **read [PLANS.md § Library Reuse Rules](../../PLANS.md#library-reuse-rules)** — verify nothing already in `provision-host/uis/lib/` covers what's needed and that nothing here duplicates `paths.sh` / `utilities.sh` / `logging.sh` functions. New functionality only.

### Tasks

- [ ] 1.1 Create `provision-host/uis/lib/platform-switching.sh` with the following functions. Names are illustrative; the function signatures + behaviors must match the contracts. All functions defensive: `set -euo pipefail` at start of each, no `|| true` masking, no regex on JSON.

  - `pf_active_platform()` — print the active kubectl context to stdout. Empty string if unset. Reads `kubectl config current-context` from `kubeconf-all`.
  - `pf_probe_reachable <context>` — return 0 if reachable, non-zero otherwise. Implementation: `kubectl --context "$1" --request-timeout=3s get --raw /version >/dev/null 2>&1`. Used by C-9 banner + by C-1 state machine.
  - `pf_lockstep_flip <platform>` — atomic write of both halves: `kubectl config use-context "$platform"` AND `sed -i` on `cluster-config.sh` updating `CLUSTER_TYPE` + `TARGET_HOST` to `$platform`. Single call site for the three converging writers (Phase 6).
  - `pf_list_platforms()` — emit the inventory to stdout, one platform name per line. Source: `platforms/*/scripts/init.sh` directory listing, skipping any directory whose name starts with `_` or `.` (per Edge case #8). Hard-codes `rancher-desktop` as the first row (always present).
  - `pf_platform_summary <platform> [--offline]` — invoke `<platform>/scripts/status.sh --summary [--offline]`, capture the tab-separated `<state>\t<hint>` output, validate field 1 is in the C-1 enum, and emit it on stdout. Non-zero exit if the `status.sh` errors or returns malformed output (caller renders `? error` for that row).
  - `pf_banner [--silent-if-set] [--check-reachable]` — print the Layer 1 banner to **stderr** per C-9. Honors `UIS_BANNER_PRINTED=1` env var (set by parent dispatcher to suppress in child invocations, per C-4) when `--silent-if-set` is passed. With `--check-reachable`, runs `pf_probe_reachable` on the active context and emits the four C-9 cases (reachable / unreachable+abort / not-in-platforms / unset). The active platform name comes from `pf_active_platform`. For the unreachable case, calls `pf_platform_summary` on the active platform to pull the platform-specific recovery hint from field 2.

- [ ] 1.2 `chmod +x` not applicable (sourced library, not invoked).

### Validation (Phase 1)

- [ ] 1.3 `bash -n provision-host/uis/lib/platform-switching.sh` parses cleanly.
- [ ] 1.4 Source standalone in a bash subshell, verify each function resolves: `( source provision-host/uis/lib/platform-switching.sh && for f in pf_active_platform pf_probe_reachable pf_lockstep_flip pf_list_platforms pf_platform_summary pf_banner; do type -t "$f" >/dev/null || { echo "missing: $f"; exit 1; }; done && echo "all functions sourceable" )`.
- [ ] 1.5 Manual smoke against the running container: `pf_active_platform` returns the current context (probably `rancher-desktop` post-talk47 destroy); `pf_probe_reachable rancher-desktop` returns 0; `pf_list_platforms` emits `rancher-desktop` + `azure-aks` on separate lines.

---

## Phase 2: Per-platform `status.sh --summary` contracts (C-1)

Two scripts: extend the existing `azure-aks/scripts/status.sh` with `--summary` and `--offline` flags, and add a new trivial `rancher-desktop/scripts/status.sh` that owns its 3-of-4 state machine per C-1's rancher-desktop subsection.

### Tasks

- [ ] 2.1 Extend `platforms/azure-aks/scripts/status.sh` with a `--summary` flag:

  - Without flag: keeps existing human-readable multi-line banner (no behavior change).
  - With `--summary`: emits exactly one tab-separated line `<state>\t<hint>` to stdout per the C-1 enum + state-machine discriminator. Reads env file presence at `.uis.secrets/cloud-accounts/azure-default.env`, kubectl context presence in `kubeconf-all`, and runs `pf_probe_reachable azure-aks` only when both above are present. Hard-codes `--context azure-aks` per C-1's cross-context invocation rule (mirrors PR #158's F12 fix).
  - With `--summary --offline`: same as `--summary` but skips the probe entirely; state outcome follows C-7's reduced table.
  - With `--summary --deep`: same as `--summary` but additionally runs the cloud-API check (`az aks show`) for richer status (cluster age, node-pool details). Sourced by `list --deep`. Time bound: not constrained.

  Hint text for each state (field 2):

  ```
  not-initialized       run './uis platform init azure-aks' to set up
  configured-not-running run './uis platform up azure-aks' to start it
  running               <node-count>× <vm-size> in <region>, k8s <version>
  unreachable           API server timeout after 3s; run './uis platform status azure-aks' for details
  ```

- [ ] 2.2 Create `platforms/rancher-desktop/scripts/status.sh` — minimal status script for the always-present local platform. Mirrors azure-aks's `--summary` behavior but uses the rancher-desktop 3-state machine (no env file; `not-initialized` reinterpreted as "Rancher Desktop not installed or not started"):

  ```bash
  not-initialized  install Rancher Desktop and start it, then './uis start'
  running          local k8s, k3s <version>
  unreachable      start Rancher Desktop
  ```

  Without `--summary` the script emits a short human-readable banner (matches azure-aks's no-flag shape but rancher-desktop has nothing cluster-cost-related to report).

- [ ] 2.3 `chmod +x platforms/rancher-desktop/scripts/status.sh`.

### Validation (Phase 2)

- [ ] 2.4 `bash -n platforms/azure-aks/scripts/status.sh` and `bash -n platforms/rancher-desktop/scripts/status.sh` parse cleanly.
- [ ] 2.5 Manual smoke (current state, in the running container):
  - `bash platforms/rancher-desktop/scripts/status.sh --summary` → `running\tlocal k8s, k3s ...` (since the host's Rancher Desktop is running and probe succeeds).
  - `bash platforms/azure-aks/scripts/status.sh --summary` → `configured-not-running\trun './uis platform up azure-aks' to start it` (env file from talk47 is preserved; no cluster).
  - `bash platforms/rancher-desktop/scripts/status.sh` (no flag) → existing banner output, unchanged shape.
  - `bash platforms/azure-aks/scripts/status.sh` (no flag) → existing banner output, unchanged.
- [ ] 2.6 `--offline` smoke: `bash platforms/azure-aks/scripts/status.sh --summary --offline` returns the same state as 2.5's azure-aks line, but without running the kubectl probe (measurable as <100ms via `time`).

---

## Phase 3: `./uis platform list` command

New dispatcher case in `uis-cli.sh`, delegating to a new `cmd_platform_list` function.

### Tasks

- [ ] 3.1 In `provision-host/uis/manage/uis-cli.sh`, add a `list)` case to `cmd_platform`'s subcommand switch, parallel to `init / up / status / down`. Route to `cmd_platform_list`.

- [ ] 3.2 Add `cmd_platform_list` after `cmd_platform_status`. Sources `platform-switching.sh`. Accepts `--offline` and `--deep` flags (mutually exclusive). Iterates `pf_list_platforms()` output, invokes `pf_platform_summary <platform> [--offline|--deep]` per row **in parallel** (one background bash per platform, `wait` for all, collect into an indexed array preserving order). Renders the table:

  ```
  Active: <pf_active_platform output or appropriate C-2 case>

  PLATFORM         STATUS
  rancher-desktop  ✓ running                   (active)
  azure-aks        · configured, not running   (run './uis platform up azure-aks' to start it)
  ```

  Column widths: platform name padded to longest-name + 2 spaces; status icon + state words padded to "configured, not running" length + 3 spaces; hint flush.

  Row visual treatment by C-1 state:
  - `running` → `✓ running` (green if TTY + not `NO_COLOR=1`)
  - `not-initialized` → `· not initialized` (dim)
  - `configured-not-running` → `· configured, not running` (dim)
  - `unreachable` → `✗ unreachable` (red)
  - Malformed `status.sh --summary` output → `? error` (yellow)

  Active row gets a trailing `(active)` annotation; per C-2, if active context isn't a UIS platform OR isn't set, NO row gets `(active)` and the header `Active:` line surfaces the external/unset state.

- [ ] 3.3 Update `cmd_help`'s `Platform:` section to include `platform list <provider?>    List potential platforms and their status` between `init` and `up`. Use the host-runnable `./uis ...` form per the talk47 follow-up cosmetic memory.

### Validation (Phase 3)

- [ ] 3.4 `bash -n provision-host/uis/manage/uis-cli.sh` parses cleanly.
- [ ] 3.5 Inside the container after Phase 2's status scripts ship + the binary is rebuilt:
  - `uis platform list` → shows rancher-desktop running + azure-aks configured-not-running, completes under 500ms (`time uis platform list`).
  - `uis platform list --offline` → same rows but no probe runs; under 100ms.
  - `uis platform list --deep` → same rows but with extended hint text (`1× Standard_B2s_v2 in westeurope, k8s 1.34` for running azure-aks); 2-5s typical when AKS is up.
  - `uis help` → `platform list` row shown alongside the others, no "not yet implemented" tag.

---

## Phase 4: `./uis platform use <name>` command

New dispatcher case + the lockstep-flip command itself, routing through `pf_lockstep_flip`.

### Tasks

- [ ] 4.1 In `cmd_platform`'s subcommand switch, add a `use)` case routing to `cmd_platform_use`.

- [ ] 4.2 Add `cmd_platform_use` after `cmd_platform_list`. Sources `platform-switching.sh`. Accepts `--offline` flag and an optional `<name>` positional.

  - No `<name>` → interactive picker per C-8: print the same table `list` shows, but only `running` rows get `[N]` selectors; non-selectable rows appear without selectors with their inline pointer. Footer prompt: `Pick a platform [1-N]:`. Plain `read -p`, no `fzf`.
  - With `<name>` → call `pf_platform_summary "$name"`, parse field 1, dispatch per Q5's enum table:
    - `not-initialized` → emit `✗ <name> is not initialized.\n  Run './uis platform init <name>' first.` to stderr, exit non-zero. `--offline` does NOT override.
    - `configured-not-running` → emit `✗ <name> is configured but not running.\n  Run './uis platform up <name>' to start it.` to stderr, exit non-zero. `--offline` does NOT override.
    - `running` → call `pf_lockstep_flip "$name"`, emit `✓ Switched: <from> → <name>` to stdout (using `pf_active_platform` for the `<from>` value, captured before the flip), exit 0. If `<name>` equals the current active platform, treat as a no-op + reachability re-probe: emit `ℹ  Already active: <name>. Re-probing... ✓ still reachable.` and exit 0. If the re-probe fails, emit `✗ <name> is no longer reachable (API server timeout after 3s).` + recovery hint, exit non-zero (active platform doesn't change).
    - `unreachable` → emit `✗ <name> is unreachable (API server timeout after 3s).\n  Check the cluster state with './uis platform status <name>'.\n  To switch anyway (e.g. to clean up stale kubectl state), use --offline.` to stderr, exit non-zero. `--offline` overrides this case only: call `pf_lockstep_flip` despite reachability failure, emit the `✓ Switched: ... (forced; cluster not reachable)` form.

- [ ] 4.3 Update `cmd_help` to add a `platform use <provider>` row.

### Validation (Phase 4)

- [ ] 4.4 `bash -n` clean.
- [ ] 4.5 Inside the container (rancher-desktop running, azure-aks env file present but no cluster):
  - `uis platform use rancher-desktop` (already active) → `ℹ  Already active... ✓ still reachable.`, exit 0.
  - `uis platform use azure-aks` → refuses with `configured-not-running` pointer at `./uis platform up azure-aks`, exit 1.
  - `uis platform use google-gke` → refuses with `not-initialized` pointer at `./uis platform init google-gke`, exit 1.
  - `uis platform use azure-aks --offline` → also refuses (configured-not-running can't be overridden), exit 1.
  - `uis platform use` (no arg) → interactive picker with only rancher-desktop selectable, azure-aks shown without `[N]` + its pointer.

---

## Phase 5: Layer 1 banner — inject into every cluster-touching `./uis` command

Per Q2 + C-9: every cluster-touching command emits the banner to stderr before its first action. Implementation: each `cmd_<verb>` function in `uis-cli.sh` calls `pf_banner --silent-if-set --check-reachable` near its top, before delegating. `--silent-if-set` honors `UIS_BANNER_PRINTED=1` for the `stack install`-child case (C-4).

### Tasks

- [ ] 5.1 In `provision-host/uis/manage/uis-cli.sh`, insert `pf_banner --silent-if-set --check-reachable` at the top of each cluster-touching command function, immediately after argument parsing:

  - `cmd_deploy`
  - `cmd_undeploy`
  - `cmd_configure`
  - `cmd_expose`
  - `cmd_status`
  - `cmd_list` (the service-list, not `cmd_platform_list`)
  - `cmd_stack_install` (parent — sets `UIS_BANNER_PRINTED=1` before invoking children)
  - `cmd_test_all`
  - `cmd_platform_up`
  - `cmd_platform_down`
  - `cmd_platform_status`
  - `cmd_platform_use`
  - `cmd_platform_list`

  **Skip** (no banner) — these don't touch any cluster: `cmd_help`, `cmd_version`, `cmd_container`, `cmd_pull`, `cmd_build`, `cmd_start`, `cmd_stop`, `cmd_restart`, `cmd_shell`, `cmd_tools_*`, `cmd_init` (the UIS-level setup wizard, not platform init), `cmd_platform_init` (creates an env file, no cluster touched yet).

  Wait — `cmd_platform_init` deserves a special note: it logs into Azure (cloud API) but doesn't touch a kubernetes cluster. Per Q2 the banner is for *cluster-touching* commands. Mark `init` as not-cluster-touching → no banner. Matches the principle that init writes the env file; nothing kubernetes happens until `up`.

- [ ] 5.2 In `cmd_stack_install` specifically, set `export UIS_BANNER_PRINTED=1` after the parent banner prints, before fanning out to child `./uis deploy <service>` calls. Per C-4 this is the only place the env var is needed.

### Validation (Phase 5)

- [ ] 5.3 Inside the container:
  - `uis deploy nginx` → banner `ℹ  Platform: rancher-desktop (reachable)` to stderr before the deploy starts. Pipe test: `uis deploy nginx 2>/dev/null` suppresses the banner; `uis deploy nginx >/dev/null` keeps it visible.
  - `uis help` → no banner (informational command).
  - `uis tools install azure-aks` (already installed) → no banner (tools commands don't touch clusters).
  - `uis platform up azure-aks` (no env file → refuses early) → banner not relevant because the command refuses before doing cluster work; need to think about ordering — see Implementation Notes.
- [ ] 5.4 Manual `unreachable` test: with kubectl context set to something unreachable, run `uis deploy nginx` — expects the unreachable banner block + abort, exit 1. Concrete repro: `kubectl config use-context azure-aks` (without an active cluster), then `uis deploy nginx`.

---

## Phase 6: Converge `02-post-apply.sh` and `03-destroy.sh` onto `pf_lockstep_flip`

The lockstep-flip writer in `platform-switching.sh` now owns the `cluster-config.sh` + kubectl-context write. Replace the existing `sed -i` blocks in `02-post-apply.sh` (auto-flip on up) and `03-destroy.sh` (auto-reset on destroy) with calls to the shared writer.

### Tasks

- [ ] 6.1 In `platforms/azure-aks/scripts/02-post-apply.sh`, replace the existing `sed -i ... cluster-config.sh` block (currently lines 102–115) with:
  ```bash
  source /mnt/urbalurbadisk/provision-host/uis/lib/platform-switching.sh
  pf_lockstep_flip "$AZURE_AKS_CLUSTER_NAME"   # flips kubectl + cluster-config.sh together
  ```

- [ ] 6.2 In `platforms/azure-aks/scripts/03-destroy.sh`, replace the existing reset block (currently lines 184–199) with:
  ```bash
  source /mnt/urbalurbadisk/provision-host/uis/lib/platform-switching.sh
  pf_lockstep_flip "rancher-desktop"   # symmetric reset on tear-down
  ```

- [ ] 6.3 Move the kubeconfig-context-delete block in `03-destroy.sh` (currently lines 171–177) into `pf_lockstep_flip` itself? **No** — `pf_lockstep_flip` is for switching to an existing context. Context deletion is its own operation. Leave the `kubectl config delete-context` block in `03-destroy.sh` as-is, just before the reset to rancher-desktop.

### Validation (Phase 6)

- [ ] 6.4 `bash -n` on both edited scripts.
- [ ] 6.5 Live: end-to-end cycle — `uis platform up azure-aks` should auto-flip via the shared writer; `uis platform down azure-aks` should auto-reset via the shared writer. Compare `cluster-config.sh` state before/after each to confirm the writes happen.
- [ ] 6.6 Defensive: after `up`, manually edit `cluster-config.sh` to point at `rancher-desktop` (simulating external tampering). Then run `uis deploy nginx` — banner should detect the divergence... wait, no: the investigation explicitly drops the divergence banner case per N-C5. So instead: confirm that *despite* the manual edit, kubectl context still says `azure-aks` (because the user only touched the cached projection, not the truth), and `uis deploy nginx` correctly targets azure-aks. The lockstep guarantee holds for reads via kubectl context.

---

## Phase 7: Tester verification round

Single talk round covering everything Layer 4 + Layer 1 ships. Goal is end-to-end against CI-built `:latest` post-merge, mirroring the talk47 protocol.

### Tasks

- [ ] 7.1 File the verification round at `testing/uis1/talk/talk.md`, archiving the previous current round per the talk-naming protocol (`mv talk.md talk<N>.md`, fresh `talk.md`).

- [ ] 7.2 Round outline (final talk.md):

  - **R0** — pull `:latest`, confirm `platform-switching.sh` + `platform/rancher-desktop/scripts/status.sh` + updated `azure-aks/scripts/status.sh` are present in the container; `uis help` shows `platform list` + `platform use` in the Platform section.
  - **R1 (Tier 1, ~5 min, €0)** — `list` and `use` against the post-talk47 baseline (rancher-desktop running, azure-aks env file present, no cluster):
    - `uis platform list` → shows both rows correctly with the right states
    - `uis platform list --offline` → same rows but no probe (verify with `time`)
    - `uis platform use rancher-desktop` (already active) → no-op + re-probe
    - `uis platform use azure-aks` (configured-not-running) → refuses with pointer at `up`
    - `uis platform use google-gke` (not-initialized) → refuses with pointer at `init`
    - `uis platform use` (no arg) → interactive picker, only rancher-desktop selectable
    - `uis deploy nginx` → banner shows `Platform: rancher-desktop (reachable)` to stderr, deploy proceeds to rancher-desktop
  - **R2 (Tier 2, ~25 min, ~€0.05–0.10)** — full novice cycle with `use` flipping between platforms:
    - `uis platform up azure-aks` (still uses `pf_lockstep_flip` internally via Phase 6) — cluster up
    - `uis platform list` → both rows now `running`, azure-aks marked `(active)`
    - `uis platform list --deep` → enhanced status with k8s version + node pool
    - `uis deploy nginx` → banner shows `Platform: azure-aks (reachable)`, nginx deploys to AKS
    - `uis platform use rancher-desktop` → success: `✓ Switched: azure-aks → rancher-desktop`
    - `uis deploy nginx` again → banner now shows `Platform: rancher-desktop`, idempotent skip
    - `uis platform use azure-aks` → success: switched back
    - `uis platform down azure-aks` → tear-down + symmetric auto-reset to rancher-desktop via shared writer
    - `uis platform list` after down → azure-aks back to `configured-not-running`, rancher-desktop active
  - **R3 (banner safety, ~2 min, no spend)** — simulate the talk41 stale-context scenario by manually breaking kubectl: `KUBECONFIG=/mnt/urbalurbadisk/kubeconfig/kubeconf-all kubectl config use-context <some-nonexistent>`, then `uis deploy nginx`. Banner should fire the unreachable block + abort, exit 1, no deploy attempted.

- [ ] 7.3 Tester rounds close green; any findings filed as F-numbered items follow up.

### Validation (Phase 7)

- [ ] 7.4 Tester confirms R0 + R1 (Tier 1) green at minimum; R2 + R3 close the full bar.

---

## Acceptance Criteria

- [ ] `provision-host/uis/lib/platform-switching.sh` exists with the 6 functions named in Phase 1, all sourceable + invocable standalone.
- [ ] `platforms/azure-aks/scripts/status.sh` accepts `--summary` / `--offline` / `--deep` flags and emits C-1-conformant output. Backward-compatible: no-flag invocation unchanged.
- [ ] `platforms/rancher-desktop/scripts/status.sh` exists, runs in <100ms, implements the 3-state rancher-desktop machine.
- [ ] `./uis platform list` runs in <500ms with 2 platforms; `--offline` <100ms; `--deep` works against a live AKS cluster.
- [ ] `./uis platform use <name>` correctly refuses for `not-initialized` / `configured-not-running` / `unreachable`; succeeds with lockstep flip for `running`; `--offline` overrides only the unreachable case.
- [ ] Every cluster-touching `./uis` command emits the Layer 1 banner to stderr before its first action.
- [ ] `02-post-apply.sh` and `03-destroy.sh` both route their `cluster-config.sh` writes through `pf_lockstep_flip` — no remaining `sed -i ... cluster-config.sh` blocks in either.
- [ ] Tester closes R0 + R1 + R2 + R3 in the talk round.
- [ ] CI green on push: Test UIS Scripts, Build UIS Container, Generate UIS Documentation, Deploy Documentation.
- [ ] Local Docusaurus build clean for this PLAN file.

---

## Implementation Notes

- **Banner before refusal banners.** When `cmd_platform_up azure-aks` is invoked with no env file, `up.sh` refuses early with `✗ No config file found...`. The Layer 1 banner needs to fire *before* this refusal (so the user sees what platform was attempted). The Q2-listed touch points (`cmd_platform_up`, etc.) get the banner at their top, before delegating to the per-platform script. The banner machinery thus needs to compute "active platform" even when the lifecycle script subsequently refuses — that's fine, the banner is about kubectl context, not about whether the platform is set up.

- **Order of dispatch when active context isn't a UIS platform.** If the user's kubectl context is a personal `prod-cluster` and they run `./uis deploy nginx`, the banner emits the C-9 case-3 warning (`not a UIS platform — proceeding with kubectl context anyway`) and the deploy goes ahead against `prod-cluster`. This matches Q5's spirit: UIS doesn't take ownership of contexts it doesn't manage; it just surfaces the situation.

- **`pf_banner` cost on every command.** Default reachability probe is ~50–200ms. For commands that don't actually need a cluster (e.g. `uis status` when no services deployed), this is overhead the user can't opt out of. Acceptable per the investigation's stance — "the cost of one probe per command is the cost of not silently deploying to the wrong cluster".

- **No probe cache.** The investigation explicitly drops the `/tmp` probe cache idea. Each invocation re-probes; staleness can't accumulate. If session-level performance becomes a real problem, revisit with measurements.

- **`status.sh --summary` reads kubeconfig directly, doesn't shell out to `kubectl config get-contexts`.** Parse `kubeconf-all` once with `awk` or a single `kubectl config view --output jsonpath` to get the context list — avoids multiple kubectl invocations per `list` row.

- **Backward compat for `02-post-apply.sh` / `03-destroy.sh`.** The existing `sed -i` writes have been in production through PR #149 and the talk44/45/46/47 cycles. Replacement via `pf_lockstep_flip` must preserve the same outcome (same file contents post-write). Test by diffing `cluster-config.sh` before/after a write in each call site under both old and new code.

- **`cluster-config.sh` CLUSTER_TYPE and TARGET_HOST**. Per the investigation's Edge case #10, both fields always hold the same string. `pf_lockstep_flip` writes both with the same value (matching the existing two `sed -i -e ...` invocations).

- **No need for `cluster-config.sh` locking.** Per Edge case #9, concurrent `use` from two terminals is documented as "last write wins"; the lockstep writer issues both writes (kubectl + sed) back-to-back, sub-millisecond window. Engineering a lock would be overkill for the use case.

---

## Files to Modify

**New:**
- `provision-host/uis/lib/platform-switching.sh`
- `platforms/rancher-desktop/scripts/status.sh`

**Modified:**
- `platforms/azure-aks/scripts/status.sh` — add `--summary` / `--offline` / `--deep` flags (backward-compat preserved)
- `platforms/azure-aks/scripts/02-post-apply.sh` — replace `sed -i` block with `pf_lockstep_flip` call
- `platforms/azure-aks/scripts/03-destroy.sh` — replace reset block with `pf_lockstep_flip "rancher-desktop"` call
- `provision-host/uis/manage/uis-cli.sh` — add `cmd_platform_list` + `cmd_platform_use` + `list)` / `use)` dispatcher cases + banner injection at ~13 command functions + help-banner row additions

**No new platform directories** beyond `platforms/rancher-desktop/` (which is the always-present row from Q3).
