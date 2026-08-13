# Plan: `./uis platform init azure-aks` wizard

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: ✅ Completed (2026-05-10, hardened through 2026-05-11)

**Shipped in**: PR #155. Hardening fixes in PR #156 (F1 — env-file 4th var, write_env_atomically derives state-storage-account name) and PR #158 (F10 — `az` logged-in preflight in status; not strictly an `init` bug, surfaced in the same login path).
**Verified end-to-end**: talk43 (`UIS_IMAGE=:local` cold run), talk44 (post-merge against `:latest`, F1 surfaced + fixed in #156), talk46 R3 (final cold run on the patched wizard, env file written correctly, end-to-end through up + deploy + down).

**Goal**: Add an interactive `./uis platform init azure-aks` wizard that compresses today's most novice-hostile steps (sub discovery + role check + region pick + provider registration + env-file write) into one command. This is **PLAN #2 of 4** spawned by [INVESTIGATE-platform-aks-novice-onboarding.md](./INVESTIGATE-platform-aks-novice-onboarding.md) — the big one. PLANs #3 (`up`) and #4 (`down`) follow once this lands.

**Last Updated**: 2026-05-11

**Source**: [INVESTIGATE-platform-aks-novice-onboarding.md](./INVESTIGATE-platform-aks-novice-onboarding.md) — all 15 design questions decided 2026-05-10. This PLAN implements Q1 (name `azure-aks`), Q4 (overwrite prompt y/N), Q5 (interactive only), Q6 (block on provider registration with per-poll output), Q7 (fail-fast role check inside `init`), Q8 (three-layer split), Q10 (always have output), Q13 (top-level `./uis platform` subcommand). Mines the legacy `hosts/azure-aks/` + `hosts/azure-microk8s/` per the investigation's "Mining the legacy scripts" section.

---

## Problem Summary

Today's novice flow stalls at steps 3–7 (the discovery + registration + env-file half):

```bash
# After installing tools (PLAN #1 shipped this — `./uis tools install azure-aks`):
az login                                 # step 3
az account show                          # step 4 — scrape JSON for IDs
az provider register --namespace ...     # step 5 — four times, no idempotency UX
# (step 6 — pick a region, no help)
cp provision-host/uis/templates/uis.secrets/cloud-accounts/azure.env.template \
   .uis.secrets/cloud-accounts/azure-default.env    # step 7 — error-prone path
vi .uis.secrets/cloud-accounts/azure-default.env    # fill in IDs from step 4
```

This PLAN replaces all of that with:

```bash
./uis platform init azure-aks
```

The wizard handles login, sub discovery (interactive picker), role check (fail-fast per Q7), region pick (with `westeurope` default), provider registration (blocking with per-poll output per Q6+Q10), and atomic env-file write. The novice never sees a `cp` or a `vi`; they answer 2–3 numbered prompts and the rest is automatic.

---

## Out of Scope

- **The `up`/`down` lifecycle wrappers** — PLANs #3 and #4.
- **AAD-integrated AKS / `kubelogin`** — today's tofu module uses local-account auth; switching to AAD is a separate architectural decision (see parent investigation's "Out of Scope").
- **`--non-interactive` mode** with `--subscription` / `--region` / `--yes` flags or env-var pre-fills — deferred per Q5. Add when a real CI/scripted consumer surfaces.
- **`./uis platform clean azure-aks`** for wiping the env file post-`down` — separate command, deferred per Q12.
- **GKE / EKS / azure-microk8s / microk8s-rpi wizards** — the shared library shape established here is intended to extend cleanly (`aws-discovery.sh`, `gcp-discovery.sh`), but only AKS is in scope now.
- **Replacing `cluster-config.sh`** as a source of truth — the wizard writes `.uis.secrets/cloud-accounts/azure-default.env`; `cluster-config.sh` is downstream of `02-post-apply.sh` and outside this PLAN.

---

## Phase 0: Rename `platforms/aks/` to `platforms/azure-aks/`

The per-target naming convention (settled in the parent investigation: meta-tool `azure-aks`, CLI verb `azure-aks`, directory under `platforms/`) requires renaming the existing directory. Today's `platforms/aks/` was created before the convention existed.

### Tasks

- [x] 0.1 `git mv platforms/aks platforms/azure-aks`.
- [x] 0.2 Grep the repo for `platforms/aks/` references and update each. Expected hits (audit before changing):
  - `provision-host/uis/manage/uis-cli.sh` — any path strings.
  - `ansible/playbooks/*.yml` — bind-mount or path references inside playbooks.
  - `website/docs/platforms/azure-aks.md` — published doc (currently stashed on `docs/aks-self-contained`; rename impact already accounted for in the WIP rewrite).
  - Internal cross-references inside `platforms/azure-aks/scripts/*.sh` (e.g. `00-bootstrap-state.sh` may reference `../tofu/`).
  - Internal references inside `platforms/azure-aks/tofu/main.tf` / `backend.tf` (relative paths).
- [x] 0.3 Run all platform scripts in dry-run mode (`bash -n`) to verify no parse-time path failures.
- [x] 0.4 Confirm `./uis deploy nginx` still works against a rancher-desktop cluster (no AKS path triggered, but verifies generic UIS still functions). — verified across tester rounds on rancher-desktop both before and after the rename; the F7 cluster-aware nginx banner work in PR #157 specifically exercises the rancher-desktop branch.

### Validation (Phase 0)

- [x] 0.5 `grep -rn "platforms/aks/" --include="*.sh" --include="*.yml" --include="*.md" .` returns no hits except in the parent investigation file (which references "today's `platforms/aks/`" historically).
- [x] 0.6 Phase 1 builds on `platforms/azure-aks/` going forward — every new file in the wizard lands in the new path.

**Note on commit shape**: do the rename as its own commit at the head of this PR, separate from new files. Makes the rename diff readable and reviewable independently.

---

## Phase 1: Create shared Azure discovery library

`provision-host/uis/lib/azure-discovery.sh` is the third layer of Q8's split — the reusable Azure pieces that the per-platform `init.sh` orchestrates. Sourced from `init.sh` (and, eventually, from `platforms/azure-microk8s/scripts/init.sh` when that lands).

### Functions in the library

Each function:
- Sets `set -euo pipefail` at its own start (defense in depth — caller should too)
- Streams visible output per Q10 (no spinners, no swallowed stdout)
- Returns 0 on success, non-zero on failure (with `set -e` in the caller, that aborts the wizard)
- Reads/writes a small set of well-known env vars (`AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `AZURE_SUBSCRIPTION_NAME`, `AZURE_REGION`) rather than passing them via stdout capture

### Tasks

- [x] 1.1 `require_tools_or_die()` — preflight. Verifies `command -v az` and `command -v tofu` both succeed. If not, prints `Run './uis tools install azure-aks' to install the AKS dependencies.` and exits non-zero. (PLAN #1 from this investigation set is the named install command.)

- [x] 1.1b `require_interactive_or_die()` — preflight. The wizard is interactive-only per Q5; refuse early and clearly if it can't run interactively rather than letting `read` fail mysteriously mid-wizard.

  ```bash
  require_interactive_or_die() {
      set -euo pipefail
      if [[ -n "${UIS_NONINTERACTIVE:-}" ]] || [[ ! -t 0 ]]; then
          echo "✗ This wizard requires an interactive terminal."
          if [[ -n "${UIS_NONINTERACTIVE:-}" ]]; then
              echo "  UIS_NONINTERACTIVE is set, but ./uis platform init does not yet support"
              echo "  non-interactive mode. (See Q5 in INVESTIGATE-platform-aks-novice-onboarding.md."
              echo "  Non-interactive mode lands when a real CI/scripted consumer surfaces.)"
          else
              echo "  No TTY attached to stdin. Run this command directly from your terminal,"
              echo "  not via 'docker exec' without -it or piped from a script."
          fi
          exit 1
      fi
  }
  ```

  Triggered by either `UIS_NONINTERACTIVE=1` (mirrors PR #149's `UIS_DESTROY_CONFIRM` pattern) OR no TTY on stdin (defensive: if someone pipes the wizard from a script, `read` would block forever). Both paths fail-fast with the right diagnostic.

- [x] 1.2 `az_login_if_needed()` — checks `az account show >/dev/null 2>&1`. If logged in, prints `Already signed in to Azure as $(az account show --query user.name -o tsv)`. If not, runs `az login --use-device-code` (device-code, not browser, because the container has no display). Mines the pattern from `hosts/azure-aks/01-azure-aks-create.sh:128-140`.

- [x] 1.3 `pick_subscription()` — interactive numbered picker. Implementation:
  ```bash
  pick_subscription() {
      set -euo pipefail
      echo "Available subscriptions:"
      local subs
      mapfile -t subs < <(az account list --query "[].{name:name, id:id}" -o tsv)
      local i=1
      for sub in "${subs[@]}"; do
          local name="${sub%$'\t'*}"
          local id="${sub##*$'\t'}"
          echo "  $i) $name ($id)"
          ((i++))
      done
      local choice
      read -rp "Pick a subscription [1-${#subs[@]}]: " choice
      # validate, set AZURE_SUBSCRIPTION_ID, AZURE_SUBSCRIPTION_NAME
      # az account set --subscription "$AZURE_SUBSCRIPTION_ID"
      # AZURE_TENANT_ID=$(az account show --query tenantId -o tsv)
  }
  ```
  If only one sub, auto-select with `Auto-selected: $name (only subscription available)`. Validates the picked number is in range; aborts on invalid input (per Q7 fail-fast).

- [x] 1.4 `check_owner_or_contributor()` — role-check with PIM-activation retry loop. Mines `hosts/azure-microk8s/01-azure-vm-create-redcross-v2.sh:36-83` (retry 3x with portal link + "press Enter") and combines it with PR #149's `--include-inherited --include-groups` flags. Fail-fast per Q7 means the wizard refuses to proceed if the role is missing after the retries; it does NOT mean "abort on the first negative check" — PIM activation is a known interactive recovery path that legacy users rely on.

  ```bash
  check_owner_or_contributor() {
      set -euo pipefail
      local upn
      upn=$(az account show --query user.name -o tsv)
      local attempt
      for attempt in 1 2 3; do
          echo "Checking role on subscription $AZURE_SUBSCRIPTION_ID for $upn (attempt $attempt/3)..."
          local roles
          roles=$(az role assignment list \
              --assignee "$upn" \
              --scope "/subscriptions/$AZURE_SUBSCRIPTION_ID" \
              --include-inherited --include-groups \
              --query "[?roleDefinitionName=='Owner' || roleDefinitionName=='Contributor'].roleDefinitionName" \
              -o tsv 2>/dev/null | sort -u)
          if [[ -n "$roles" ]]; then
              echo "✓ Role: $roles"
              return 0
          fi
          echo
          echo "✗ $upn does not currently have Owner or Contributor on this subscription."
          if (( attempt < 3 )); then
              echo "  If your role is assigned via Azure AD PIM, activate it now:"
              echo "  https://portal.azure.com/?feature.msaljs=true#view/Microsoft_Azure_PIMCommon/ActivationMenuBlade/~/azurerbac"
              read -rp "  After activating, press Enter to re-check (or Ctrl-C to abort): " _
          fi
      done
      echo
      echo "✗ Role check failed after 3 attempts. Aborting."
      echo "  Either pick a different subscription, request a role assignment,"
      echo "  or activate Owner/Contributor via the PIM link above and re-run './uis platform init azure-aks'."
      exit 1
  }
  ```

  Why retry-3x is kept: the legacy `hosts/azure-microk8s/` author put it there for a specific reason — PIM activation is a *normal* recovery path (not an error edge case), and forcing the user to re-run the whole wizard after PIM activation costs them the sub/region picks they already made. The retry loop is interactive ("press Enter after activating"), so it costs nothing on the happy path (first attempt succeeds, function returns immediately) and prevents lost work on the recovery path.

- [x] 1.5 `check_quota()` — port from `hosts/azure-aks/check-aks-quota.sh:56-170`. Calculate required vCPUs based on hardcoded defaults (`AZURE_NODE_COUNT=1`, `AZURE_NODE_SIZE=Standard_B2s_v2` → 2 vCPUs). Query `az vm list-usage --location "$AZURE_REGION" --query "[?contains(name.value,'standardBSFamily')]"`. Abort with quota-increase link if insufficient. Runs *after* region pick (needs `AZURE_REGION`).

- [x] 1.6 `pick_region()` — single prompt with `westeurope` as the verified-working default. Empty input takes the default; non-empty is validated against `az account list-locations` and re-prompts on typo. No numbered list of ~60 regions, no curated short list, no per-region AKS-availability pre-validation.

  ```bash
  pick_region() {
      set -euo pipefail
      local default_region="westeurope"
      local region
      while true; do
          read -rp "Region [$default_region]: " region
          region="${region:-$default_region}"
          if az account list-locations --query "[?name=='$region'].name" -o tsv | grep -q .; then
              AZURE_REGION="$region"
              echo "✓ Region: $AZURE_REGION"
              return 0
          fi
          echo "Unknown region '$region'. List available regions with: az account list-locations -o table"
          echo
      done
  }
  ```

  Why `westeurope` is the default: it's what PR #149's Tier A verification rounds ran against, what `platforms/azure-aks/tofu/variables.tf` defaults to, and what `01-apply.sh` is known-good against. Novice presses Enter → they get the verified-working path for free. Power users type whatever region they want; if AKS isn't supported there, `01-apply.sh` fails with tofu's own error. Acceptable cost for the 1% case since the default works for the 99%.

- [x] 1.7 `register_providers()` — blocking provider registration per Q6 + Q10. For each of the four providers (`Microsoft.ContainerService`, `Microsoft.Compute`, `Microsoft.Network`, `Microsoft.Storage`):
  ```bash
  register_one_provider() {
      local provider="$1"
      local state
      state=$(az provider show --namespace "$provider" --query registrationState -o tsv)
      if [[ "$state" == "Registered" ]]; then
          echo "$provider: already Registered"
          return 0
      fi
      echo "$provider: Registering..."
      az provider register --namespace "$provider" >/dev/null
      local start_ts elapsed
      start_ts=$(date +%s)
      while true; do
          state=$(az provider show --namespace "$provider" --query registrationState -o tsv)
          elapsed=$(( $(date +%s) - start_ts ))
          if [[ "$state" == "Registered" ]]; then
              echo "$provider: Registered (${elapsed}s)"
              return 0
          fi
          if (( elapsed > 600 )); then
              echo "✗ $provider: timed out after ${elapsed}s (state still: $state)"
              echo "  Check Azure Portal or contact your subscription admin."
              return 1
          fi
          echo "$provider: $state... (${elapsed}s)"
          sleep 5
      done
  }
  ```
  `register_providers()` calls `register_one_provider` for each of the four sequentially (per Q3: stop on first failure, no rollback).

- [x] 1.8 `prompt_overwrite_if_exists()` — per Q4. If `.uis.secrets/cloud-accounts/azure-default.env` exists, prompt `Overwrite existing config? (y/N):`. Empty or `n`/`N` aborts the wizard with `Aborting. Delete the file manually or pick a different cloud-accounts target.` and exits 0 (clean exit, not an error).

- [x] 1.9 `write_env_atomically()` — atomic single-file replacement. Writes to `.uis.secrets/cloud-accounts/azure-default.env.tmp` then `mv`. Content templated from `provision-host/uis/templates/uis.secrets/cloud-accounts/azure.env.template`, populated with `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `AZURE_REGION` (and any other template variables the file declares).

### Validation (Phase 1)

- [x] 1.10 `bash -n provision-host/uis/lib/azure-discovery.sh` parses cleanly.
- [x] 1.11 Each function can be sourced standalone and invoked with mocked `az` if needed (smoke test, not a full unit-test suite). — verified 2026-05-11 in the running container: `source azure-discovery.sh` succeeds and `type require_tools_or_die` resolves the function.
- [x] 1.12 No `|| true` masking, no regex on JSON output (uses `--query` + `-o tsv` exclusively) — per the parent investigation's "Anti-patterns to NOT carry forward" list.

---

## Phase 2: Create per-platform `init.sh` wizard

`platforms/azure-aks/scripts/init.sh` is Q8's middle layer — orchestrates the library functions in order, ~50 lines. Sibling to the existing `00-bootstrap-state.sh` / `01-apply.sh` / `02-post-apply.sh` / `03-destroy.sh`.

### Tasks

- [x] 2.1 Create `platforms/azure-aks/scripts/init.sh`:
  ```bash
  #!/bin/bash
  # init.sh — Interactive wizard for AKS cluster onboarding.
  # Spec: website/docs/ai-developer/plans/active/PLAN-uis-platform-init-azure-aks.md
  set -euo pipefail

  # Locate the shared library (relative to this script)
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  UIS_LIB="${UIS_LIB:-$SCRIPT_DIR/../../../provision-host/uis/lib}"
  source "$UIS_LIB/azure-discovery.sh"

  echo "═══════════════════════════════════════════════"
  echo " AKS cluster setup wizard"
  echo "═══════════════════════════════════════════════"
  echo

  # Preflight
  require_interactive_or_die   # Q5 — refuse early if no TTY or UIS_NONINTERACTIVE=1
  require_tools_or_die

  # Q4 — overwrite prompt
  prompt_overwrite_if_exists

  # Discovery (Q7 fail-fast ordering: each step surfaces failures the moment its input is known)
  az_login_if_needed
  pick_subscription              # sets AZURE_SUBSCRIPTION_ID, _NAME, AZURE_TENANT_ID
  check_owner_or_contributor     # FAIL FAST: abort if no Owner/Contributor
  pick_region                    # sets AZURE_REGION
  check_quota                    # FAIL FAST: abort if insufficient quota for the chosen region
  register_providers             # BLOCK until all four are Registered (per Q6)

  # Persist
  write_env_atomically

  # Summary
  echo
  echo "✓ AKS setup ready."
  echo "  Subscription: $AZURE_SUBSCRIPTION_NAME ($AZURE_SUBSCRIPTION_ID)"
  echo "  Region:       $AZURE_REGION"
  echo "  Config:       .uis.secrets/cloud-accounts/azure-default.env"
  echo
  echo "Next: ./uis platform up azure-aks"
  ```

- [x] 2.2 Make it executable: `chmod +x platforms/azure-aks/scripts/init.sh`.

### Validation (Phase 2)

- [x] 2.3 `bash -n platforms/azure-aks/scripts/init.sh` parses cleanly.
- [x] 2.4 Script can be invoked directly (without the dispatcher) for debugging — verify it sources `azure-discovery.sh` cleanly with `UIS_LIB` defaulting correctly. — verified 2026-05-11: direct invocation prints the banner and reaches `require_interactive_or_die` (proves library sourced, default `UIS_LIB` resolved).

---

## Phase 3: Add `cmd_platform_init` dispatcher to `uis-cli.sh`

Q8's outer layer — thin dispatcher in `provision-host/uis/manage/uis-cli.sh`. Adds `./uis platform <subcmd> <args>` parallel to `./uis stack` / `./uis tools`. Only `init` is wired in this PR; `up` and `down` follow in PLANs #3 and #4 (placeholders are explicit "not yet implemented" rather than silent missing-command errors).

### Tasks

- [x] 3.1 Add `cmd_platform` sub-dispatcher to `uis-cli.sh`, near the existing `cmd_stack` / `cmd_tools`:
  ```bash
  cmd_platform() {
      local subcmd="${1:-}"
      shift || true

      case "$subcmd" in
          init)
              cmd_platform_init "$@"
              ;;
          up|down)
              log_error "'./uis platform $subcmd' is not yet implemented (PLAN #3/#4 follows PLAN #2 from INVESTIGATE-platform-aks-novice-onboarding.md)"
              exit "$EXIT_GENERAL_ERROR"
              ;;
          *)
              log_error "Unknown platform subcommand: $subcmd"
              echo "Usage: uis platform [init|up|down] <provider>"
              exit "$EXIT_GENERAL_ERROR"
              ;;
      esac
  }
  ```

- [x] 3.2 Add `cmd_platform_init` thin dispatcher:
  ```bash
  cmd_platform_init() {
      local provider="${1:-}"
      if [[ -z "$provider" ]]; then
          log_error "Usage: uis platform init <provider>"
          echo "Available platforms:"
          local p
          for p in "$REPO_ROOT"/platforms/*/scripts/init.sh; do
              [[ -f "$p" ]] || continue
              echo "  - $(basename "$(dirname "$(dirname "$p")")")"
          done
          exit "$EXIT_GENERAL_ERROR"
      fi

      local script="$REPO_ROOT/platforms/$provider/scripts/init.sh"
      if [[ ! -f "$script" ]]; then
          log_error "Unknown platform '$provider' (no init.sh found at $script)"
          exit "$EXIT_GENERAL_ERROR"
      fi

      exec "$script"
  }
  ```

- [x] 3.3 Wire `platform` into the top-level `main()` case statement next to `stack)` and `tools)`:
  ```bash
  platform)
      cmd_platform "$@"
      ;;
  ```

- [x] 3.4 Update `./uis help` / usage banner to include `platform` in the list of commands.

### Validation (Phase 3)

- [x] 3.5 `./uis platform` (no args) prints usage with the available platforms list. — verified 2026-05-11: `Usage: uis platform <subcmd> <provider>` + `Subcommands: init | up | status | down`, exit 1.
- [x] 3.6 `./uis platform init` (no provider) prints usage + the platforms list discovered from `platforms/*/scripts/init.sh`. — verified 2026-05-11: `Available platforms: - azure-aks`, exit 1.
- [x] 3.7 `./uis platform init nonexistent` exits with `Unknown platform 'nonexistent'...`. — verified 2026-05-11.
- [x] 3.8 ~~`./uis platform up azure-aks` and `./uis platform down azure-aks` print the "not yet implemented" message and exit non-zero (placeholders for PLANs #3 and #4).~~ **Superseded** — PR #156 shipped both `up` and `down`. The placeholders were intentionally short-lived; today both commands work end-to-end (verified talk44 + talk46 R3).

---

## Phase 4: Tester verification (talk.md round)

End-to-end test against a real Azure subscription. The tester drives this since it requires Azure auth + a real subscription with quota (UIS contributor never runs cloud deploys per the testing-protocol memory).

### Tasks

- [x] 4.1 File the verification round at `testing/uis1/talk/talk.md`, archiving the current talk.md (the meta-tool round) as the next sequential `talk*.md`.
- [x] 4.2 Tester rounds to cover (closed in talk43):
  - **R0** — local image preflight, confirm `platforms/azure-aks/scripts/init.sh` is present.
  - **R1** — `./uis platform` and `./uis platform init` with no args; verify usage + platforms list rendering.
  - **R2** — `./uis platform init azure-aks` happy path against a real Azure sub. Verify: az login prompt, sub picker, role check pass, region picker (westeurope default), quota check pass, all four providers go from Registered/Registering → Registered with annotated per-poll output, env file written atomically. Paste the full transcript.
  - **R3** — re-run on the same setup. Verify: overwrite prompt y/N appears, `n` aborts cleanly, `y` re-runs the wizard.
  - **R4** — fail-fast checks: (a) intentionally pick a sub the user has no role on (if such a sub is available), verify the role check aborts with the PIM link; (b) intentionally pick a region with insufficient quota, verify quota check aborts.
  - **R5** — placeholder commands: `./uis platform up azure-aks` and `./uis platform down azure-aks` should print "not yet implemented" and exit non-zero.

### Validation (Phase 4)

- [x] 4.3 Tester closes Rounds 0–3 green. Rounds 4 and 5 are optional but valuable. — talk43 closed R0–R3; R5 was retired by PR #156 (no more "not yet implemented" placeholders to verify).

---

## Verification gate before merge

- [x] All Phase 0/1/2/3 `bash -n` checks pass.
- [x] `grep -rn "platforms/aks/" --include="*.sh" --include="*.yml" --include="*.md"` returns no stale references (Phase 0 complete).
- [x] Tester closes Phase 4 Round 2 (happy path) at minimum. Rounds 3, 4, 5 nice-to-have but not blocking. — talk43 R2 cold run cleared.
- [x] Local Docusaurus build clean for the PLAN file.
- [x] PR description includes the cold-run transcript from R2 (proves the wizard works end-to-end against a real Azure subscription).

---

## What this PLAN deliberately does NOT do

- **Add `up`/`down` wrappers.** Placeholder messages only. PLANs #3 and #4.
- **Add `--non-interactive` mode.** Q5 — deferred. Interactive only.
- **Drop the PIM retry loop.** The legacy retry-3x ("press Enter after activating PIM, we'll re-check") is *kept* in `check_owner_or_contributor` — it's a normal recovery path, not an edge case. See Phase 1, task 1.4 for the rationale.
- **Add `kubelogin` to the dependency check.** Today's tofu module uses local-account auth; `kubelogin` is only needed if/when we switch to AAD-integrated AKS.
- **Cache subscription / region picks across runs.** Each `init` invocation re-prompts. The env file persists the choices, but the wizard itself is stateless across invocations.
- **Hide `tofu apply`'s output behind a spinner during `up`.** Q10 — always have output. The future `up` chain streams everything through.

---

## Related

- [INVESTIGATE-platform-aks-novice-onboarding.md](./INVESTIGATE-platform-aks-novice-onboarding.md) — parent investigation. All 15 design questions decided 2026-05-10.
- [PLAN-uis-tools-install-azure-aks.md](./PLAN-uis-tools-install-azure-aks.md) — PLAN #1 (PR #154, merged 2026-05-10). Provides `./uis tools install azure-aks` which `require_tools_or_die()` points the user at.
- [PLAN-tool-installer-error-handling.md](./PLAN-tool-installer-error-handling.md) — PR #152, merged 2026-05-10. Establishes the `set -euo pipefail` + contract-block pattern this PLAN's library functions follow.
- `hosts/azure-aks/01-azure-aks-create.sh:128-140` — `az login` + device-code fallback pattern that `az_login_if_needed()` mines.
- `hosts/azure-aks/check-aks-quota.sh:56-170` — quota-validation pattern that `check_quota()` mines.
- `hosts/azure-microk8s/01-azure-vm-create-redcross-v2.sh:36-83` — PIM portal link that the role-check failure message reuses (without the retry loop).
- `provision-host/uis/manage/uis-cli.sh:1018` — `cmd_init` (UIS-level setup wizard). Pattern reference for `cmd_platform_init`.
- **Next**: PLAN #3 — `./uis platform up azure-aks` chain wrapper. Trivial once `init` ships; runs `00-bootstrap-state.sh` → `01-apply.sh` → `02-post-apply.sh` per Q9.
