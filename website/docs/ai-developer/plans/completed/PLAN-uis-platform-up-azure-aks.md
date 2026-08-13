# Plan: `./uis platform up azure-aks` chain wrapper

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: ✅ Completed (2026-05-11)

**Shipped in**: PR #156 (bundled with PLAN #4).
**Verified end-to-end**: talk44 (`UIS_IMAGE=:local`), talk45 + talk46 (post-merge against CI-built `:latest`) — cold cycle ran 00→01→02 successfully, F1–F5 surfaced and fixed in the same PR before merge, F11/F12 in the follow-on status command fixed in PR #158.

**Goal**: Add `./uis platform up azure-aks` — a thin chain wrapper that runs the three existing lifecycle scripts (`00-bootstrap-state.sh` → `01-apply.sh` → `02-post-apply.sh`) in order with visible inter-step banners. This is **PLAN #3 of 4** spawned by [INVESTIGATE-platform-aks-novice-onboarding.md](./INVESTIGATE-platform-aks-novice-onboarding.md). Trivial once PLAN #2's `init` ships — the heavy lifting (sub discovery, role check, region pick, provider registration, env-file write) is done; `up` just executes the IaC.

**Last Updated**: 2026-05-11 — **bundled with PLAN #4 (`./uis platform down azure-aks`) in PR #156** so the AKS wrapper sequence ships as one logical change. Tester round at `testing/uis1/talk/talk.md` covers both wrappers.

**Source**: [INVESTIGATE-platform-aks-novice-onboarding.md](./INVESTIGATE-platform-aks-novice-onboarding.md). Implements Q8 (three-layer split), Q9 (naive chain), Q10 (always have output), Q11 (refuse-with-pointer if env missing).

---

## Problem Summary

After PLAN #2's `init` ships, the novice flow is at step 8 of 8:

```bash
uis tools install azure-aks       # PR #154 ✅
uis platform init azure-aks       # PR #155 ✅
# Now: run three scripts manually:
./platforms/azure-aks/scripts/00-bootstrap-state.sh
./platforms/azure-aks/scripts/01-apply.sh
./platforms/azure-aks/scripts/02-post-apply.sh
```

The novice has to know which scripts to run, in which order, that they're idempotent, and where they live (`./platforms/azure-aks/scripts/...` is an unfamiliar path inside an unfamiliar shape). This PLAN replaces the three manual invocations with:

```bash
uis platform up azure-aks
```

Per Q9: naive chain — all three lifecycle scripts run on every invocation. All three are idempotent today, so warm runs are fast no-ops with visible logging per Q10 (no `--force` / `--skip-*` flags needed).

---

## Out of Scope

- **The `down` wrapper** — PLAN #4.
- **The `clean` command** for wiping `.uis.secrets/cloud-accounts/azure-default.env` post-`down` — deferred per Q12.
- **`--non-interactive` flag** — there are no interactive prompts in `up` (everything reads from the env file written by `init`), so this is moot. The destroy-confirmation pattern from `03-destroy.sh` doesn't apply.
- **Changing the underlying lifecycle scripts.** `up` calls them as-is. Any improvements to `00-bootstrap-state.sh` / `01-apply.sh` / `02-post-apply.sh` are separate PRs.
- **A progress UX over `tofu apply`'s output** — Q10 says always have output, no spinners. `tofu apply` already streams per-resource output; `up` only adds inter-step banners.
- **Adding `up` for other platforms** (`gke`/`eks`/`azure-microk8s`/`microk8s-rpi`). The dispatcher infrastructure (`cmd_platform_up` discovering `platforms/<provider>/scripts/up.sh`) makes future additions cheap, but only AKS is in scope now.

---

## Phase 1: Create `platforms/azure-aks/scripts/up.sh`

The chain orchestrator. Mirrors `init.sh`'s shape (banner + preflight + delegate + summary) but the delegation is to the three existing lifecycle scripts in sequence.

### Tasks

- [x] 1.1 Create `platforms/azure-aks/scripts/up.sh`:
  ```bash
  #!/bin/bash
  # up.sh — Provision an AKS cluster end-to-end (PLAN #3 of INVESTIGATE-platform-aks-novice-onboarding.md).
  #
  # Entry point: uis platform up azure-aks
  # Chains the three existing lifecycle scripts in order, with inter-step
  # banners per the always-have-output principle. All three are idempotent,
  # so warm runs are fast no-ops with visible logging.

  set -euo pipefail

  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  REPO_ROOT="${UIS_REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
  ENV_FILE="$REPO_ROOT/.uis.secrets/cloud-accounts/azure-default.env"

  # Q11 — refuse with a pointer if init has not been run.
  if [[ ! -f "$ENV_FILE" ]]; then
      echo "✗ No config file found at $ENV_FILE" >&2
      echo "  Run 'uis platform init azure-aks' first to set one up." >&2
      exit 1
  fi

  # Make AZURE_* available to the lifecycle scripts.
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a

  echo "═══════════════════════════════════════════════════════════"
  echo " AKS cluster provisioning"
  echo " (uis platform up azure-aks)"
  echo " Subscription: ${AZURE_SUBSCRIPTION_ID:-unset}"
  echo " Region:       ${AZURE_REGION:-unset}"
  echo "═══════════════════════════════════════════════════════════"
  echo
  echo "⚠  This will create or update Azure resources and may incur cost (~€1/day)."
  echo "   Run 'uis platform down azure-aks' to tear down when finished."
  echo

  echo "▶ 1/3 Bootstrap remote tofu state (Azure storage account + container)..."
  "$SCRIPT_DIR/00-bootstrap-state.sh"
  echo

  echo "▶ 2/3 Apply cluster (tofu apply against platforms/azure-aks/tofu/)..."
  "$SCRIPT_DIR/01-apply.sh"
  echo

  echo "▶ 3/3 Post-apply (kubeconfig merge + storage-class aliases + Traefik)..."
  "$SCRIPT_DIR/02-post-apply.sh"

  echo
  echo "═══════════════════════════════════════════════════════════"
  echo " ✓ AKS cluster is up"
  echo "═══════════════════════════════════════════════════════════"
  echo "  Try: kubectl get nodes"
  echo "       uis deploy nginx"
  echo
  echo "  Tear down: uis platform down azure-aks  (PLAN #4 — not yet shipped)"
  echo "             ./platforms/azure-aks/scripts/03-destroy.sh  (works today)"
  ```

- [x] 1.2 `chmod +x platforms/azure-aks/scripts/up.sh`

### Validation (Phase 1)

- [x] 1.3 `bash -n platforms/azure-aks/scripts/up.sh` parses cleanly.
- [x] 1.4 Script runs the three lifecycle scripts in order. Verified at Phase 3 by the tester. — talk46 R3 `▶ 1/3 / ▶ 2/3 / ▶ 3/3` banners fired in order, cluster came up successfully.

---

## Phase 2: Wire `up` into the dispatcher

`cmd_platform` in `provision-host/uis/manage/uis-cli.sh` currently handles `up`/`down` with a "not yet implemented" placeholder (PLAN #2 c780a74). This phase removes the placeholder for `up` and routes it through a new `cmd_platform_up` that mirrors `cmd_platform_init`.

### Tasks

- [x] 2.1 In `cmd_platform`, replace the `up|down)` joint placeholder with two distinct cases:
  ```bash
  up)
      cmd_platform_up "$@"
      ;;
  down)
      log_error "'uis platform down' is not yet implemented"
      { ... } >&2
      exit "$EXIT_GENERAL_ERROR"
      ;;
  ```
  (The `down` placeholder gets its own block now that `up` and `down` ship separately. Keep the same lifecycle-script fallback hint in `down`'s placeholder.)

- [x] 2.2 Add `cmd_platform_up` after `cmd_platform_init`. It's structurally identical to `cmd_platform_init` but dispatches to `up.sh`:
  ```bash
  cmd_platform_up() {
      local provider="${1:-}"
      local repo_root
      repo_root="$(cd "$SCRIPT_DIR/../../.." && pwd)"

      if [[ -z "$provider" ]]; then
          log_error "Usage: uis platform up <provider>"
          { _list_available_platforms_with_script up.sh "$repo_root"; } >&2
          exit "$EXIT_GENERAL_ERROR"
      fi

      local script="$repo_root/platforms/$provider/scripts/up.sh"
      if [[ ! -f "$script" ]]; then
          log_error "Platform '$provider' has no up.sh (looked at $script)"
          { _list_available_platforms_with_script up.sh "$repo_root"; } >&2
          exit "$EXIT_GENERAL_ERROR"
      fi

      export UIS_REPO_ROOT="$repo_root"
      exec "$script"
  }
  ```

  Note: lifting the "list available platforms with script X" logic into a helper `_list_available_platforms_with_script` avoids duplicating the loop across `cmd_platform_init` (looks for `init.sh`) and `cmd_platform_up` (looks for `up.sh`). Tiny refactor — same shape, new arg for the script name:
  ```bash
  _list_available_platforms_with_script() {
      local target_script="$1"
      local repo_root="$2"
      echo "Available platforms:"
      local p script_path
      for script_path in "$repo_root"/platforms/*/scripts/"$target_script"; do
          [[ -f "$script_path" ]] || continue
          p=$(basename "$(dirname "$(dirname "$script_path")")")
          echo "  - $p"
      done
  }
  ```
  Refactor `cmd_platform_init`'s two suggestion blocks to use this helper too (so `init` lists platforms-with-init.sh and `up` lists platforms-with-up.sh, both via the same code).

- [x] 2.3 Update `cmd_help`'s `Platform:` section to remove the "PLAN #3 — not yet implemented" tag from the `up` line. The `down` line keeps its "PLAN #4 — not yet implemented" tag.

### Validation (Phase 2)

- [x] 2.4 `bash -n provision-host/uis/manage/uis-cli.sh` parses cleanly.
- [x] 2.5 Smoke-test inside the rebuilt local container:
  - `uis platform up` (no provider) — usage + available platforms (azure-aks only), exit non-zero.
  - `uis platform up nonexistent` — "Platform 'nonexistent' has no up.sh..." + available list, exit non-zero.
  - `uis platform up azure-aks` with no env file — refuses with the `uis platform init azure-aks` pointer, exit non-zero. **(can be self-tested by deleting `azure-default.env` before invoking; no Azure call attempted.)**
  - `uis platform down azure-aks` — still prints "not yet implemented" placeholder.
  - `uis help` shows `platform up <provider>    Provision the cluster` without the "not yet implemented" tag; `down` still tagged.

---

## Phase 3: Tester verification (talk.md round)

**This is the load-bearing test of the entire AKS path.** Up until now, every PR has been verifiable without provisioning a real cluster. PLAN #3 changes that: `up` creates an actual AKS cluster, which costs real money (~€1/day for a 1-node Standard_B2s_v2 cluster). The tester must spend ~€1–2 to fully verify cold-run + warm-run + (Phase 4 will tear it down at the end).

### Tasks

- [x] 3.1 File the verification round at `testing/uis1/talk/talk.md`, archiving the current talk.md (the `init` round) as `talk43.md`.
- [x] 3.2 Tester rounds (talk44 pre-merge against `:local`, talk45/talk46 post-merge against `:latest`):
  - **R0** — local image preflight; confirm `platforms/azure-aks/scripts/up.sh` is in the running container.
  - **R1** — dispatcher error paths: `uis platform up` (no provider), `uis platform up nonexistent`, `uis platform up azure-aks` with the env file deleted (Q11 refusal). All non-zero exits with the expected messages.
  - **R2** — **cold run** against a real Azure subscription. Run `uis platform up azure-aks`. Expect ~10–15 minutes:
    - Inter-step banners `▶ 1/3 Bootstrap...`, `▶ 2/3 Apply...`, `▶ 3/3 Post-apply...`
    - `00-bootstrap-state.sh`: ~10s if state RG exists from prior work, ~30-60s otherwise.
    - `01-apply.sh`: `tofu apply` streams per-resource output. RG creation → cluster creation → wait for cluster Ready → ~8–12 minutes.
    - `02-post-apply.sh`: kubeconfig merge, storage-class aliases applied, Traefik installed.
    - Final banner with `Try: kubectl get nodes` hint.
    Verify after: `kubectl get nodes` lists the one Standard_B2s_v2 node, `kubectl get pods -n traefik` shows Traefik running.
  - **R3** — **warm run** immediately after R2. Same command. Expect:
    - All three scripts run again (Q9 naive chain).
    - `00-bootstrap-state.sh`: "state RG already exists, skipping creation".
    - `01-apply.sh`: `tofu apply — no changes` in ~30s.
    - `02-post-apply.sh`: kubeconfig already merged, storage classes already aliased, Traefik already installed.
    - Final banner. Total elapsed should be ~1–2 minutes.
  - **R4** — **deploy verification**: `uis deploy nginx` against the live AKS cluster. Confirm the cluster-config flip from R2 routed the deploy to AKS (per [INVESTIGATE-active-cluster-visibility-ux.md](./INVESTIGATE-active-cluster-visibility-ux.md), this is currently a silent-failure mode; layered visibility lands later). `kubectl get pods -n nginx` shows the pod running.
  - **R5** — **cost reassurance + tear-down hint visible**: confirm the wizard printed `⚠ This will create or update Azure resources and may incur cost (~€1/day)` before any actual API call. After R2-R4, run `./platforms/azure-aks/scripts/03-destroy.sh` manually (PLAN #4's `down` wrapper isn't shipped yet). Cluster goes away, cost stops.

### Validation (Phase 3)

- [x] 3.3 Tester closes R0–R3 green (R2 is the load-bearing one). R4 + R5 nice-to-have. — All closed across talk44/45/46; talk46 R3 ran R2 (cold cycle) + R4 (`uis deploy nginx` on AKS) + R5 (real tear-down).

---

## Verification gate before merge

- [x] All Phase 1/2 `bash -n` checks pass.
- [x] Tester closes Phase 3 R2 (cold run end-to-end against real Azure) at minimum. — talk46 R3.
- [x] Local Docusaurus build clean for this PLAN file.
- [x] PR description includes the cold-run transcript from R2 (proves the chain works end-to-end).
- [x] PR description includes the tear-down output from R5 (proves the verification environment is clean — no cluster left running and incurring cost).

---

## What this PLAN deliberately does NOT do

- **Add a `--force` or `--skip-*` flag.** Q9: naive chain is the answer. The few seconds of warm-run "already exists" output is the cost of not having a flag the novice has to learn.
- **Wrap `tofu apply`'s output in a spinner or progress bar.** Q10. Stream the per-resource output through unchanged.
- **Try to detect "is this a cold or warm run" upfront** to skip steps. Each script self-determines that internally; the wrapper just runs all three.
- **Cache kubeconfig flips across runs.** `02-post-apply.sh` re-flips on every invocation. If the user manually changed kubectl context between `up` runs, the post-apply will restore it — acceptable behavior since `up` is the "I want this AKS cluster to be the active target" command.
- **Add cost-confirmation Y/N prompts.** The cold-run cost is ~€1/day, visible in the banner before the API calls. A prompt every time is friction; users who don't want the cost don't run `up`.

---

## Related

- [INVESTIGATE-platform-aks-novice-onboarding.md](./INVESTIGATE-platform-aks-novice-onboarding.md) — parent investigation. Q8, Q9, Q10, Q11 directly inform this PLAN.
- [PLAN-uis-tools-install-azure-aks.md](./PLAN-uis-tools-install-azure-aks.md) — PLAN #1 (PR #154, merged).
- [PLAN-uis-platform-init-azure-aks.md](./PLAN-uis-platform-init-azure-aks.md) — PLAN #2 (PR #155, merged). `init` writes the env file that `up` reads.
- [INVESTIGATE-active-cluster-visibility-ux.md](./INVESTIGATE-active-cluster-visibility-ux.md) — once `up` lands and the operator has 2+ clusters (rancher-desktop + azure-aks), Layer 1's per-command banner + Layer 4's `uis platform list/use` become the next safety problem. R4 of Phase 3 explicitly notes this.
- `platforms/azure-aks/scripts/{00-bootstrap-state,01-apply,02-post-apply}.sh` — the three lifecycle scripts `up.sh` chains. Unchanged in this PR.
- **Next**: PLAN #4 — `./uis platform down azure-aks` pass-through to `03-destroy.sh`. Trivial; under a day.
