# Plan: `./uis platform down azure-aks` pass-through wrapper

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: ✅ Completed (2026-05-11)

**Shipped in**: PR #156 (the `up` + `down` bundle).
**Verified end-to-end**: talk45 + talk46 — F9 safety branch later hardened in PR #157, all tester rounds green on CI-built `:latest`.

**Goal**: Add `./uis platform down azure-aks` — a thin pass-through to the existing `03-destroy.sh` lifecycle script. **This is PLAN #4 of 4** spawned by [INVESTIGATE-platform-aks-novice-onboarding.md](./INVESTIGATE-platform-aks-novice-onboarding.md) — the last and most trivial. Closes the AKS novice-onboarding sequence (`tools install` + `platform init` + `platform up` + `platform down`).

**Last Updated**: 2026-05-11

**Source**: [INVESTIGATE-platform-aks-novice-onboarding.md](./INVESTIGATE-platform-aks-novice-onboarding.md). Implements Q8 (three-layer split), Q12 (leave env file in place after destroy), Q10 (always have output). `03-destroy.sh` already has TTY-guarded typed-name confirmation + `UIS_DESTROY_CONFIRM` escape hatch (PR #149), so the wrapper inherits all interactive safety for free.

---

## Problem Summary

After PLAN #3 ships, the novice flow is one command short of complete:

```bash
uis tools install azure-aks       # PR #154 ✅
uis platform init azure-aks       # PR #155 ✅
uis platform up   azure-aks       # PR #156 ✅ (pending tester R2)
# Tear-down still requires the manual path:
./platforms/azure-aks/scripts/03-destroy.sh
```

This PLAN replaces the manual destroy invocation with:

```bash
uis platform down azure-aks
```

Behaviour per Q12: `down` destroys cloud resources only — leaves `.uis.secrets/cloud-accounts/azure-default.env` in place so the user can `up` again tomorrow without re-running `init`. The wrapper prints a final config-preservation pointer explaining how to fully reset if the user wants to.

---

## Out of Scope

- **The `clean` command** for wiping `.uis.secrets/cloud-accounts/azure-default.env` post-`down` — deferred per Q12 to a future "I want to fully reset and switch tenants" command. Not in this PR.
- **Changing `03-destroy.sh`.** The wrapper calls it as-is. Any improvements (kubeconfig cleanup, state-RG handling) are governed by [PLAN-platform-aks-destroy-kubeconfig-cleanup.md](./PLAN-platform-aks-destroy-kubeconfig-cleanup.md) — separate PR.
- **Adding `--force` / `--yes` flags to skip the typed-name confirmation.** `03-destroy.sh` already has `UIS_DESTROY_CONFIRM=<cluster-name>` env-var support for non-interactive flows (PR #149). The wrapper passes the env through; no additional flag plumbing.
- **`down` for other platforms** (`gke`/`eks`/`azure-microk8s`). The dispatcher infrastructure makes them cheap to add, but only AKS is in scope now.

---

## Phase 1: Create `platforms/azure-aks/scripts/down.sh`

Thin pass-through. Reads the env file (same Q11 refuse-with-pointer pattern as `up.sh`), prints a banner, runs `03-destroy.sh`, prints the config-preservation hint per Q12.

### Tasks

- [x] 1.1 Create `platforms/azure-aks/scripts/down.sh`:
  ```bash
  #!/bin/bash
  # down.sh — Tear down the AKS cluster (delegates to 03-destroy.sh).
  #
  # Spec: website/docs/ai-developer/plans/active/PLAN-uis-platform-down-azure-aks.md
  # Entry point: uis platform down azure-aks

  set -euo pipefail

  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  REPO_ROOT="${UIS_REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
  ENV_FILE="$REPO_ROOT/.uis.secrets/cloud-accounts/azure-default.env"

  # Refuse with a pointer if there's no config (no cluster to destroy).
  if [[ ! -f "$ENV_FILE" ]]; then
      echo "✗ No config file found at $ENV_FILE" >&2
      echo "  No AKS cluster appears to be configured. Nothing to tear down." >&2
      echo "  (If you have a cluster from a manual run, fall back to" >&2
      echo "  './platforms/azure-aks/scripts/03-destroy.sh' directly.)" >&2
      exit 1
  fi

  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a

  echo "═══════════════════════════════════════════════════════════"
  echo " AKS cluster tear-down"
  echo " (uis platform down azure-aks)"
  echo " Subscription: ${AZURE_SUBSCRIPTION_ID:-unset}"
  echo " Region:       ${AZURE_REGION:-unset}"
  echo "═══════════════════════════════════════════════════════════"
  echo
  echo "This will destroy the AKS cluster and stop ~€1/day cluster cost."
  echo "(The state RG used by tofu is preserved — that's deliberate.)"
  echo

  # Delegate to the existing lifecycle script. It owns the typed-name
  # confirmation prompt + UIS_DESTROY_CONFIRM escape hatch.
  "$SCRIPT_DIR/03-destroy.sh"

  # On success, surface the config-preservation pointer (Q12).
  echo
  echo "═══════════════════════════════════════════════════════════"
  echo " ✓ AKS cluster destroyed"
  echo "═══════════════════════════════════════════════════════════"
  echo "  Cluster cost stopped. The config file is preserved:"
  echo "    $ENV_FILE"
  echo
  echo "  To recreate the cluster with the same subscription + region:"
  echo "    uis platform up azure-aks"
  echo
  echo "  To fully reset (e.g. before switching tenants), delete the file:"
  echo "    rm $ENV_FILE"
  ```

- [x] 1.2 `chmod +x platforms/azure-aks/scripts/down.sh`.

### Validation (Phase 1)

- [x] 1.3 `bash -n platforms/azure-aks/scripts/down.sh` parses cleanly.

---

## Phase 2: Wire `down` into the dispatcher

`cmd_platform_down` parallel to `cmd_platform_up` (PR #156). Reuses the `_list_available_platforms_with_script` helper. Removes the `down)` placeholder from `cmd_platform`.

### Tasks

- [x] 2.1 In `cmd_platform` (`provision-host/uis/manage/uis-cli.sh`), replace the `down)` placeholder with a real dispatch:
  ```bash
  down)
      cmd_platform_down "$@"
      ;;
  ```

- [x] 2.2 Add `cmd_platform_down` after `cmd_platform_up` (same shape, looks for `down.sh`):
  ```bash
  cmd_platform_down() {
      local provider="${1:-}"
      local repo_root
      repo_root="$(cd "$SCRIPT_DIR/../../.." && pwd)"

      if [[ -z "$provider" ]]; then
          log_error "Usage: uis platform down <provider>"
          { _list_available_platforms_with_script down.sh "$repo_root"; } >&2
          exit "$EXIT_GENERAL_ERROR"
      fi

      local script="$repo_root/platforms/$provider/scripts/down.sh"
      if [[ ! -f "$script" ]]; then
          log_error "Platform '$provider' has no down.sh (looked at $script)"
          { _list_available_platforms_with_script down.sh "$repo_root"; } >&2
          exit "$EXIT_GENERAL_ERROR"
      fi

      export UIS_REPO_ROOT="$repo_root"
      exec "$script"
  }
  ```

- [x] 2.3 Update `cmd_help`'s `Platform:` section to remove the "PLAN #4 — not yet implemented" tag from the `down` line. The AKS sequence is now complete; no remaining tags.

- [x] 2.4 Update the empty-subcmd error message in `cmd_platform` — drop the "(not yet implemented)" qualifier on `down`:
  ```bash
  echo "Subcommands: init | up | down" >&2
  ```

### Validation (Phase 2)

- [x] 2.5 `bash -n provision-host/uis/manage/uis-cli.sh` parses cleanly.
- [x] 2.6 Smoke-test inside the rebuilt local container:
  - `uis platform down` (no provider) → usage error + `Available platforms: - azure-aks`, exit 1.
  - `uis platform down nonexistent` → "Platform 'nonexistent' has no down.sh ..." + list, exit 1.
  - `uis platform down azure-aks` with the env file deleted → refuses with the "nothing configured" message, exit 1.
  - `uis help | grep -A4 ^Platform:` → all three lines (`init` / `up` / `down`) clean, no "not yet implemented" tags.

---

## Phase 3: Tester verification — bundled with PLAN #3

**Update 2026-05-11**: this PLAN ships in the same PR as PLAN #3 (PR #156 — the up chain wrapper). The bundled PR retains PLAN #3's pre-merge verification flow (`UIS_IMAGE=uis-provision-host:local` against the contributor's build, draft PR pending tester signoff) because PLAN #3 is the high-risk piece (first PR that creates a real AKS cluster). PLAN #4's verification rides along: the R5 tear-down step in PLAN #3's talk.md round now uses `uis platform down azure-aks` instead of `./platforms/azure-aks/scripts/03-destroy.sh` directly, which verifies PLAN #4 for free as part of PLAN #3's cleanup.

The testing-flow shift to CI-built GHCR `:latest` (recorded in `feedback_testing_protocol.md`) starts with the next PR after this bundle merges — likely the `azure-aks.md` doc rewrite stashed on `docs/aks-self-contained`. That's also low-risk (doc-only, no behavior change) and a good first candidate for the new flow.

PLAN #4 is low-risk regardless:
- The underlying `03-destroy.sh` is already verified (PLAN #3's R5 uses it).
- The wrapper is a thin pass-through — Phase 2's self-tests cover the dispatcher; the bundled R5 covers the real-world end-to-end.
- Cost: ~€0. `down` *stops* cost; doesn't create new resources.

### Tasks

- [x] 3.1 Update the bundled PLAN #3 talk.md (`testing/uis1/talk/talk.md`) so R5's tear-down uses `uis platform down azure-aks` rather than the manual `./platforms/azure-aks/scripts/03-destroy.sh`. Also add a small R1 sub-case for `uis platform down` dispatcher error paths (no Azure cost).
- [x] 3.2 Tester verification (riding on PLAN #3's round):
  - **R1.down** — dispatcher errors: `uis platform down` (no provider), `uis platform down nonexistent`, `uis platform down azure-aks` with the env file deleted. All exit non-zero with expected messages. No Azure call.
  - **R5** (PLAN #3's existing round, retargeted at the wrapper) — real tear-down via `uis platform down azure-aks`. Pre-condition: an AKS cluster exists from R2/R4 of PLAN #3. Verify:
    - Banner prints with sub + region from env.
    - `03-destroy.sh`'s typed-name confirmation prompts; type the cluster name to proceed.
    - `tofu destroy` streams output; cluster goes away in ~5-10 min.
    - Final `✓ AKS cluster destroyed` banner + config-preservation pointer pointing at the `azure-default.env` path.
  - **R6 (optional)** — `az aks list -o table` returns empty; `az group list --query "[?contains(name,'aks')].name" -o tsv` empty (state RG with `state` in the name is preserved on purpose).

### Validation (Phase 3)

- [x] 3.3 Tester closes R5 (the load-bearing path, replaces what was the manual cleanup step). — talk46 R3 ran real tear-down via `uis platform down azure-aks`, exit 0, cluster destroyed, state RG preserved.

---

## Verification gate before merge

- [x] All Phase 1/2 `bash -n` checks pass.
- [x] Phase 2 dispatcher self-tested inside the contributor's locally-rebuilt container (no-provider, nonexistent, env-missing, help banner).
- [x] Local Docusaurus build clean for this PLAN file.
- [x] PR description notes the testing-flow shift (verification on CI `:latest`, post-merge) and the rationale.
- [x] CI green on push (Test UIS Scripts, Generate UIS Documentation, Deploy Documentation, Build UIS Container).
- [x] **Post-merge**: tester closes R0–R3 on the CI-built `:latest` image. — talk45 closed Tier 1 + Tier 2 on `:latest`. F1–F5 + F9 surfaced as fix-up PRs #156/#157.

---

## What this PLAN deliberately does NOT do

- **Add a `--force` / `--yes` flag.** `03-destroy.sh` already supports `UIS_DESTROY_CONFIRM=<cluster-name>` for non-interactive flows.
- **Delete the env file after destroy.** Q12: preserve. The user reuses the same sub + region across up/down cycles. Manual delete is documented in the wrapper's output.
- **Touch `cluster-config.sh`.** `02-post-apply.sh` flipped it on `up`; `03-destroy.sh` resets it. Wrapper just exec's the destroy script.
- **Tear down the tofu state RG.** Deliberate: the state RG holds the remote state backend; deleting it would force a re-bootstrap on the next `up` even though the resources are the same. `03-destroy.sh` already preserves it.

---

## Related

- [INVESTIGATE-platform-aks-novice-onboarding.md](./INVESTIGATE-platform-aks-novice-onboarding.md) — parent investigation. Q8, Q10, Q12 directly inform this PLAN. **Closes the four-PLAN sequence once this lands.**
- [PLAN-uis-tools-install-azure-aks.md](./PLAN-uis-tools-install-azure-aks.md) — PLAN #1 (PR #154, merged).
- [PLAN-uis-platform-init-azure-aks.md](./PLAN-uis-platform-init-azure-aks.md) — PLAN #2 (PR #155, merged).
- [PLAN-uis-platform-up-azure-aks.md](./PLAN-uis-platform-up-azure-aks.md) — PLAN #3 (PR #156, draft pending tester R2). `down` depends on a successful `up` for end-to-end verification.
- [PLAN-platform-aks-destroy-kubeconfig-cleanup.md](./PLAN-platform-aks-destroy-kubeconfig-cleanup.md) — improvements to `03-destroy.sh` itself (kubeconfig cleanup post-destroy). Separate PR; doesn't block this one.
- **After this lands**: the `azure-aks.md` doc rewrite stashed on `docs/aks-self-contained` becomes shippable. The 596-line WIP collapses to a 5-command novice flow with "under the hood" sections explaining what each wrapper does. See Q15 of the parent investigation.
