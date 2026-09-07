# PLAN-009: Fix Tailscale Service for UIS

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed

**Goal**: Make `./uis deploy tailscale-tunnel` and `./uis undeploy tailscale-tunnel` work correctly end-to-end.

**Last Updated**: 2026-02-23

**Completed**: 2026-02-22 — Fully verified during PLAN-010 testing (4 rounds, see talk13.md)

**Priority**: Medium — required before tailscale can be verified (STATUS-service-migration Phase 5)

**Requires**: Tailscale account with auth key, OAuth client ID/secret

---

## Problem Analysis

The Tailscale service has multiple issues that prevent it from working with the UIS system:

### 1. Wrong deploy playbook in service script

`service-tailscale-tunnel.sh` points to `801-setup-network-tailscale-tunnel.yml`, but this playbook:
- Sets up the Tailscale daemon on **provision-host** (not the cluster)
- Runs a connectivity/funnel test
- Then **cleans everything up and disconnects** (steps 25-31)

The actual cluster deployment is in `802-deploy-network-tailscale-tunnel.yml`, which:
- Installs the Tailscale operator via Helm
- Creates a cluster ingress
- Tests connectivity

So `./uis deploy tailscale-tunnel` currently runs the wrong playbook.

### 2. Two-stage setup (resolved — not a problem)

The full Tailscale setup has two stages:
1. **Stage 1** (`801`): One-time manual setup — connect provision-host to Tailscale, verify keys work, then store the verified secrets in `.uis.secrets/`
2. **Stage 2** (`802`): Automated deploy — reads secrets from Kubernetes, deploys Tailscale operator to cluster

This is the correct pattern: stage 1 is a one-time manual prerequisite (like creating a Tailscale account), not part of the automated deploy. The service script should point to `802` as the deploy playbook.

### 3. No remove playbook

- A shell script exists (`804-tailscale-tunnel-delete.sh`) with comprehensive cleanup logic
- A partial Ansible playbook exists (`806-remove-tailscale-internal-ingress.yml`) for ingress-only removal
- Neither is referenced in the service script (`SCRIPT_REMOVE_PLAYBOOK=""`)
- Need a proper `801-remove-network-tailscale-tunnel.yml` Ansible playbook

### 4. User docs reference legacy shell scripts

The docs (`website/docs/networking/tailscale-setup.md`) reference:
- `./networking/tailscale/801-tailscale-tunnel-setup.sh`
- `./networking/tailscale/802-tailscale-tunnel-deploy.sh`
- `./networking/tailscale/803-tailscale-tunnel-deletehost.sh`
- `./networking/tailscale/804-tailscale-tunnel-delete.sh`

These should reference `./uis deploy tailscale-tunnel` and `./uis undeploy tailscale-tunnel` instead (for the parts that UIS handles).

### 5. User docs tell users to edit generated secrets file directly

The docs (Step 6) say:
```
Edit .uis.secrets/generated/kubernetes/kubernetes-secrets.yml with your values
```

This is the old way. In the new UIS system, users should:
1. Edit `.uis.secrets/config/00-common-values.env` with their Tailscale values
2. Run `./uis secrets generate` to regenerate the kubernetes secrets from the template
3. Secrets are applied automatically on deploy via `ensure_secrets_applied()`

The docs also tell users to manually run `kubectl apply -f ...` (Step 7) which is no longer needed.

---

## Current File Map

| File | Type | Purpose | Status |
|------|------|---------|--------|
| `provision-host/uis/services/network/service-tailscale-tunnel.sh` | Service script | UIS metadata | Points to wrong playbook, no remove playbook |
| `ansible/playbooks/801-setup-network-tailscale-tunnel.yml` | Ansible | Provision-host daemon setup + test + cleanup | Works but cleans up after itself |
| `ansible/playbooks/802-deploy-network-tailscale-tunnel.yml` | Ansible | Deploy operator to cluster | Untested since migration |
| `ansible/playbooks/802-tailscale-tunnel-addhost.yml` | Ansible | Add individual service ingress | Untested |
| `ansible/playbooks/805-deploy-tailscale-internal-ingress.yml` | Ansible | Internal-only ingress (no funnel) | Untested |
| `ansible/playbooks/806-remove-tailscale-internal-ingress.yml` | Ansible | Remove internal ingress | Works (partial removal) |
| `networking/tailscale/801-tailscale-tunnel-setup.sh` | Shell | Legacy: setup daemon | Replaced by 801 playbook |
| `networking/tailscale/802-tailscale-tunnel-deploy.sh` | Shell | Legacy: deploy operator + add services | Partially replaced by 802 playbook |
| `networking/tailscale/803-tailscale-tunnel-deletehost.sh` | Shell | Legacy: remove individual service | No playbook equivalent |
| `networking/tailscale/804-tailscale-tunnel-delete.sh` | Shell | Legacy: complete cleanup | No playbook equivalent |
| `website/docs/networking/tailscale-setup.md` | Docs | User guide | References legacy scripts |
| `website/docs/networking/tailscale-internal-ingress.md` | Docs | Internal access guide | May need updates |
| `website/docs/networking/tailscale-network-isolation.md` | Docs | Not implemented (TODO) | Placeholder only |

---

## Implementation Plan

### Phase 1: Fix the deploy path

The deploy playbook should be `802-deploy-network-tailscale-tunnel.yml`. The `801` playbook is a one-time manual tool for initial Tailscale account verification and secret discovery — not part of the automated deploy.

- [x] 1.1 Update `service-tailscale-tunnel.sh`: set `SCRIPT_PLAYBOOK="802-deploy-network-tailscale-tunnel.yml"` ✓
- [ ] 1.2 Run 801 manually via `./uis shell` to verify Tailscale connection and populate secrets (needs live account)
- [ ] 1.3 Test `./uis deploy tailscale-tunnel` with secrets in place (needs live account)
- [ ] 1.4 Verify the operator deploys and the cluster ingress is accessible (needs live account)

### Phase 2: Create remove playbook

- [x] 2.1 Create `ansible/playbooks/801-remove-network-tailscale-tunnel.yml` based on logic in `804-tailscale-tunnel-delete.sh` ✓
- [x] 2.2 Include: remove cluster ingress, uninstall Helm release, delete namespace, optionally remove tailnet devices via API ✓
- [x] 2.3 Update `service-tailscale-tunnel.sh` with `SCRIPT_REMOVE_PLAYBOOK` ✓
- [ ] 2.4 Test `./uis undeploy tailscale-tunnel` (needs live account)
- [ ] 2.5 Verify clean removal (no leftover pods, namespace gone) (needs live account)

### Phase 3: Test full cycle

- [ ] 3.1 Deploy → verify accessible → undeploy → verify clean
- [ ] 3.2 Redeploy to confirm idempotency

### Phase 4: Update user docs

- [x] 4.1 Update `tailscale-setup.md` to use `./uis deploy` / `./uis undeploy` where appropriate ✓
- [x] 4.2 Keep manual Tailscale account setup steps (Steps 1-5) as-is — those are external (Tailscale website) ✓
- [x] 4.3 Update Step 6: change from editing `generated/kubernetes/kubernetes-secrets.yml` directly to editing `.uis.secrets/config/00-common-values.env` + running `./uis secrets generate` ✓
- [x] 4.4 Remove Step 7 (`kubectl apply`): replaced with verification step using 801 playbook ✓
- [x] 4.5 Update Steps 8-10: replaced with `./uis deploy`, per-service scripts unchanged ✓
- [x] 4.6 Review `tailscale-internal-ingress.md`: updated `docker exec` commands to `./uis shell` ✓

---

## Research: Tailscale Wildcard DNS Status (2026-02-22)

Checked whether Tailscale now supports wildcard DNS, which would eliminate the need for per-service ingresses.

**Finding**: The per-service approach is still required for public internet access.

- **MagicDNS subdomain resolution** was implemented ([GitHub #1196](https://github.com/tailscale/tailscale/issues/1196), closed as completed). Subdomains like `service.machine.tailnet.ts.net` can now resolve within the tailnet.
- **Funnel (public internet) does NOT support wildcard domains**. [GitHub #15434](https://github.com/tailscale/tailscale/issues/15434) remains open — accessing `team123.device.tailnet.ts.net` from the public internet gives DNS errors.
- **MagicDNS still doesn't allow arbitrary DNS records** — the [DNS docs](https://tailscale.com/kb/1054/dns) explicitly state this.

**Impact on this plan**: The per-service ingress approach (`./networking/tailscale/802-tailscale-tunnel-deploy.sh whoami`) remains the correct pattern. Each service needs its own Tailscale ingress pod for public internet access via Funnel.

---

## Design Decision: Deploy Strategy

**Decision**: Use `802` as the deploy playbook. The `801` playbook remains a manual one-time tool.

**Rationale**: Stage 1 (801) is a one-time setup where you connect to Tailscale, verify your keys work, and store the verified secrets in `.uis.secrets/`. This is the same pattern as creating the Tailscale account itself — a manual prerequisite, not an automated step. Once secrets are in place, `802` can deploy fully automatically by reading them from Kubernetes.
