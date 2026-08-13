# Plan: AKS Step 1 — Verify minimal working cluster end-to-end

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: ✅ Completed (2026-05-11)

**Note on path**: this PLAN scoped a manual-walkthrough verification (run the four lifecycle scripts directly, then `./uis deploy nginx`, then `03-destroy.sh`). The actual verification happened differently — by the time the cold cycle ran end-to-end (talk46 R3), the four-PLAN AKS novice-onboarding sequence ([INVESTIGATE-platform-aks-novice-onboarding.md](./INVESTIGATE-platform-aks-novice-onboarding.md)) had also shipped, so verification ran through the new `uis platform up azure-aks` + `uis platform down azure-aks` wrappers instead of the raw scripts. The verification bar (`./uis deploy nginx` succeeds with the in-cluster connectivity tests passing, cluster cleanly torn down afterward) was met regardless. See the "Findings from first-run verification" subsection in [INVESTIGATE-system-platform-provisioning-layer.md](../backlog/INVESTIGATE-system-platform-provisioning-layer.md) for the full chronology.

**Goal**: Take the unverified `platforms/azure-aks/` OpenTofu drafts (merged 2026-04-09 via PR #120) through their first real end-to-end run against an Azure subscription, fix any gaps that surface, and earn the right to call AKS Step 1 *actually* shipped — by deploying `./uis deploy nginx` against the resulting cluster and watching its built-in connectivity tests pass.

**Last Updated**: 2026-05-11

**Investigation**: [INVESTIGATE-system-platform-provisioning-layer.md](../backlog/INVESTIGATE-system-platform-provisioning-layer.md) — Step 1 scope, verification bar, and gap-analysis findings.

---

## Problem Summary

`platforms/azure-aks/` contains four scripts (`00-bootstrap-state.sh`, `01-apply.sh`, `02-post-apply.sh`, `03-destroy.sh`) plus an OpenTofu module (`tofu/main.tf` etc.) that have never been run against a real Azure subscription. One known issue from the 2026-05-07 gap analysis must be fixed before the first run can succeed: the `uis-provision-host` container has no `tofu` binary. There's an installer for `azure-cli` at `provision-host/uis/tools/install-azure-cli.sh` but no equivalent for OpenTofu.

Beyond that, the dominant risk is *un-run risk*: bugs and small omissions only surface when scripts execute against real Azure resources for the first time. This plan reserves a phase for that iterative discovery.

The other 2026-05-07 gap (missing `kubernetes-secrets.yml` apply step in `02-post-apply.sh`) is split out into [PLAN-platform-aks-002-secrets-apply-parity.md](./PLAN-platform-aks-002-secrets-apply-parity.md). The verification bar here is `./uis deploy nginx`, and nginx doesn't need cluster secrets — so the secrets-parity gap doesn't block this PLAN. It just means the cluster after this PLAN ships is verified for nginx but won't yet be ready for secret-using UIS services like postgresql. PLAN-002 closes that.

---

## Phase 1: OpenTofu installer

Add `tofu` to the on-demand `./uis tools install` system, mirroring the existing `install-azure-cli.sh`.

### Tasks

- [x] 1.1 Create `provision-host/uis/tools/install-opentofu.sh`. Match the shape of `install-azure-cli.sh`:
  - `TOOL_ID="opentofu"`
  - `TOOL_NAME="OpenTofu"`
  - `TOOL_DESCRIPTION="Open-source infrastructure-as-code tool (Terraform fork)"`
  - `TOOL_CATEGORY="CLOUD_TOOLS"`
  - `TOOL_CHECK_COMMAND="command -v tofu"`
  - `TOOL_SIZE="~30MB"`
  - `TOOL_WEBSITE="https://opentofu.org/"`
  - `do_install()` runs the official installer with the apt-method (creates apt repo + installs system-wide), so the install pattern matches azure-cli's `sudo bash` flow:
    ```bash
    curl --proto '=https' --tlsv1.2 -fsSL https://get.opentofu.org/install-opentofu.sh -o /tmp/install-opentofu.sh
    chmod +x /tmp/install-opentofu.sh
    sudo /tmp/install-opentofu.sh --install-method deb
    rm /tmp/install-opentofu.sh
    ```
  - `do_uninstall()` removes the apt package and the apt source list (parallel to azure-cli's uninstall).

- [x] 1.2 Confirm `./uis tools list` discovers the new entry — the listing logic in `provision-host/uis/lib/tool-installation.sh:get_all_tool_ids` reads any `install-*.sh` script's `TOOL_ID=` line, so no registry edit is needed.

### Validation

Tester runs:
```
docker exec -it uis-provision-host bash -lc "./uis tools list"
```
…and sees `opentofu` listed with status `❌ Not installed`. Then:
```
./uis tools install opentofu
tofu --version
```
…installs cleanly and reports a version `>= 1.6.0` (the minimum the existing `tofu/main.tf` requires).

---

## Phase 2: First-run verification by tester (against real Azure)

The tester runs the full `platforms/azure-aks/` flow against an Azure subscription and reports results. This is where un-run risk surfaces.

### Tasks

- [x] 2.1 Install tooling: `./uis tools install azure-cli && ./uis tools install opentofu`. Verify `az --version` and `tofu --version` both work. — superseded by [PLAN-uis-tools-install-azure-aks.md](../completed/PLAN-uis-tools-install-azure-aks.md) (PR #154): the meta-installer `uis tools install azure-aks` bundles both, used in talk46.

- [x] 2.2 ~~Create `platforms/azure-aks/azure-aks-config.sh` from the template~~. **Superseded** by [PLAN-aks-config-cloud-accounts.md](../completed/PLAN-aks-config-cloud-accounts.md) (PR #146): config now lives at `.uis.secrets/cloud-accounts/azure-default.env`, written by the `uis platform init azure-aks` wizard ([PLAN-uis-platform-init-azure-aks.md](../completed/PLAN-uis-platform-init-azure-aks.md), PR #155).

- [x] 2.3 Log into Azure — handled by the wizard's `az_login_if_needed` / device-code flow. The PIM-activation retry loop from `hosts/azure-microk8s/` was ported into `check_owner_or_contributor` ([PLAN-uis-platform-init-azure-aks.md](../completed/PLAN-uis-platform-init-azure-aks.md) Phase 1.4).

- [x] 2.4 Run `platforms/azure-aks/scripts/00-bootstrap-state.sh`. — ran successfully in talk46 R3 as step `▶ 1/3` of `uis platform up azure-aks`. State RG + storage account (derived from the subscription ID) + container + versioning all created.

- [x] 2.5 Run `platforms/azure-aks/scripts/01-apply.sh`. — ran successfully in talk46 R3 as step `▶ 2/3`. `tofu apply` created RG + Log Analytics workspace + AKS cluster (Standard_B2s_v2 × 1, k8s 1.34). Subscription-quota check now ported into the wizard (stronger than the originally-deferred plan).

- [x] 2.6 Run `platforms/azure-aks/scripts/02-post-apply.sh`. — ran successfully in talk46 R3 as step `▶ 3/3`. Kubeconfig merged, storage class aliases applied, Traefik installed, external IP provisioned. `kubernetes-secrets.yml` apply gap closed separately by [PLAN-platform-aks-002-secrets-apply-parity.md](./PLAN-platform-aks-002-secrets-apply-parity.md) (PR #149).

- [x] 2.7 Verify with `./uis deploy nginx`. — verified in talk46 R3: pod scheduled, service reachable, IngressRoute applied, in-cluster connectivity tests (steps 13 + 15 of `020-setup-nginx.yml`) both succeeded. Public smoke `curl http://<external-ip>/` returned the catch-all page end-to-end. The F7 cluster-aware banner (PR #157) also rendered the correct LB IP + curl --resolve hint for hostname routes.

- [x] 2.8 Tear-down via `03-destroy.sh`. — verified in talk46 R3 via `uis platform down azure-aks`. Cluster RG and Log Analytics destroyed; state RG `rg-urbalurba-tfstate` preserved as designed. `az aks list -o table` returned empty afterward.

- [x] 2.9 Capture every observation — what worked, what failed, what was confusing — in a tester report. — captured across `testing/uis1/talk/talk43.md` through `talk46.md`. F1–F13 findings list lives in [INVESTIGATE-system-platform-provisioning-layer.md](../backlog/INVESTIGATE-system-platform-provisioning-layer.md) "Findings from first-run verification".

### Validation

`./uis deploy nginx` succeeds end-to-end and the 020-setup-nginx.yml connectivity tests print the expected response. Tester confirms cluster is destroyed afterward (cost gate).

---

## Phase 3: Address gaps surfaced in Phase 2

This phase is intentionally open-ended — until Phase 2 runs, the catalogue of bugs is unknown. Each gap surfaces as a small commit that re-enables a previously-failing Phase 2 task. Re-runs continue until Phase 2 passes cleanly.

### Tasks (placeholder — to be enumerated as gaps surface)

- [x] 3.x (per gap) Make the smallest fix that closes the gap. — surfaced as F1–F13 across PRs #155 (init), #156 (up + down + F1–F5), #157 (F7/F8/F9 + cosmetic), #158 (F10/F11/F12/F13 + workflow path-filter fix). Each fix targeted `platforms/azure-aks/` source rather than working around in config, per the original principle.

- [x] 3.y (per gap) Re-run the affected Phase 2 step. — every fix was followed by either a fresh tester round (talk44 → talk45 → talk46 → talk47-in-the-making) or, for trivially-verifiable ones, in-container smoke tests. The end-to-end cycle in talk46 R3 ran cleanly with all surfaced fixes in place.

### Validation

Phase 2 tasks all pass on a fresh clean run (i.e., starting from `00-bootstrap-state.sh`).

---

## Phase 4: Status sync

Once Phase 2 passes cleanly, mark Step 1 actually shipped.

### Tasks

- [x] 4.1 Update `INVESTIGATE-system-platform-provisioning-layer.md` Step 1 heading + add "Findings from first-run verification" subsection. — done 2026-05-11 as part of this cleanup PR.

- [x] 4.2 Update `1PRIORITY.md` Tier 0 row for `platform-provisioning-layer`. — done 2026-05-11 as part of this cleanup PR.

- [x] 4.3 Move this PLAN file to `completed/`. — done 2026-05-11 as part of this cleanup PR.

### Validation

User confirms Step 1 status accurately reflects the verified state.

---

## Acceptance Criteria

- [x] `provision-host/uis/tools/install-opentofu.sh` exists and follows the shape of `install-azure-cli.sh`. `./uis tools install opentofu` installs cleanly and `tofu --version` reports `>= 1.6.0`.
- [x] Tester has run `00 → 01 → 02 → ./uis deploy nginx → 03` end-to-end against a real Azure subscription, with the `020-setup-nginx.yml` connectivity tests succeeding. — talk46 R3, via the `uis platform up/down azure-aks` wrappers.
- [x] Cluster has been cleanly destroyed at the end of the verification run (cost gate). — talk46 R3 close, `az aks list -o table` empty afterward, ~€0.02 total cost for the cycle.
- [x] `INVESTIGATE-system-platform-provisioning-layer.md` and `1PRIORITY.md` reflect Step 1 as shipped (not "drafts merged").
- [x] This plan is in `completed/`.

---

## Files to Modify

- `provision-host/uis/tools/install-opentofu.sh` (new)
- `platforms/azure-aks/azure-aks-config.sh` (new, git-ignored, tester sets up in Phase 2.2)
- `website/docs/ai-developer/plans/backlog/INVESTIGATE-system-platform-provisioning-layer.md` (Phase 4)
- `website/docs/ai-developer/plans/backlog/1PRIORITY.md` (Phase 4)
- `website/docs/ai-developer/plans/active/PLAN-001-aks-step1-verification.md` → `completed/` (Phase 4)
- Additional `platforms/azure-aks/` files only as Phase 3 gaps require.

---

## Implementation Notes

- **Cost gate.** AKS clusters bill while running. The Phase 2 verification is expected to be a same-session run-through ending in `03-destroy.sh`. If a run is interrupted, run `03-destroy.sh` before stepping away from the keyboard.
- **State backend persists across destroys.** `00-bootstrap-state.sh` creates a state RG / storage account that is *not* torn down by `03-destroy.sh`. That's by design (state survives cluster recreate cycles). It costs a few cents a month, not a real concern.
- **No Key Vault, no ACR.** Step 1 deliberately matches the Rancher Desktop secrets workflow (`kubernetes-secrets.yml`). Azure-specific add-ons are deferred to "Future hardening" in the investigation.
- **Secrets parity is split out.** PLAN-002 closes the `kubernetes-secrets.yml` apply gap on `02-post-apply.sh`. nginx doesn't need it; everything else does. Sequencing is loose — PLAN-002 can run before or after this plan ships, but the natural order is verify first (this plan), then extend (PLAN-002).
- **Tester reports against this plan.** Phase 2's tester report is the highest-signal artifact. Capture surprises in detail — they shape Phase 3 and inform PLAN-002 and Step 2's eventual PLAN.
