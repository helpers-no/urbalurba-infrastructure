# Plan: AKS — Bring `02-post-apply.sh` secrets-apply step to parity with bash

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Superseded (2026-05-16)

The auto-apply-inside-post-apply approach was not taken. Instead, secrets management is now a separate top-level CLI surface:

- `./uis secrets generate` — renders `kubernetes-secrets.yml` from templates
- `./uis secrets apply` — runs `kubectl apply -f kubernetes-secrets.yml` against the current context (implementation: `provision-host/uis/lib/secrets-management.sh:204`)

The user-facing flow after `./uis platform up azure-aks`:

```bash
./uis platform up azure-aks       # provisions + Traefik
./uis secrets apply                # apply once after cluster is up
./uis deploy <service>             # works
```

The edit-and-reapply path is documented in `website/docs/contributors/architecture/secrets.md` ("Normal commands" block, lines 125-136):

```bash
nano .uis.secrets/secrets-config/00-common-values.env.template
./uis secrets generate
./uis secrets apply
```

This PLAN is preserved in `completed/` as a record of the design path; no further work is planned against `02-post-apply.sh`'s secrets step.

**Goal**: Add a `kubernetes-secrets.yml` apply step to `platforms/azure-aks/scripts/02-post-apply.sh` so that an AKS cluster provisioned via `platforms/azure-aks/` is ready to receive the full UIS service catalogue (postgresql, authentik, openwebui, postgrest, etc.) — not just nginx. Brings the OpenTofu post-apply script into parity with the working bash precedent at `hosts/azure-aks/02-azure-aks-setup.sh:125-141`.

**Last Updated**: 2026-05-07

**Investigation**: [INVESTIGATE-system-platform-provisioning-layer.md](../backlog/INVESTIGATE-system-platform-provisioning-layer.md) — gap-analysis finding #1 (kubernetes-secrets.yml not applied).

**Prerequisite (soft)**: [PLAN-001-aks-step1-verification.md](../completed/PLAN-001-aks-step1-verification.md) — natural order is verify Step 1 first, then extend with this parity fix. Not a hard dependency: the change here is a no-op when `kubernetes-secrets.yml` doesn't exist (warns + continues), and nginx in PLAN-001's verification doesn't need secrets.

---

## Problem Summary

`platforms/azure-aks/scripts/02-post-apply.sh` does five things today: merge kubeconfig, switch context, apply storage class aliases, install Traefik, wait for external IP. It does *not* apply `kubernetes-secrets.yml` to the cluster.

The bash precedent (`hosts/azure-aks/02-azure-aks-setup.sh:125-141`) does apply it, between storage classes and Traefik install. Without that step, almost every UIS service fails at deploy time on the AKS cluster — they expect the `urbalurba-secrets` secret object to exist in their target namespace.

The fix is mechanical: insert a parallel block in the OpenTofu post-apply script. ~15 lines of code, plus a one-line `source` of `provision-host/uis/lib/paths.sh` so the `get_kubernetes_secrets_path` helper is in scope (same as the bash version).

---

## Phase 1: Code change

### Tasks

- [ ] 1.1 Edit `platforms/azure-aks/scripts/02-post-apply.sh`:
  - Near the top of the script (after `source "$CONFIG_FILE"` at ~line 48), add: `source "/mnt/urbalurbadisk/provision-host/uis/lib/paths.sh"` — guarded with `[[ -f ... ]]` so a missing paths.sh doesn't break the script. (Bash version at `02-azure-aks-setup.sh:54-56` uses the same guard.)
  - Insert a new section between the existing storage-class section (ends ~line 88) and the Traefik install section (starts ~line 91). The new section mirrors `02-azure-aks-setup.sh:125-141`:
    ```bash
    # ─── Step 3: Deploy secrets ────────────────────────────────────────────
    print_section "Step 3: Deploy secrets"

    if type get_kubernetes_secrets_path &>/dev/null; then
        SECRETS_FILE="$(get_kubernetes_secrets_path)/kubernetes-secrets.yml"
    else
        SECRETS_FILE="/mnt/urbalurbadisk/topsecret/kubernetes/kubernetes-secrets.yml"
    fi

    if [[ -f "$SECRETS_FILE" ]]; then
        print_status "Applying kubernetes secrets from $SECRETS_FILE..."
        kubectl apply -f "$SECRETS_FILE"
        print_success "Secrets deployed"
    else
        print_warning "Secrets file not found at: $SECRETS_FILE"
        print_warning "Run './uis secrets generate' before deploying services that require urbalurba-secrets"
    fi
    ```
  - Renumber the subsequent section headers so Traefik becomes "Step 4" and external IP becomes "Step 5" (currently labelled "Step 3" and "Step 4"). Keep the existing `print_section` style.

- [ ] 1.2 Static check: `shellcheck platforms/azure-aks/scripts/02-post-apply.sh` parses clean.

### Validation

`grep -n "kubernetes-secrets.yml" platforms/azure-aks/scripts/02-post-apply.sh` shows the new block. `shellcheck` returns no errors.

---

## Phase 2: Functional verification

The fix only matters on a real AKS cluster, so the validation has to run there. Two paths depending on whether PLAN-001 has shipped yet.

### Tasks

- [ ] 2.1 If PLAN-001 has already shipped (cluster is provisionable), tester runs:
  1. `./uis secrets generate` (so `kubernetes-secrets.yml` exists in `.uis.secrets/generated/kubernetes/` or the legacy `topsecret/` path).
  2. `00-bootstrap-state.sh` → `01-apply.sh` → `02-post-apply.sh` against a fresh AKS cluster.
  3. Confirm the new "Step 3: Deploy secrets" output prints the expected file path and `Secrets deployed`.
  4. `./uis deploy postgresql` (or any other secret-using service from the catalogue) succeeds — no `urbalurba-secrets not found` errors.
  5. `03-destroy.sh` — clean tear-down.

- [ ] 2.2 If PLAN-001 hasn't shipped yet, this plan can fold its functional verification into PLAN-001's Phase 2.7 (add `./uis deploy postgresql` after `./uis deploy nginx`). Coordinate with PLAN-001's status before scheduling.

### Validation

A secret-using UIS service (postgresql or equivalent) deploys cleanly on a fresh AKS cluster provisioned via `platforms/azure-aks/`, with no manual `kubectl apply -f kubernetes-secrets.yml` step.

---

## Phase 3: Status sync

### Tasks

- [ ] 3.1 Update `INVESTIGATE-system-platform-provisioning-layer.md` Step 1 — remove the "Currently *missing* from the tofu draft; the Step 1 PLAN must add it" caveat next to the `kubernetes-secrets.yml` line in Step 1 scope. Note in the gap-analysis findings list that this gap was closed by PLAN-002.

- [ ] 3.2 Move this PLAN file to `completed/`.

### Validation

Investigation no longer flags the secrets-apply gap as outstanding.

---

## Acceptance Criteria

- [ ] `platforms/azure-aks/scripts/02-post-apply.sh` applies `kubernetes-secrets.yml` between storage classes and Traefik install, mirroring `hosts/azure-aks/02-azure-aks-setup.sh:125-141`. Soft-fails when the file is absent.
- [ ] `shellcheck` passes on the modified script.
- [ ] A secret-using UIS service deploys on a fresh AKS cluster provisioned via `platforms/azure-aks/`.
- [ ] `INVESTIGATE-system-platform-provisioning-layer.md` no longer flags this gap as outstanding.
- [ ] This plan is in `completed/`.

---

## Files to Modify

- `platforms/azure-aks/scripts/02-post-apply.sh`
- `website/docs/ai-developer/plans/backlog/INVESTIGATE-system-platform-provisioning-layer.md` (Phase 3)
- `website/docs/ai-developer/plans/active/PLAN-platform-aks-002-secrets-apply-parity.md` → `completed/` (Phase 3)

---

## Implementation Notes

- **Order is loose vs PLAN-001.** The change here is a no-op for nginx and soft-fails when `kubernetes-secrets.yml` doesn't exist. So shipping this before, after, or during PLAN-001 are all fine. Natural order is *after* PLAN-001 verifies (we want a verified Step 1 first, then extend), but a tester running both end-to-end in one session can fold them.
- **Why this isn't part of Step 2.** Step 2 in the investigation is "operational tooling" (start/stop/scale, internet-access toggle). This parity fix isn't operational — it's the closing of one specific gap from the 2026-05-07 gap analysis, scoped narrowly so it can ship as its own small commit.
