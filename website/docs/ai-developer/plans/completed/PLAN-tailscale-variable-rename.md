# PLAN: Rename Tailscale hostname variables for clarity

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed

**Goal**: Rename `TAILSCALE_CLUSTER_HOSTNAME` to `TAILSCALE_PUBLIC_HOSTNAME` and `TAILSCALE_INTERNAL_HOSTNAME` to `TAILSCALE_OPERATOR_PREFIX` to accurately describe what these UIS-invented variables actually control.

**Last Updated**: 2026-02-26

**Priority**: Low — cosmetic improvement, no functional change

**Origin**: [INVESTIGATE-tailscale-variable-rename.md](INVESTIGATE-tailscale-variable-rename.md)

---

## Problem Summary

Both Tailscale hostname variables have misleading names:

- `TAILSCALE_CLUSTER_HOSTNAME` — sounds like a cluster setting, but it's the **public Funnel device name** (e.g., `k8s` becomes `https://k8s.dog-pence.ts.net`)
- `TAILSCALE_INTERNAL_HOSTNAME` — sounds like an internal ingress hostname, but it's the **operator device name prefix** (e.g., `k8s-terje` becomes device `k8s-terje-tailscale-operator`)

The comments in the secrets template are also misleading, describing behaviors that don't match reality.

---

## Phase 1: Update secret templates (source of truth) — DONE

### Tasks

- [x] 1.1 In `provision-host/uis/templates/secrets-templates/00-common-values.env.template`: rename `TAILSCALE_CLUSTER_HOSTNAME` to `TAILSCALE_PUBLIC_HOSTNAME`, update comment ✓
- [x] 1.2 In `provision-host/uis/templates/secrets-templates/00-common-values.env.template`: rename `TAILSCALE_INTERNAL_HOSTNAME` to `TAILSCALE_OPERATOR_PREFIX`, update comment ✓
- [x] 1.3 In `provision-host/uis/templates/secrets-templates/00-master-secrets.yml.template`: rename both variables and their comments ✓

### Validation

User confirms template changes are correct.

---

## Phase 2: Update Ansible playbooks and Jinja2 manifests — DONE

### Tasks

- [x] 2.1 `ansible/playbooks/802-deploy-network-tailscale-tunnel.yml` — renamed both variables in comments, vars, facts, and template vars ✓
- [x] 2.2 `ansible/playbooks/801-remove-network-tailscale-tunnel.yml` — renamed `TAILSCALE_CLUSTER_HOSTNAME` in fact extraction ✓
- [x] 2.3 `ansible/playbooks/803-verify-tailscale.yml` — renamed `TAILSCALE_CLUSTER_HOSTNAME` in fact extraction and display ✓
- [x] 2.4 `ansible/playbooks/802-tailscale-tunnel-addhost.yml` — checked: no references to either variable, no changes needed ✓
- [x] 2.5 `ansible/playbooks/805-deploy-tailscale-internal-ingress.yml` — renamed `TAILSCALE_INTERNAL_HOSTNAME` in comments, facts, and template vars ✓
- [x] 2.6 `manifests/803-tailscale-cluster-ingress.yaml.j2` — renamed Jinja2 variable ✓
- [x] 2.7 `manifests/800-tailscale-operator-config.yaml.j2` — renamed Jinja2 variable and comments ✓
- [x] 2.8 `manifests/805-tailscale-internal-ingress.yaml.j2` — renamed Jinja2 variable ✓

### Validation

User confirms playbook and manifest changes are correct.

---

## Phase 3: Update legacy scripts and documentation — DONE

### Tasks

- [x] 3.1 `networking/tailscale/802-tailscale-tunnel-deploy.sh` — renamed `TAILSCALE_CLUSTER_HOSTNAME` ✓
- [x] 3.2 `networking/tailscale/804-tailscale-tunnel-delete.sh` — renamed `TAILSCALE_CLUSTER_HOSTNAME` ✓
- [x] 3.3 `provision-host/kubernetes/09-network/not-in-use/03-setup-tailscale-internal.sh` — renamed `TAILSCALE_INTERNAL_HOSTNAME` ✓
- [x] 3.4 `website/docs/networking/tailscale-setup.md` — renamed variables ✓
- [x] 3.5 `website/docs/networking/tailscale-internal-ingress.md` — renamed variables ✓
- [x] 3.6 `website/docs/reference/secrets-management.md` — renamed variables ✓

### Validation

User confirms documentation and legacy script changes are correct.

---

## Phase 4: Verify and grep for stragglers — DONE

### Tasks

- [x] 4.1 Grep for `TAILSCALE_CLUSTER_HOSTNAME` — zero results in code/playbooks/manifests/docs (only in plan/investigation files which document the rename) ✓
- [x] 4.2 Grep for `TAILSCALE_INTERNAL_HOSTNAME` — zero results in code/playbooks/manifests/docs (only in plan/investigation files) ✓
- [x] 4.3 Grep for lowercase `tailscale_cluster_hostname` and `tailscale_internal_hostname` — zero results ✓
- [ ] 4.4 Run `./uis test-all --only tailscale-tunnel` — deferred to user (requires running cluster with Tailscale credentials)

### Validation

User confirms all old references are gone. Integration test deferred to user.

---

## Bug Fix (found during testing)

- [x] Fixed `service-tailscale-tunnel.sh` SCRIPT_CHECK_COMMAND — was checking wrong namespace (`network` instead of `tailscale`) and wrong label (`app.kubernetes.io/name=tailscale` instead of `app=operator`). This caused `./uis list` to show tailscale-tunnel as "Not deployed" even after successful deployment.

---

## Acceptance Criteria

- [x] All references to `TAILSCALE_CLUSTER_HOSTNAME` replaced with `TAILSCALE_PUBLIC_HOSTNAME`
- [x] All references to `TAILSCALE_INTERNAL_HOSTNAME` replaced with `TAILSCALE_OPERATOR_PREFIX`
- [x] Comments in `00-common-values.env.template` clearly explain each variable's actual behavior
- [x] `./uis deploy tailscale-tunnel` succeeds with the new variable names (tested by tester)
- [x] No remaining references to the old variable names anywhere in the repo (verified by grep)
- [x] Documentation updated
- [ ] `CLOUDFLARE_DNS_TOKEN` — investigated for removal, but confirmed it IS used by `u01-add-domains-to-tunnel.yml`. Kept as-is.

---

## Files to Modify

### TAILSCALE_CLUSTER_HOSTNAME → TAILSCALE_PUBLIC_HOSTNAME

| File | Change |
|------|--------|
| `provision-host/uis/templates/secrets-templates/00-common-values.env.template` | Rename variable, improve comment |
| `provision-host/uis/templates/secrets-templates/00-master-secrets.yml.template` | Rename variable and comment |
| `ansible/playbooks/802-deploy-network-tailscale-tunnel.yml` | Rename in comments, vars, facts |
| `ansible/playbooks/801-remove-network-tailscale-tunnel.yml` | Rename in fact extraction |
| `ansible/playbooks/803-verify-tailscale.yml` | Rename in fact extraction |
| `ansible/playbooks/802-tailscale-tunnel-addhost.yml` | Check if still used, rename if active |
| `manifests/803-tailscale-cluster-ingress.yaml.j2` | Rename Jinja2 variable |
| `networking/tailscale/802-tailscale-tunnel-deploy.sh` | Rename variable (legacy script) |
| `networking/tailscale/804-tailscale-tunnel-delete.sh` | Rename variable (legacy script) |
| `website/docs/networking/tailscale-setup.md` | Rename in docs |

### TAILSCALE_INTERNAL_HOSTNAME → TAILSCALE_OPERATOR_PREFIX

| File | Change |
|------|--------|
| `provision-host/uis/templates/secrets-templates/00-common-values.env.template` | Rename variable, fix comment |
| `provision-host/uis/templates/secrets-templates/00-master-secrets.yml.template` | Rename variable |
| `ansible/playbooks/802-deploy-network-tailscale-tunnel.yml` | Rename in fact extraction and template vars |
| `ansible/playbooks/805-deploy-tailscale-internal-ingress.yml` | Rename in fact extraction and template vars |
| `manifests/800-tailscale-operator-config.yaml.j2` | Rename Jinja2 variable, update comments |
| `manifests/805-tailscale-internal-ingress.yaml.j2` | Rename Jinja2 variable |
| `provision-host/kubernetes/09-network/not-in-use/03-setup-tailscale-internal.sh` | Rename (legacy, not in use) |
| `website/docs/networking/tailscale-internal-ingress.md` | Rename in docs |
| `website/docs/reference/secrets-management.md` | Rename in docs |

---

## Implementation Notes

- This is a straight find-and-replace. No backwards compatibility needed — the system is not released.
- The `default-secrets.env` file (if it references these variables) must also be checked.
- If users have existing `.uis.secrets/` directories with the old variable names, those will need manual updating — but this is expected for a pre-release system.
