# INVESTIGATE: Rename Tailscale hostname variables and fix misleading comments

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed

**Goal**: Rename UIS-invented Tailscale hostname variables for clarity, and fix misleading comments in the secrets template.

**Last Updated**: 2026-02-26

**Priority**: Low — cosmetic improvement, no functional change

---

## Context

`TAILSCALE_CLUSTER_HOSTNAME` is a UIS-invented variable (not from Tailscale). It sets the `tailscale.com/hostname` annotation on the Kubernetes Ingress resource, which determines the Tailscale device name and the public Funnel URL.

Example: `TAILSCALE_CLUSTER_HOSTNAME=k8s` results in `https://k8s.dog-pence.ts.net`

The name "cluster hostname" is misleading — it's really the **public Funnel hostname**.

`TAILSCALE_INTERNAL_HOSTNAME` is also misleading. The comment says "Internal-only Tailscale ingress hostname (for developer access via Tailnet, no Funnel)" but in practice it's just an **operator device name prefix**. The value `k8s-terje` produces a device called `k8s-terje-tailscale-operator` in the Tailscale admin — the `-tailscale-operator` suffix is appended automatically in `800-tailscale-operator-config.yaml.j2`. There is no `k8s-terje` ingress device unless the internal ingress (`805-deploy-tailscale-internal-ingress.yml`) is also deployed separately.

### Variable comparison

| Current Name | Proposed Name | Actual Behavior | Device in Tailscale Admin |
|---|---|---|---|
| `TAILSCALE_CLUSTER_HOSTNAME` | `TAILSCALE_PUBLIC_HOSTNAME` | Public Funnel ingress device name | `k8s.dog-pence.ts.net` |
| `TAILSCALE_INTERNAL_HOSTNAME` | `TAILSCALE_OPERATOR_PREFIX` | Operator device name prefix (also used by 805 internal ingress if deployed) | `k8s-terje-tailscale-operator.dog-pence.ts.net` |

---

## Files to Change

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

## Implementation

Straight find-and-replace across all files. No backwards compatibility needed — system is not released.

Improved comments in the template:
```bash
# Public Funnel hostname — the device name for public internet access
# Becomes: https://<value>.<TAILSCALE_DOMAIN> (e.g., https://k8s.dog-pence.ts.net)
# This is the entry point exposed via Tailscale Funnel
TAILSCALE_PUBLIC_HOSTNAME=k8s

# Operator device name prefix — identifies this cluster in Tailscale admin
# Produces device: <value>-tailscale-operator (e.g., k8s-terje-tailscale-operator)
# Use a unique name per cluster (e.g., k8s-terje, k8s-imac, k8s-tecmacdev)
# Also used as device name for internal tailnet-only ingress (805) if deployed separately
TAILSCALE_OPERATOR_PREFIX=k8s-terje
```

---

## Outcome

Investigation complete. Created [PLAN-tailscale-variable-rename.md](../completed/PLAN-tailscale-variable-rename.md) which was implemented and verified by tester.

## Acceptance Criteria

- [x] All references to `TAILSCALE_CLUSTER_HOSTNAME` replaced with `TAILSCALE_PUBLIC_HOSTNAME`
- [x] All references to `TAILSCALE_INTERNAL_HOSTNAME` replaced with `TAILSCALE_OPERATOR_PREFIX`
- [x] Comments in `00-common-values.env.template` clearly explain each Tailscale variable
- [x] `./uis deploy tailscale-tunnel` succeeds with new variable names (tested)
- [x] Documentation updated
