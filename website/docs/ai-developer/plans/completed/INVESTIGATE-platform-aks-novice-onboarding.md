# Investigate: compress the AKS novice-onboarding flow with `./uis platform` wrapper commands

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Completed — proposed target flow shipped end-to-end; decisions Q1-Q3 implemented

The target six-command novice flow is live and documented:

```
./uis pull                         # 1
./uis tools install azure-aks      # 2  (meta-installer per Q1/Q2 — provision-host/uis/tools/install-azure-aks.sh)
./uis platform init azure-aks      # 3  (wizard per Q4 — platforms/azure-aks/scripts/init.sh)
./uis platform up azure-aks        # 4  (lifecycle wrapper)
./uis deploy nginx                 # 5  (verification)
./uis platform down azure-aks      # 6
```

The `aks/` → `azure-aks/` rename also landed. The AKS guide (`website/docs/platforms/azure-aks.md`) leads with this exact flow.

**Last Updated**: 2026-05-10

**Source**: Surfaced during the AKS platform-doc rewrite (`docs/aks-self-contained` branch, 2026-05-10). The maintainer's read of the in-progress 596-line `azure-aks.md` draft was that "talking about `platforms/aks/scripts/...` without giving the big picture does not work" and that "the goal must be to get a novice user able to set up AKS with a minimum of commands." That reframes the work from "polish the runbook" to "compress the path so the runbook can shrink." The path-compression is what this investigation scopes. The doc rewrite is blocked on its outcome — whatever flow the wrappers settle on is the flow the doc will describe.

---

## Problem Summary

The current novice path from "I have an Azure subscription" to "AKS cluster running an nginx pod I can hit" requires ~8 commands plus an unknown number of UI clicks (Azure Portal sub-discovery), plus a manual `cp` + `vi` of an env-template:

| # | What | Command(s) | Friction |
|---|---|---|---|
| 1 | Install Azure CLI | `./uis tools install azure-cli` | low |
| 2 | Install OpenTofu | `./uis tools install opentofu` | low |
| 3 | `az login` | `az login` (or `az login --use-device-code` from container) | medium — interactive |
| 4 | Discover tenant + sub IDs | `az account show` + scrape JSON | medium — unfamiliar JSON shape |
| 5 | Register Azure resource providers | `az provider register --namespace Microsoft.ContainerService` (×N) | medium — opaque, "what is this for" |
| 6 | Pick a region | (no help — must know Azure regions exist) | medium |
| 7 | Create config file | `cp provision-host/uis/templates/uis.secrets/cloud-accounts/azure.env.template .uis.secrets/cloud-accounts/azure-default.env` then `vi` to fill in IDs from step 4 | **high** — error-prone, paths are deep |
| 8 | Run the four scripts | `./platforms/aks/scripts/00-bootstrap-state.sh && 01-apply.sh && 02-post-apply.sh` | medium — `./platforms/...` paths are unfamiliar |
| (later) | Tear down | `./platforms/aks/scripts/03-destroy.sh` | medium |

The whole flow is what the maintainer was reacting to as "too low-level for a novice." Specifically, **steps 4, 5, 6, 7** are the worst — they assume the user already understands Azure's IAM model and our env-file convention, and they leave the user holding open multiple terminals and the Azure Portal at once.

A reasonable target is ~5 commands, with all the discovery, registration, and config-writing folded into one wizard:

| # | What | Command |
|---|---|---|
| 1 | Install dependencies | `./uis tools install azure-aks` |
| 2 | Set up the cluster config | `./uis platform init azure-aks` |
| 3 | Provision the cluster | `./uis platform up azure-aks` |
| 4 | Deploy something | `./uis deploy nginx` |
| 5 | Tear down | `./uis platform down azure-aks` |

The investigation is about whether that target is right, what each wrapper actually does, and what's worth building in what order.

---

## Out of Scope

- **Provisioning a cluster on `gke`/`eks`/`microk8s-vm`/RPi.** This investigation is AKS-only. Other platforms are governed by [INVESTIGATE-system-platform-provisioning-layer.md](../backlog/INVESTIGATE-system-platform-provisioning-layer.md) and [INVESTIGATE-system-migrate-hosts-to-platforms.md](../backlog/INVESTIGATE-system-migrate-hosts-to-platforms.md). The wrapper-command shape decided here can extend to those later, but the *first* concrete deliverable is AKS-only.
- **Changing the underlying scripts** (`platforms/aks/scripts/00..03`). They stay as the implementation detail. Wrappers call them; novices stop reading them directly.
- **Authentik / SSO / domain wiring.** That's a post-cluster concern; the novice flow stops at "deploy nginx, see it work."
- **Switching AKS to AAD-integrated RBAC.** Today's `platforms/aks/tofu/main.tf` provisions AKS with local-account auth (no `azure_active_directory_role_based_access_control` block). That's why `az aks get-credentials` writes a cert-based kubeconfig and `kubectl` works without `kubelogin`. If we ever switch to AAD-integrated AKS — for per-user identity in audit logs, AD-group-based RBAC, and no shared cert credential — `kubelogin` becomes a hard dependency for every operator and CI runner, and the meta-installer would need to gain it. That's a real architectural decision worth its own investigation; the novice-onboarding wrappers should not pre-judge it.

---

## Wrapper-by-wrapper open questions

### `./uis tools install azure-aks` (meta-installer)

A **single** install command that installs both AKS dependencies in one shot: `azure-cli` and `opentofu`. Currently the user has to run `./uis tools install azure-cli` and `./uis tools install opentofu` as two separate commands and *know* both are needed.

The name `azure-aks` is per-target rather than per-cloud. Future Azure-flavored cluster targets (`azure-microk8s` for MicroK8s on an Azure VM, etc.) get their own meta-tools with their own dependency bundles, since AKS and MicroK8s-on-VM need different toolchains (AKS needs only `az` + `tofu`; MicroK8s-on-VM additionally needs ansible-playbook orchestration that AKS does not).

The same per-target naming applies to the platform CLI verb: `./uis platform init azure-aks`, `./uis platform up azure-aks`, etc. The platform target identifier is `azure-aks` end-to-end — meta-tool, CLI verb, and (presumably) the directory under `platforms/`. Today's `platforms/aks/` directory was named before this convention was established and would need to be renamed to `platforms/azure-aks/` for consistency. That rename is small (the directory only has scripts, tofu module, manifests; ~10 internal path references) but is its own short PLAN since it touches the published PR #149 / PR #151 layout. See **Q8** for where this lands in the wrapper file structure.

**Open questions:**

- **Q1. (Decided 2026-05-10)** Meta-tool name is `azure-aks`. Rationale: per-target naming leaves clean room for `azure-microk8s` (MicroK8s on Azure VM) and other Azure-flavored cluster targets later. Each `<provider>-<target>` meta-tool bundles whatever deps that specific target needs. Naming the meta-tool `azure` would have collided with the Azure-CLI-only sub-tool and forced a single shared dep set across all Azure targets.
- **Q2. (Decided 2026-05-10)** `install-azure-aks.sh` is a regular tool-script that delegates inside `do_install`: `install_tool azure-cli && install_tool opentofu`. No new "meta-tool" concept in `tool-installation.sh`. The script appears in `./uis tools list` for free (the lister iterates `install-*.sh` and reads metadata), with `TOOL_CATEGORY="META"` for optional grouping. `TOOL_CHECK_COMMAND` is a compound: `command -v az >/dev/null && command -v tofu >/dev/null`. Meta-tool's `do_uninstall` is best-effort only — it prints "run uninstall on each component" rather than tearing down sub-tools that the user might want for other reasons.
- **Q3. (Decided 2026-05-10)** On sub-install failure: stop, no rollback. Surface the error (loud failures now reliable after [PLAN-tool-installer-error-handling.md](./PLAN-tool-installer-error-handling.md) shipped), leave the partially-installed components in place, log clearly which step failed. Idempotent re-run via the wrapper's `is_tool_installed` short-circuit picks up where it left off.

### `./uis platform init azure-aks` (interactive wizard)

The most consequential wrapper. Replaces steps 4–8 of today's flow with one interactive command:

```
./uis platform init azure-aks
  → check that az + tofu are installed (else point at `./uis tools install azure-aks`)
  → run `az login` (or `az account show` if already logged in)
  → list subscriptions, prompt user to pick one (or auto-select if only one)
  → ensure the user has Owner/Contributor on the chosen sub (re-using PR #149's role-check logic)
  → list Azure regions, prompt user to pick one (default: westeurope)
  → ensure the four resource providers (ContainerService, Compute, Network, Storage) are registered; register if not, wait for state=Registered
  → write .uis.secrets/cloud-accounts/azure-default.env atomically (single file write at the end, never partial)
  → print summary: "Wrote azure-default.env — sub <name>, region <region>, ready for './uis platform up azure-aks'"
```

**Open questions:**

- **Q4. (Decided 2026-05-10)** If `azure-default.env` already exists: prompt `"overwrite? (y/N)"`, default no. No auto-backup, no silent overwrite. The user controls the outcome; they can pre-delete the file if they want to skip the prompt. (No `--yes` flag — wizard is interactive-only per Q5.)
- **Q5. (Decided 2026-05-10)** Interactive only for now. No `--subscription` / `--region` / `--yes` flags, no `UIS_AZURE_SUBSCRIPTION_ID=...` env-var pre-fills. The wizard prompts for everything it needs and refuses to proceed without a TTY. Rationale: the wizard's job is novice-onboarding; non-interactive mode is for CI / scripted setups, which today is a hypothetical use case. Defer until a real consumer surfaces. When that happens, the env-var pre-fill pattern (mirroring `UIS_DESTROY_CONFIRM=...` from PR #149) is the obvious shape to add.
- **Q6. (Decided 2026-05-10)** Block until all four providers are `Registered`. Follows directly from Q7 (fail fast — surface the "you don't have permission to register providers" failure mode inside the wizard, not 5 minutes later in `01-apply.sh`) and Q5 (interactive only — the user is sitting in front of the wizard, can afford a 2–5 minute wait, can't afford a silent failure surfacing downstream). Q8's `register_providers` library function does the full job in one call: register if not already, poll each `--registration-state` every ~5 seconds and print one annotated line per poll (e.g. `Microsoft.ContainerService: Registering... (15s)`, then `Microsoft.ContainerService: Registered (47s)` — never a bare dot, per Q10's always-have-output principle), give up after a 10-minute timeout, abort the wizard with a clear error on timeout or permission failure. Idempotent on re-run — already-`Registered` providers are verified, not re-registered.
- **Q7. (Decided 2026-05-10)** Fail fast: run the role check inside `init` immediately after the user picks the subscription, before anything else (before region-pick, before provider registration, certainly before `01-apply.sh`). The check stays in `01-apply.sh` too as defense in depth — it's cheap and protects the case where someone runs `up` against a pre-existing `azure-default.env` after their role assignment was revoked. The wizard's check is the primary novice-facing gate; `01-apply.sh`'s is the backstop. The same fail-fast principle applies to neighbouring checks (login state, quota validation per the legacy-mining section, provider registration permission per Q6): surface failures the moment the required input is known, never later.
- **Q8. (Decided 2026-05-10)** Three-layer split:
  1. **Thin dispatcher in `uis-cli.sh`** — `cmd_platform_init` is ~10 lines: parse the `<provider>` arg, validate it, `exec "$repo/platforms/$provider/scripts/init.sh"`. Same shape for `cmd_platform_up` / `cmd_platform_down`. Keeps `uis-cli.sh` generic.
  2. **Per-platform wizard at `platforms/<provider>/scripts/init.sh`** — colocated with its sibling lifecycle scripts (`00-bootstrap-state.sh`, `01-apply.sh`, `02-post-apply.sh`, `03-destroy.sh`). For `azure-aks` this is roughly `source $UIS_LIB/azure-discovery.sh; az_login_if_needed; pick_subscription; check_owner_or_contributor; pick_region; register_providers; write_env_atomically` — ~50 lines of orchestration.
  3. **Shared cloud library at `provision-host/uis/lib/azure-discovery.sh`** — hosts the reusable Azure pieces (`az_login_if_needed`, `pick_subscription`, `check_owner_or_contributor`, `register_providers`, `pick_region`, `write_env_atomically`). When `platforms/azure-microk8s/scripts/init.sh` arrives later, it sources the same library — one source of truth per cloud, directly addressing the PIM-check-duplicated-across-scripts anti-pattern called out in the legacy-mining section. Same shape for `aws-discovery.sh` and `gcp-discovery.sh` when those clouds land.

  Tradeoff accepted: three places to touch when a wizard step changes (dispatcher + per-platform script + library). The cost is small relative to the duplication this prevents the moment a second Azure target lands.

### `./uis platform up azure-aks` (run the lifecycle scripts)

Chains `00-bootstrap-state.sh → 01-apply.sh → 02-post-apply.sh`. Today the novice runs them by hand from `./platforms/aks/scripts/` — that path is unfamiliar and the novice has no signal that they're idempotent (they are) or what each does (they're documented inline but the user has to read three files).

**Open questions:**

- **Q9. (Decided 2026-05-10)** Naive chain. `up` always runs all three lifecycle scripts (`00-bootstrap-state.sh` → `01-apply.sh` → `02-post-apply.sh`) on every invocation. Each is idempotent — `00` is a no-op if the state RG exists, `01` is `tofu apply` (idempotent by definition), `02` does kubeconfig merge + traefik install + cluster-config flip (all idempotent). Warm runs cost a few seconds of "checking..." overhead, and per Q10 (always-have-output) they print why each step is a no-op rather than silently skipping (`00: state RG already exists in <region>, skipping creation` / `01: tofu apply — no changes` / `02: kubeconfig already merged`). The user never has to think about which subset to run; no `--force` / `--skip-*` flags. Tradeoff accepted: a slightly noisier warm run in exchange for not having to teach a "if X then run Y" mental model.
- **Q10. (Decided 2026-05-10)** Always have output. No spinners, no swallowed stdout, no "trust me, working..." UX. This matches the established principle from UIS's Ansible playbooks (verbose-by-default, every step prints what it's doing). For `01-apply.sh`, that means: stream `tofu apply`'s per-resource output through unchanged; the wrapper only adds banners between the three lifecycle scripts (e.g. `▶ 1/3 Bootstrap state...`, `▶ 2/3 Apply cluster...`, `▶ 3/3 Post-apply...`). The same principle applies retroactively to Q6's provider-registration loop: print `Microsoft.ContainerService: Registering... (15s)` / `Microsoft.ContainerService: Registered (47s)` lines per poll, not bare dots. A bare-dot indicator hides what's happening; an annotated per-poll line follows the always-have-output rule.
- **Q11. (Decided 2026-05-10)** Refuse with a pointer. If `.uis.secrets/cloud-accounts/azure-default.env` is missing when `up` is invoked, abort with a clear message:

  ```
  ✗  No config file found at .uis.secrets/cloud-accounts/azure-default.env
     Run './uis platform init azure-aks' first to set one up.
  ```

  Rationale: `init` and `up` have different mental models (`init` configures, `up` provisions). Auto-running init when the env is missing surprises the user with an interactive wizard at a command they thought was just "go provision the cluster" — especially bad in scripted contexts. Refuse-with-pointer respects the explicit-wizard philosophy (Q5) and the fail-fast principle (Q7): tell the user exactly what's wrong and exactly what to type next, immediately.

### `./uis platform down azure-aks` (`03-destroy.sh`)

Direct delegation to `03-destroy.sh`. Already has TTY-guarded confirmation prompts and `UIS_DESTROY_CONFIRM` escape hatch (PR #149). The wrapper is a thin pass-through.

**Open questions:**

- **Q12. (Decided 2026-05-10)** Leave the env file. `down` destroys cloud resources only — `.uis.secrets/cloud-accounts/azure-default.env` stays put. Rationale: the env file is **config**, not state. The user typically rotates the same cluster shape (same sub, same tenant, same region) across multiple up/down cycles; re-running the wizard each time would force them to re-pick the same values. If a "wipe everything including config" need surfaces later it gets its own `./uis platform clean azure-aks` command (out of scope for this investigation). Defense-in-depth note: leaving the env file means the next `up` reuses the same `TENANT_ID` / `SUBSCRIPTION_ID`; if the user actually intended to switch tenants, `01-apply.sh`'s role check (Q7's backstop) will catch it loudly. `down` must print a clear pointer in its output: `Resources destroyed. Config preserved at .uis.secrets/cloud-accounts/azure-default.env — delete this file manually to fully reset.`

---

## Mining the legacy `hosts/` scripts (added 2026-05-10)

The wizard isn't building from scratch — `hosts/azure-aks/` and `hosts/azure-microk8s/` already implement parts of the auth + verification flow. Other parts are entirely absent there too.

### Reuse (port the pattern, don't rewrite)

- **`az login` with device-code fallback** — `hosts/azure-aks/01-azure-aks-create.sh:128-140`. Detects existing session via `az account show`; falls back to `az login --use-device-code` when no session. Same shape for the wizard's "are you already logged in?" preflight.
- **PIM role activation loop with portal link** — `hosts/azure-microk8s/01-azure-vm-create-redcross-v2.sh:36-83`. Polls `az role assignment list --query "[?roleDefinitionName=='Contributor'...]" -o tsv | grep -q .`; on miss, prints the Azure Portal PIM activation URL + `read -p "After activating, press Enter..."` + retries up to 3x. The wizard's role check (Q7) inherits this pattern; combine with the `--include-inherited --include-groups` refinement from PR #149.
- **Quota validation with VM-family-aware vCPU math** — `hosts/azure-aks/check-aks-quota.sh:56-170`. Maps `NODE_SIZE` → vCPUs/node, multiplies by `NODE_COUNT`, queries `az vm list-usage --location "$LOCATION" --query "[?contains(name.value,'standardBSFamily')]"`, suggests "request increase" link or "reduce node count". Worth running inside `init` so the user fails fast on quota issues before `01-apply.sh`.
- **Kubeconfig merge + context flip** — `hosts/azure-aks/02-azure-aks-setup.sh:82-96`. Already exists in modern `platforms/aks/scripts/02-post-apply.sh` and the `04-merge-kubeconf.yml` playbook; the legacy version is the precursor, no need to port.

### Build fresh (legacy doesn't help)

These are the most novice-hostile steps in today's flow, and **none of them have legacy implementations to mine**:

- **Interactive subscription picker.** Every legacy script hardcodes `SUBSCRIPTION_ID` in its config (`hosts/azure-aks/azure-aks-config.sh` lines 7-8 even leaked Red Cross internal IDs into source control — see anti-patterns below). The wizard needs `az account list --query "[].{name:name, id:id, isDefault:isDefault}" -o tsv` + a numbered prompt.
- **Interactive region picker with default.** Legacy hardcodes `LOCATION="westeurope"`. Wizard needs `az account list-locations --query "[?metadata.regionType=='Physical'].name" -o tsv` + numbered prompt with `westeurope` as the default.
- **Provider registration loop.** **Completely absent in legacy** — no `az provider register --namespace ...` calls anywhere, no `--registration-state` polling. The wizard must build this fresh: register the four providers (`Microsoft.ContainerService`, `Microsoft.Compute`, `Microsoft.Network`, `Microsoft.Storage`), poll each until `Registered`, abort with a clear error if a provider fails (likely "you don't have permission to register providers in this subscription" — fail fast here rather than 5 minutes into `01-apply.sh`).
- **Atomic env-file write to `.uis.secrets/cloud-accounts/azure-default.env`.** The template exists at `provision-host/uis/templates/uis.secrets/cloud-accounts/azure.env.template`, but no current script populates it — every legacy flow sources its config directly. Wizard writes the discovered values to a temp file then `mv` to the final path (atomic single-file replacement; never partial).

### Anti-patterns to NOT carry forward

Sourced from the same scripts; calling these out so the new wizard avoids them:

- **Hardcoded subscription / tenant IDs in source control.** `hosts/azure-aks/azure-aks-config.sh:7-8` checked in real Red Cross IDs. The new wizard discovers and writes IDs into `.uis.secrets/cloud-accounts/azure-default.env` (which is gitignored), never into source-controlled config.
- **`|| true` masking errors.** `hosts/azure-aks/02-azure-aks-setup.sh:147-148` uses `helm repo add ... >/dev/null 2>&1 || true`. The wizard runs under `set -euo pipefail` and surfaces failures (consistent with [PLAN-tool-installer-error-handling.md](./PLAN-tool-installer-error-handling.md) shipped 2026-05-10).
- **Regex/awk on JSON outputs.** `hosts/azure-microk8s/01-azure-vm-create-redcross-v2.sh:301-307` runs `'([0-9]{1,3}\.){3}[0-9]{1,3}'` on `--query 'value[0].message'` to extract a Tailscale IP. Brittle. Use `--query "..." -o tsv` directly on structured output, never grep/awk.
- **Duplicated logic across scripts.** The PIM check is copy-pasted identically into `azure-aks/01-azure-aks-create.sh` and `azure-microk8s/01-azure-vm-create-redcross-v2.sh` — no shared library. The new wizard's helpers go in `provision-host/uis/lib/azure-discovery.sh` (or similar) so future `gke`/`eks` wizards can mirror the shape, and so the role check / login / sub-picker each have one home.

---

## Cross-cutting design questions

### Q13 — Does `./uis platform` deserve to be its own command, or does this fold into `./uis init`?

**(Decided 2026-05-10) Option (b)**: `./uis platform init <provider>` is a new top-level subcommand parallel to `./uis init`. Same shape as `./uis stack` / `./uis tools`. Novice runs two setup commands (`./uis init` for UIS-as-a-whole + `./uis platform init azure-aks` for the cluster), but each has one clear job.

Today `./uis init` exists at `cmd_init` in `uis-cli.sh:1018`. It handles UIS-as-a-whole (cluster type, project name, base domain) and does **not** copy cloud-account templates — that's why step 7 of today's novice flow exists. `./uis platform init <provider>` is the missing piece that fills that gap.

Rationale for (b) over the alternatives:

- **vs. (a)** "fold into `./uis init`": (a) would have conflated UIS-level setup with platform-level setup, and forced every future GKE/EKS/azure-microk8s wizard to wedge into a single growing `cmd_init`. Option (b) keeps each provider's wizard in its own `platforms/<provider>/scripts/init.sh` (per Q8) — `cmd_init` stays small and generic, the platform wizards stay isolated and parallel.
- **vs. (c)** "`./uis init` prompts and dispatches": (c) is appealing for the single-command novice experience but requires that `platform init` already exist *and* be proven before the prompt can dispatch to it safely. (c) is a clean follow-up once (b) ships and has a couple of provisioning cycles under its belt.

Pre-decided by Q8 as a side effect: the three-layer split (thin dispatcher in `uis-cli.sh` + per-platform script + shared cloud library) already presumes `cmd_platform_init` as a top-level dispatcher next to `cmd_stack` and `cmd_tools`. Option (a) would have required restructuring Q8's per-platform script approach into a single fat `cmd_init`, contradicting a decision we already locked in.

**Future follow-up (not in scope here)**: once (b) is stable, add (c) as a soft prompt at the end of `./uis init`: "You've configured UIS. Want to set up a cloud platform now? [y/N] — runs `./uis platform init <provider>`." Single command for novices, clean separation under the hood. Files an INVESTIGATE when the time comes.

### Q14 — Per-platform applicability

**(Decided 2026-05-10 — confirmed by Q8)** The interface (`./uis platform init/up/down <provider>`) is portable; the implementation is per-platform. Q8's three-layer split (thin dispatcher + per-platform `scripts/init.sh` + shared cloud library) already settles this structurally: each provider's `init`/`up`/`down` lives in its own `platforms/<provider>/scripts/` directory and can vary freely while sharing helpers via a per-cloud library (`azure-discovery.sh`, `aws-discovery.sh`, `gcp-discovery.sh`).

How this plays out per future target:

- **GKE/EKS**: same wrapper shape applies cleanly. Auth flow differs (`gcloud auth login` / `aws sso login`) but the conceptual steps are identical (login → pick project/account → pick region → enable APIs/services → write env file). Each gets its own discovery library mirroring `azure-discovery.sh`.
- **microk8s-vm** (legacy `hosts/azure-microk8s/`): partial applicability. The "discover" steps simplify (no provider registration), but the manifest changes — "do you want to provision an Azure VM and install MicroK8s on it?" — so the per-platform `init.sh` has different wizard steps. Still fits the dispatcher + per-platform + shared-library shape.
- **microk8s-rpi**: least applicable. Novice physically prepares an SD card; `init` becomes mostly a runbook + minimal config wizard rather than a full auto-pick flow. Probably exposes `up`/`down` against a Tailscale-reachable Pi; `init` is small and mostly informational.

**Out of scope for this investigation**: actually building the GKE/EKS/microk8s-vm/microk8s-rpi wizards. Each lands as its own PLAN when a real consumer surfaces. AKS-first is established (per [INVESTIGATE-system-platform-provisioning-layer.md](../backlog/INVESTIGATE-system-platform-provisioning-layer.md)). This investigation only guarantees that the AKS wrapper's design doesn't paint future platforms into a corner.

### Q15 — Where does the doc-flow story land?

**(Decided 2026-05-10) Option (a): doc waits.** The `azure-aks.md` rewrite (the 596-line WIP on the `docs/aks-self-contained` branch) stays unpublished until the wrapper PRs land, then ships against the 5-command novice flow rather than the 8-step manual flow.

Sizing justifies the wait: four child PLANs total (meta-tool + `init` wizard + `up` chain + `down` pass-through), of which `init` is the only big one (~1–2 contributor sessions + 1–2 tester loops). The others are small or trivial. Total work is days, not weeks.

Rationale for (a) over the alternatives:

- **vs. (b)** "ship the 8-step manual doc now + add a 'soon: wrappers' callout": (b) creates documentation debt — a callout that has to be remembered and deleted once wrappers ship. Every doc that says "we'll do X soon" is a deletion follow-up someone has to track. With the wrapper work measured in days, that debt isn't worth the unblock.
- **vs. (c)** "ship `up` only, defer `init`": partial flow that still forces the novice through the most-painful step (env-file `cp` + `vi`). Worst of both worlds.

The current draft's content survives the wrapper migration as the *per-step explanation of what the wizard does behind the scenes*. The 596-line WIP is mining PLAN-001b correctly; once wrappers ship, the user-facing flow compresses to 5 commands but the page can keep an "under the hood" section explaining what `init` actually does (`az login`, sub-pick, region-pick, provider registration, env-file write). Maintains transparency without forcing the novice to drive each step by hand.

**Defensive posture if wrappers slip**: if the `init` wizard PR runs into unforeseen complexity and slips past ~1 week, revisit (b) at that point. Until then, doc waits.

---

## What this investigation needs to produce

A child PLAN per wrapper that's worth building, ordered for shortest path to "novice can run 5 commands":

1. **PLAN — `./uis tools install azure-aks` meta-tool**. Bundles `azure-cli` + `opentofu`. Estimate: small, ~half a session.
2. **PLAN — `./uis platform init azure-aks` wizard.** The big one. Estimate: 1–2 sessions of code + 1 tester loop.
3. **PLAN — `./uis platform up azure-aks` chain wrapper.** Trivial once init is in place. Estimate: small.
4. **PLAN — `./uis platform down azure-aks` pass-through.** Even more trivial. Estimate: trivial.

Pre-conditions: **all 15 design questions (Q1–Q15) decided as of 2026-05-10.** This investigation is ready to spawn child PLANs. The four PLANs above can land in this dependency order:

1. **Meta-tool first** (smallest, unblocks the rest). Builds on PR #152's hardened tool installers.
2. **`init` wizard next** (the big one — shared `azure-discovery.sh` library + per-platform `platforms/azure-aks/scripts/init.sh` + thin `cmd_platform_init` dispatcher in `uis-cli.sh`, per Q8).
3. **`up` chain wrapper** (trivial — naive chain of the existing three lifecycle scripts, per Q9).
4. **`down` pass-through** (trivial — calls existing `03-destroy.sh`, prints config-preservation pointer per Q12).

Doc rewrite (`azure-aks.md`) waits for #2 to land, per Q15.

---

## Related

- [PLAN-platform-aks-001b-manual-setup.md](../backlog/PLAN-platform-aks-001b-manual-setup.md) — the current "how a human does it" reference. The wrappers automate this; the PLAN stays as the authoritative documentation of *what* gets automated.
- [PLAN-platform-aks-002-secrets-apply-parity.md](./PLAN-platform-aks-002-secrets-apply-parity.md) — secrets-application parity for AKS. Related but orthogonal: that's about *running* on AKS, this is about *getting to* AKS.
- [INVESTIGATE-system-platform-provisioning-layer.md](../backlog/INVESTIGATE-system-platform-provisioning-layer.md) — the broader `platforms/*` architecture. This investigation lives downstream of that one's "AKS-first focus" decision.
- [INVESTIGATE-active-cluster-visibility-ux.md](../completed/INVESTIGATE-active-cluster-visibility-ux.md) — once a novice has clusters across `rancher-desktop` + `azure-aks`, "which cluster am I about to touch?" becomes the next safety problem. Visibility UX dovetails with platform wrappers.
- [PLAN-tool-installer-error-handling.md](./PLAN-tool-installer-error-handling.md) — prerequisite (shipped 2026-05-10 as PR #152). Makes per-tool installs fail loudly, which the meta-tool depends on.
- `provision-host/uis/manage/uis-cli.sh:1018` — `cmd_init` (UIS-level setup wizard). Reference for the wizard pattern; `cmd_platform_init` would parallel it.
