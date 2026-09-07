# PLAN-001: Tailscale variable cleanup and dead-file deletions

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed

**Goal**: Shrink the Tailscale secret variable set from 8 to 5 (4 cluster-side OAuth values + 1 renamed cloud-init / VM-bootstrap key) and delete the dead-code files (internal-mode, 801-setup, 804-delete, AUTH_KEY template) ahead of the network CLI port.

**Last Updated**: 2026-05-13

**Investigation**: [INVESTIGATE-tailscale-architecture-cleanup.md](INVESTIGATE-tailscale-architecture-cleanup.md) — Decisions 1, 2, 3, 4, 11, 12, 13, 15, 16.

**Blocks**: PLAN-002-tailscale-network-port-cli cannot start until this is done (new scripts assume the cleaned-up variable namespace).

**Priority**: High — foundation for the rest of the Tailscale architecture-cleanup initiative.

---

## Overview

The existing Tailscale codebase carries architectural debt that accumulated across PLAN-009 / PLAN-010 / PLAN-011 / PLAN-tailscale-variable-rename: 8 partially-overlapping secret variables (some unread), a Helm-release collision between 802 and 805, an orphaned 804 cleanup script, a 805/806 internal-mode path with no CLI verb and silently-broken removal, and an unused `tailscale.env.template` with a 6th variable name (`TAILSCALE_AUTH_KEY`) no code references.

This plan does the "kill what's dead" pass — pure deletions and a single variable rename. The legacy `uis tailscale expose/unexpose/verify` CLI keeps working after this plan ships. No user-facing change beyond `uis deploy tailscale-tunnel` continuing to work against the renamed `TAILSCALE_OWNER_ID` (was `TAILSCALE_OPERATOR_PREFIX`).

After this lands, PLAN-002 builds the new `uis network ... tailscale` CLI surface on the clean foundation.

---

## Phase 1: Rename `TAILSCALE_OPERATOR_PREFIX` → `TAILSCALE_OWNER_ID`

Investigation Decision 13. The new name describes what it means semantically (the cluster's owner on the shared tailnet) rather than its job in one specific Jinja2 template.

### Tasks

- [x] 1.1 `provision-host/uis/templates/secrets-templates/00-common-values.env.template` — rename variable + update the comment block to describe the new owner-id semantic (used for operator device, per-service device names, optional cluster Funnel device name)
- [x] 1.2 `provision-host/uis/templates/secrets-templates/00-master-secrets.yml.template` — rename variable + comment
- [x] 1.3 `ansible/playbooks/802-deploy-network-tailscale-tunnel.yml` — rename in fact extraction + template vars (also lowercase Ansible var `tailscale_operator_prefix` → `tailscale_owner_id`)
- [x] 1.4 `ansible/playbooks/803-verify-tailscale.yml` — confirmed no reference (file gates on CLIENTID/CLIENTSECRET/TAILNET, not OPERATOR_PREFIX)
- [x] 1.5 `manifests/800-tailscale-operator-config.yaml.j2` — rename Jinja2 variable + update example comment block
- [x] 1.6 `networking/tailscale/802-tailscale-tunnel-deploy.sh` — confirmed no reference (the shell wrapper just invokes the playbook)
- [x] 1.7 `website/docs/networking/tailscale-setup.md` + `tailscale-network-isolation.md` — confirmed no reference (will be rewritten in PLAN-003)
- [x] 1.8 `provision-host/uis/lib/integration-testing.sh` — confirmed no reference (Tailscale gate uses CLIENTID/CLIENTSECRET/DOMAIN, not OPERATOR_PREFIX/OWNER_ID)

### Validation

```bash
# Confirm no remaining OPERATOR_PREFIX references in non-historical files
grep -rn 'TAILSCALE_OPERATOR_PREFIX' --exclude-dir=plans/completed --exclude-dir=plans/backlog .
# Expected: empty (or only matches in INVESTIGATE-tailscale-architecture-cleanup.md description text, which is fine)

# Confirm legacy uis deploy tailscale-tunnel still parses + dry-runs (no real cluster touch)
./uis deploy tailscale-tunnel --dry-run
```

User confirms phase is complete.

---

## Phase 2: Variable cleanup — rename + delete

Investigation Decisions 2, 3, 11, 12, 16. After this phase, the variable set is down to 5: `CLIENTID`, `CLIENTSECRET`, `TAILNET`, `OWNER_ID` (cluster path) + `VM_AUTH_KEY` (cloud-init / VM-bootstrap path, out of cluster scope).

**Phase 2 audit surfaced a gap in Decision 2 as originally written**: `TAILSCALE_SECRET` is not unused — `cloud-init/create-cloud-init.sh:85` reads it for VM bootstrap (`URB_TAILSCALE_SECRET_VARIABLE` substitution), called by `hosts/multipass-microk8s/01-create-multipass-microk8s.sh:75`. Decision 2 updated to **rename** rather than delete: `TAILSCALE_SECRET` → `TAILSCALE_VM_AUTH_KEY` to disambiguate from `TAILSCALE_CLIENTSECRET` and mark scope explicitly. The cluster-side dead reads (placeholder checks in `802-deploy.sh` and `803-verify.yml`) still go away — they verify a static auth key that the cluster operator path never uses.

### Tasks

- [x] 2.1 Rename `TAILSCALE_SECRET` → `TAILSCALE_VM_AUTH_KEY` in `00-common-values.env.template` + `00-master-secrets.yml.template` (Decision 2). Comment block rewritten to mark the scope explicitly (cloud-init / VM bootstrap only).
- [x] 2.2 Rename in alive readers: `cloud-init/create-cloud-init.sh:85`, `provision-host/uis/lib/secrets-management.sh:161`, `website/docs/networking/tailscale-setup.md` (3 refs), `website/docs/contributors/architecture/secrets.md` (rewrote the inconsistency note to describe the two auth flows). The internal `URB_TAILSCALE_SECRET_VARIABLE` placeholder name in cloud-init templates stays unchanged (out of scope; future cloud-init rewrite).
- [x] 2.3 Dropped dead cluster-side reads of the old `TAILSCALE_SECRET`:
  - `networking/tailscale/802-tailscale-tunnel-deploy.sh` — removed the read + placeholder check (cluster path uses OAuth)
  - `ansible/playbooks/803-verify-tailscale.yml` — removed `ts_secret` fact extraction + the `tskey-auth-ktyTufs` check from the placeholder validator. The static auth-key check was part of check 1 (Secrets validation), not its own check — total check count stays at 4 (Secrets / API Connectivity / Stale Devices / Operator).
  - `801-setup-network-tailscale-tunnel.yml:36` left alone — Phase 3 deletes the whole file
- [x] 2.4 Deleted `TAILSCALE_DOMAIN` from both templates (Decision 11). Rewired reads to `TAILSCALE_TAILNET` in 802-deploy.yml, 803-verify.yml, 802-tailscale-tunnel-deploy.sh, integration-testing.sh gate. Also renamed internal var `tailscale_domain` → `tailscale_tailnet` in 802-deploy.yml and `ts_domain` → `ts_tailnet` in 803-verify.yml for semantic clarity.
- [x] 2.5 Deleted `TAILSCALE_PUBLIC_HOSTNAME` from both templates (Decision 12). Rewired reads to `TAILSCALE_OWNER_ID` in 801-remove.yml, 802-deploy.yml, 803-verify.yml, 803-tailscale-cluster-ingress.yaml.j2, 802-tailscale-tunnel-deploy.sh + tailscale-setup.md. The duplicate `tailscale_public_hostname` set_fact in 802-deploy.yml was consolidated into the existing `tailscale_owner_id` fact (same source after Decision 12).
- [x] 2.6 Deleted `provision-host/uis/templates/uis.secrets/service-keys/tailscale.env.template` (Decision 3 — defined unused `TAILSCALE_AUTH_KEY`). New variable name `TAILSCALE_VM_AUTH_KEY` is scope-explicit per Decision 2.
- [x] 2.7 Deleted `BASE_DOMAIN_TAILSCALE` from `00-common-values.env.template:21`. Audit confirmed zero active readers; pure delete (not in master template).

### Validation

```bash
# Confirm the rename is complete + the deletes landed cleanly
echo "=== Old name should be gone except in historical plans ==="
grep -rn 'TAILSCALE_SECRET\b' --exclude-dir=plans/completed --exclude-dir=plans/backlog --exclude-dir=node_modules --exclude-dir=.git .
# Expected: empty (or only PLAN-001 task descriptions referencing the rename history)

echo "=== Deleted variables should have zero remaining readers ==="
for v in TAILSCALE_DOMAIN TAILSCALE_PUBLIC_HOSTNAME TAILSCALE_AUTH_KEY BASE_DOMAIN_TAILSCALE; do
  echo "--- $v ---"
  grep -rn "$v" --exclude-dir=plans/completed --exclude-dir=plans/backlog --exclude-dir=node_modules --exclude-dir=.git .
done
# Expected: empty for all four (or only PLAN-001 task descriptions)

echo "=== New name should appear in templates + cloud-init path ==="
grep -rn 'TAILSCALE_VM_AUTH_KEY' --exclude-dir=plans --exclude-dir=node_modules --exclude-dir=.git .
# Expected: ~6 hits (2 templates, secrets-management.sh, create-cloud-init.sh, ubuntu-cloud-init README, tailscale-setup.md)
```

User confirms phase is complete.

---

## Phase 3: Delete dead-code files

Investigation Decisions 1, 4, 15.

### Tasks

- [x] 3.1 Delete `ansible/playbooks/801-setup-network-tailscale-tunnel.yml` (Decision 1 — host-side smoke-test scaffolding, obsolete)
- [x] 3.2 Delete `networking/tailscale/801-tailscale-tunnel-setup.sh` (Decision 1 — wrapper for the above)
- [x] 3.3 Delete `networking/tailscale/804-tailscale-tunnel-delete.sh` (Decision 4 — orphaned, 253 lines, no caller, superseded by `801-remove-network-tailscale-tunnel.yml`)
- [x] 3.4 Delete `ansible/playbooks/805-deploy-tailscale-internal-ingress.yml` (Decision 15 — internal-mode dead)
- [x] 3.5 Delete `ansible/playbooks/806-remove-tailscale-internal-ingress.yml` (Decision 15 — was silently broken anyway)
- [x] 3.6 Delete `manifests/805-tailscale-internal-ingress.yaml.j2` (Decision 15)
- [x] 3.7 Delete `website/docs/networking/tailscale-internal-ingress.md` (Decision 15)
- [x] 3.8 Update `801-remove-network-tailscale-tunnel.yml` — dropped the "Based on logic from 804" comment + the `provision-host` device-name match in the tailnet device-deletion regex (was the host-side residue from when 801-setup created a `provision-host` device)
- [ ] 3.9 Update `INVESTIGATE-network-tailscale-cross-cluster-backbone.md`: replace "Deleted in the cleanup — recoverable from git history" placeholder with the actual commit hash from this plan's PR after merge — deferred to post-merge follow-up

**Also cleaned up stale cross-references (not in original task list but surfaced by the deletion):**
- `networking/tailscale/802-tailscale-tunnel-deploy.sh` — dropped two references to `801-tailscale-tunnel-setup.sh` (header comment + the secrets-missing error message)
- `provision-host/uis/templates/secrets-templates/00-master-secrets.yml.template` — rewrote the OAuth client comment block (was referring to deleted scripts; now describes the OAuth scopes properly)
- `website/docs/networking/index.md` — removed the bullet linking to the deleted internal-ingress page
- `website/docs/reference/documentation-index.md` — removed the Tailscale Internal Ingress row
- `website/docs/contributors/architecture/manifests.md` — removed the `805-tailscale-internal-ingress.yaml.j2` row from the 800-899 networking manifests table

### Validation

```bash
# Confirm all listed files are gone
for f in \
  ansible/playbooks/801-setup-network-tailscale-tunnel.yml \
  ansible/playbooks/805-deploy-tailscale-internal-ingress.yml \
  ansible/playbooks/806-remove-tailscale-internal-ingress.yml \
  manifests/805-tailscale-internal-ingress.yaml.j2 \
  networking/tailscale/801-tailscale-tunnel-setup.sh \
  networking/tailscale/804-tailscale-tunnel-delete.sh \
  provision-host/uis/templates/uis.secrets/service-keys/tailscale.env.template \
  website/docs/networking/tailscale-internal-ingress.md; do
  [ ! -e "$f" ] && echo "✓ deleted: $f" || echo "✗ STILL PRESENT: $f"
done

# Confirm legacy uis deploy tailscale-tunnel + uis tailscale expose still work
./uis deploy tailscale-tunnel --dry-run
./uis tailscale expose --help 2>&1 | head -5
```

User confirms phase is complete.

---

## Phase 4: Local verification

### Tasks

- [x] 4.1 `bash -n` syntax check on modified shell scripts — all pass (802-tunnel-deploy.sh, create-cloud-init.sh, secrets-management.sh, integration-testing.sh)
- [x] 4.2 services.json parses cleanly
- [x] 4.3 `cd website && npm run build` — `[SUCCESS]` after removing the `networking/tailscale-internal-ingress` entry from `sidebars.ts` (sidebar still referenced the doc page deleted in Phase 3). Only broken anchors flagged are pre-existing in unrelated files (INVESTIGATE-service-dagster, completed/PLAN-001-postgrest-documentation).
- [ ] 4.4 `./uis build` — tester step per contributor/tester split (contributor never tests deploys)
- [ ] 4.5 Smoke test legacy CLI surface (`./uis tailscale --help`, `./uis deploy tailscale-tunnel --dry-run`) — tester step

### Validation

```bash
cd website && npm run build 2>&1 | tail -3
# Expected: [SUCCESS] Generated static files in "build".

bash -n provision-host/uis/manage/uis-cli.sh && echo "uis-cli.sh OK"
# Expected: uis-cli.sh OK
```

User confirms phase is complete.

---

## Acceptance Criteria

- [ ] Variable set is down from 8 to 5: `CLIENTID`, `CLIENTSECRET`, `TAILNET`, `OWNER_ID` (cluster path) + `VM_AUTH_KEY` (cloud-init / VM-bootstrap, renamed from `TAILSCALE_SECRET`)
- [ ] Dead files deleted: 801-setup playbook, 801-setup shell wrapper, 804-delete shell, 805/806 playbooks, 805 j2 manifest, AUTH_KEY service-keys template, internal-ingress doc page
- [ ] `TAILSCALE_OPERATOR_PREFIX` references gone from non-historical files
- [ ] `BASE_DOMAIN_TAILSCALE` references gone (rewired to `TAILSCALE_TAILNET` where needed, deleted otherwise)
- [ ] Legacy `./uis deploy tailscale-tunnel` + `./uis tailscale expose/unexpose/verify` still work — this plan does **not** touch the CLI surface
- [ ] Local `npm run build` succeeds
- [ ] `INVESTIGATE-network-tailscale-cross-cluster-backbone.md` updated with the merge commit hash for the deleted internal-mode files

---

## Files to Modify

**Edit (variable rename + reads):**
- `provision-host/uis/templates/secrets-templates/00-common-values.env.template`
- `provision-host/uis/templates/secrets-templates/00-master-secrets.yml.template`
- `ansible/playbooks/802-deploy-network-tailscale-tunnel.yml`
- `ansible/playbooks/803-verify-tailscale.yml`
- `ansible/playbooks/801-remove-network-tailscale-tunnel.yml`
- `manifests/800-tailscale-operator-config.yaml.j2`
- `manifests/803-tailscale-cluster-ingress.yaml.j2`
- `networking/tailscale/802-tailscale-tunnel-deploy.sh`
- `networking/tailscale/803-tailscale-tunnel-deletehost.sh`
- `website/docs/networking/tailscale-setup.md`
- `website/docs/networking/tailscale-network-isolation.md`
- `website/docs/ai-developer/plans/backlog/INVESTIGATE-network-tailscale-cross-cluster-backbone.md` (commit hash update)

**Delete:**
- `ansible/playbooks/801-setup-network-tailscale-tunnel.yml`
- `ansible/playbooks/805-deploy-tailscale-internal-ingress.yml`
- `ansible/playbooks/806-remove-tailscale-internal-ingress.yml`
- `manifests/805-tailscale-internal-ingress.yaml.j2`
- `networking/tailscale/801-tailscale-tunnel-setup.sh`
- `networking/tailscale/804-tailscale-tunnel-delete.sh`
- `provision-host/uis/templates/uis.secrets/service-keys/tailscale.env.template`
- `website/docs/networking/tailscale-internal-ingress.md`

---

## Implementation Notes

- **Order matters within Phase 2.** If `TAILSCALE_DOMAIN` reads are replaced with `TAILSCALE_TAILNET` *before* the variable is removed from the templates, the deploy paths keep working; reversing the order leaves a window where deploys fail.
- **`BASE_DOMAIN_TAILSCALE` audit may surface surprises.** It's a cross-cutting variable possibly used in Traefik IngressRoute YAMLs (not just Tailscale playbooks). Be prepared to find readers in unexpected places. If a reader is for a Cloudflare IngressRoute (matching `*.<owned-domain>`), leave it alone — the cleanup target is the Tailscale-side reads only.
- **`INVESTIGATE-network-tailscale-cross-cluster-backbone.md` commit-hash update** can be done as a follow-up PR if the original PR merges without it; the cross-cluster doc is in backlog and not blocking.
- This plan is **low risk** — pure deletions + a rename. No new code. Legacy CLI unchanged. Should be ~2 hours of mechanical work.
