# Plan: derive `TAILSCALE_OWNER_ID` default from `GITHUB_USERNAME` + soft-warn validation guards

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed (2026-05-16)

PR #193 — talk57 R1-R7 + R8 retry all PASS. PLAN and its companion `INVESTIGATE-network-tailscale-owner-id-default.md` move to `completed/` together.

**Implementation note — envsubst gotcha (caught in tester R1/R2, fixed in commit `914816d`):** the original Phase 1.2 design used envsubst's `${VAR:-default}` syntax in the master template. GNU envsubst does *not* evaluate that form — it only does plain `${VAR}` substitution — so the outer fallback was preserved as literal shell text in the rendered Secret. The shipped implementation pre-computes the derivation in shell inside `generate_kubernetes_secrets()` (`provision-host/uis/lib/first-run.sh`) before envsubst runs; the master template went back to plain `${TAILSCALE_OWNER_ID}`. Lesson for next time: keep `${VAR:-default}` defaults out of envsubst templates.

**Goal**: Close the contributor-bypass gap left after PLAN-002 — a fresh install that skips the wizard and runs `./uis secrets generate` directly should still produce a non-colliding `TAILSCALE_OWNER_ID`. Soft-warn (matching the existing `DEFAULT_*` placeholder pattern) when the resolved value is missing or malformed.

**Last Updated**: 2026-05-16

**Investigation**: [INVESTIGATE-network-tailscale-owner-id-default.md](./INVESTIGATE-network-tailscale-owner-id-default.md) — Decision: soft-warn (2026-05-16). Hard-fail in `./uis deploy tailscale-tunnel` deferred until soft-warn proves insufficient.

**Depends on**: nothing. Two template edits + two `if` blocks in `validate_secrets`. No wizard, no docs, no deploy-path change.

---

## Problem Summary

After PLAN-002 shipped the `./uis network init tailscale` wizard, the wizard-driven path is safe. But two paths still produce the broken `TAILSCALE_OWNER_ID=k8s`:

1. **Fresh-clone contributor who skips the wizard.** Runs `./uis secrets generate` directly. The template default at `00-common-values.env.template:85` is still `k8s`. On second-cluster deploy: device-name collision, Tailscale appends `-1`, `./uis tailscale verify` flags the `-1` device as stale (it isn't).

2. **Existing user with `TAILSCALE_OWNER_ID=k8s` in their local `secrets-config/`.** Wizard never touched their value; soft-warn on `./uis secrets validate` is the only path that flags it.

Per the investigation's decision summary (2026-05-16): the cost of bad state (one collided device with a `-1` suffix) is mild; soft-warn matches existing `DEFAULT_*` weak-password handling; the heavier hard-fail in deploy is deferred until soft-warn fails to bite.

---

## Phase 1: Template default — derive from `GITHUB_USERNAME`

### Tasks

- [x] 1.1 Edit `provision-host/uis/templates/secrets-templates/00-common-values.env.template`:
  - Line 85: changed `TAILSCALE_OWNER_ID=k8s` → `TAILSCALE_OWNER_ID=` (empty). Comment block updated to point at `GITHUB_USERNAME` as the derivation source.

- [x] 1.2 Pre-compute derivation in shell (revised from the original "use envsubst `${VAR:-default}`" approach after R1/R2 revealed envsubst doesn't evaluate that form). In `provision-host/uis/lib/first-run.sh::generate_kubernetes_secrets()`, between `source` of common-values and the envsubst call, insert:

  ```bash
  if [[ -z "${TAILSCALE_OWNER_ID:-}" ]]; then
      local _gh_lc
      _gh_lc="$(printf '%s' "${GITHUB_USERNAME:-}" | tr '[:upper:]' '[:lower:]')"
      export TAILSCALE_OWNER_ID="k8s-${_gh_lc}"
  fi
  ```

  Master template stays as plain `TAILSCALE_OWNER_ID: "${TAILSCALE_OWNER_ID}"`.

### Behaviour after this phase

| `TAILSCALE_OWNER_ID` in user's env | `GITHUB_USERNAME` in user's env | Resolved value |
|---|---|---|
| unset / empty | `terchris` | `k8s-terchris` |
| `k8s-terchris-mbp` (explicit) | any | `k8s-terchris-mbp` |
| unset | `your-github-username` (placeholder) | `k8s-your-github-username` ← caught by Phase 2 |
| unset | unset / empty | `k8s-` ← caught by Phase 2 |
| `k8s` (existing user, unchanged) | any | `k8s` ← caught by Phase 2 |

### Notes

- The change to `00-common-values.env.template:85` affects **fresh installs only**. Existing users' `.uis.secrets/secrets-config/00-common-values.env.template` is preserved by `first-run.sh::copy_secrets_templates` (it doesn't overwrite an existing copy).
- The master-template change applies to **everyone** at `./uis secrets generate` time. An existing user whose local common-values has `TAILSCALE_OWNER_ID=k8s` still gets `k8s` resolved (the explicit value wins over the fallback). Phase 2's soft-warn is what flags this case.

---

## Phase 2: Two soft-warn validation guards in `validate_secrets`

### Tasks

- [x] 2.1 In `provision-host/uis/lib/secrets-management.sh::validate_secrets` (line 249), added the Tailscale-section block after the weak-password loop (~line 302):

  ```bash
  # ─── Tailscale OWNER_ID derivation guards ────────────────────────
  # Soft-warn (log_warn, not has_issues=true) — matches the existing
  # DEFAULT_* weak-password pattern at line ~300. Hard-fail deferred
  # to deploy path per INVESTIGATE-network-tailscale-owner-id-default
  # decision (2026-05-16).

  # Guard A: GITHUB_USERNAME is not the literal placeholder.
  if [[ "${GITHUB_USERNAME:-}" == "your-github-username" ]]; then
      log_warn "GITHUB_USERNAME is still the template placeholder."
      log_warn "  TAILSCALE_OWNER_ID derives from this — set it in 00-common-values.env.template."
  fi

  # Guard B: resolved OWNER_ID is a legal hostname segment.
  # Mirror the same fallback the master template uses so the value we
  # check here matches what envsubst will emit at generate time.
  local _gh_lc="$(printf '%s' "${GITHUB_USERNAME:-}" | tr '[:upper:]' '[:lower:]')"
  local _resolved_owner_id="${TAILSCALE_OWNER_ID:-k8s-${_gh_lc}}"
  if [[ ! "$_resolved_owner_id" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
      log_warn "TAILSCALE_OWNER_ID resolves to '$_resolved_owner_id'"
      log_warn "  Not a legal Tailscale device-name segment (must be 1-63 chars of [a-z0-9-],"
      log_warn "  no leading/trailing hyphen). Tailscale will reject this or auto-suffix on collision."
  fi

  # Guard C (bundled with B for cheapness): existing-user collision flag.
  # The literal value 'k8s' is the broken legacy default. Flag it specifically
  # so the user understands why it's being called out (vs. a generic shape check).
  if [[ "${TAILSCALE_OWNER_ID:-}" == "k8s" ]]; then
      log_warn "TAILSCALE_OWNER_ID is still the legacy default 'k8s'"
      log_warn "  Two clusters with this default will collide on the same tailnet."
      log_warn "  Recommended: leave it blank to auto-derive from GITHUB_USERNAME,"
      log_warn "  or set it explicitly (e.g. k8s-terje-mbp)."
  fi
  ```

- [x] 2.2 Verify the three guard cases interactively in the dev container against a freshly-init'd `.uis.secrets/`:
  - Set `GITHUB_USERNAME=your-github-username` → Guard A fires.
  - Set `GITHUB_USERNAME=Has-CAPS` (uppercase) → Guard B fires (after lowercasing, the regex still passes for `has-caps`, so this *shouldn't* fire — verify behaviour matches expectation).
  - Set `GITHUB_USERNAME=` empty, `TAILSCALE_OWNER_ID=` empty → resolves to `k8s-` (trailing hyphen) → Guard B fires.
  - Set `TAILSCALE_OWNER_ID=k8s` → Guard C fires.
  - All three guards use `log_warn`, none increment `has_issues`. `validate_secrets` returns 0 in all four cases.

### Validation

- `./uis secrets validate` prints WARN lines for each broken case; the command still exits 0.
- `./uis secrets validate` against a wizard-initialised tailnet (`TAILSCALE_OWNER_ID=k8s-terchris-mbp`, `GITHUB_USERNAME=terchris`) prints no Tailscale warnings.

---

## Phase 3: Smoke-test the rendered master secret

### Tasks

- [x] 3.1 In the dev container, run `./uis secrets generate` for the four scenarios above and grep the rendered `generated/kubernetes/kubernetes-secrets.yml` for `TAILSCALE_OWNER_ID:`:
  - Fresh + `GITHUB_USERNAME=terchris`, OWNER_ID blank → `TAILSCALE_OWNER_ID: "k8s-terchris"`
  - Explicit `TAILSCALE_OWNER_ID=k8s-terchris-mbp` → `TAILSCALE_OWNER_ID: "k8s-terchris-mbp"` (explicit wins)
  - Both blank → `TAILSCALE_OWNER_ID: "k8s-"` (visible to operator, then the deploy path produces a collidable device — caught by future hard-fail PLAN, not this one)
  - `TAILSCALE_OWNER_ID=k8s` (legacy) → `TAILSCALE_OWNER_ID: "k8s"` (explicit wins, unchanged)

- [x] 3.2 Confirm no other consumer of `TAILSCALE_OWNER_ID` breaks on the new shape:
  - `grep -rn "TAILSCALE_OWNER_ID" provision-host/ ansible/ manifests/` — reviewed. Playbooks 800/802 have `default_owner_id: "k8s"` ansible-level fallback; manifests just consume the value. No name change, no collateral.

---

## Files to Modify

- `provision-host/uis/templates/secrets-templates/00-common-values.env.template` (Phase 1.1)
- `provision-host/uis/templates/secrets-templates/00-master-secrets.yml.template` (Phase 1.2)
- `provision-host/uis/lib/secrets-management.sh` (Phase 2.1)

## Out of Scope

- **Hard-fail in `./uis deploy tailscale-tunnel`.** Deferred per investigation decision; revisit if soft-warn fails to bite within ~5 deploys.
- **Wizard changes.** The wizard already prompts + validates (PLAN-002, shipped). No re-work there.
- **Auto-migration for existing users with `TAILSCALE_OWNER_ID=k8s`.** Guard C calls it out; user makes the call. No silent rewrite of the user's env file.
- **Docs.** No doc changes needed — the comment block in `00-common-values.env.template` is the contract; PLAN-003 already covers the Tailscale setup narrative.

## Acceptance Criteria

- [x] Fresh `./uis secrets init` + `./uis secrets generate` (no wizard) produces a `TAILSCALE_OWNER_ID` of `k8s-<lowercased-github-username>` when `GITHUB_USERNAME` is set. — R8.1 confirmed `k8s-terchris` rendered.
- [x] `./uis secrets validate` against a placeholder `GITHUB_USERNAME=your-github-username` prints Guard A's warning + exits 0. — R3 PASS.
- [x] `./uis secrets validate` against `TAILSCALE_OWNER_ID=k8s` prints Guard C's warning + exits 0. — R5 + R8.3 PASS.
- [x] `./uis secrets validate` against a clean wizard-initialised config prints no Tailscale warnings. — R6 PASS.
- [x] `grep TAILSCALE_OWNER_ID` across `provision-host/`, `ansible/`, `manifests/` shows no name-change collateral. — Phase 3.2 confirmed.
