# INVESTIGATE: Network Services Remove Playbooks

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed

**Goal**: Investigate the full state of tailscale-tunnel and cloudflare-tunnel services — verify deploy works, create remove playbooks, and test the full deploy/undeploy cycle.

**Last Updated**: 2026-02-26

**Priority**: Low — Both Tailscale and Cloudflare are now fully complete.

**Parent**: [STATUS-service-migration.md](STATUS-service-migration.md) — Phase 3 and Phase 5

---

## Context

All 26 UIS services have deploy playbooks. 24 of 26 have been verified working. Tailscale is now fully complete. Only Cloudflare remains:

| Service | Deploy Playbook | Remove Playbook | External Requirement | Status |
|---------|----------------|-----------------|---------------------|--------|
| **tailscale-tunnel** | ✅ `802-deploy-network-tailscale-tunnel.yml` | ✅ `801-remove-network-tailscale-tunnel.yml` | Tailscale auth key | **COMPLETE** (PLAN-009/010/011) |
| **cloudflare-tunnel** | ✅ `820-deploy-network-cloudflare-tunnel.yml` | ✅ `821-remove-network-cloudflare-tunnel.yml` | Cloudflare tunnel token | **COMPLETE** (PLAN-cloudflare-tunnel-undeploy, PR #43) |

Cloudflare cannot be tested without a live external account (API token and configured tunnel in Cloudflare dashboard).

## Prerequisites

Before starting this work:

1. **Tailscale account** with an auth key configured in `.uis.secrets/`
2. **Cloudflare account** with a tunnel token configured in `.uis.secrets/`
3. A running Kubernetes cluster (Rancher Desktop or Azure AKS)

## Investigation Questions

### Tailscale — COMPLETE

All Tailscale work completed in PLAN-009/010/011:
- [x] `./uis deploy tailscale-tunnel` works (deploys operator via Helm)
- [x] `./uis undeploy tailscale-tunnel` works (removes operator, cleans up Tailnet devices via API)
- [x] `./uis tailscale expose <service>` exposes services via Funnel
- [x] `./uis tailscale unexpose <service>` removes services with device cleanup
- [x] `./uis tailscale verify` checks secrets, API, stale devices, operator

### Cloudflare — COMPLETE

All Cloudflare work completed in PLAN-cloudflare-tunnel-undeploy (PR #43):
- [x] `./uis deploy cloudflare-tunnel` works (token-based, E2E connectivity verified)
- [x] `./uis undeploy cloudflare-tunnel` works (removes deployment, waits for pod termination)
- [x] `./uis cloudflare verify` checks secrets, network, and pod status
- [x] Reduced replicas from 2 to 1 (sufficient for local dev)
- [x] Cleaned up confusing deploy output (removed redundant skip messages)

## Expected Deliverables

1. ~~Verify or fix `./uis deploy tailscale-tunnel`~~ ✅ Done (PLAN-009)
2. ~~Verify or fix `./uis deploy cloudflare-tunnel`~~ ✅ Done (PLAN-012, PLAN-cloudflare-tunnel-undeploy)
3. ~~Create `ansible/playbooks/801-remove-network-tailscale-tunnel.yml`~~ ✅ Done (PLAN-009)
4. ~~Create `ansible/playbooks/821-remove-network-cloudflare-tunnel.yml`~~ ✅ Done (PR #43)
5. ~~Update `service-tailscale-tunnel.sh`: set `SCRIPT_REMOVE_PLAYBOOK`~~ ✅ Done (PLAN-009)
6. ~~`service-cloudflare-tunnel.sh`: `SCRIPT_REMOVE_PLAYBOOK` already set~~ ✅
7. ~~Verify full `./uis deploy` and `./uis undeploy` cycle for tailscale-tunnel~~ ✅ Done (PLAN-010)
8. ~~Verify full `./uis deploy` and `./uis undeploy` cycle for cloudflare-tunnel~~ ✅ Done (PR #43)

## Related Files

| File | Role |
|------|------|
| `provision-host/uis/services/network/service-tailscale-tunnel.sh` | Service metadata (needs `SCRIPT_REMOVE_PLAYBOOK`) |
| `provision-host/uis/services/network/service-cloudflare-tunnel.sh` | Service metadata (needs `SCRIPT_REMOVE_PLAYBOOK`) |
| `ansible/playbooks/801-setup-network-tailscale-tunnel.yml` | Deploy playbook (reference for resources created) |
| `ansible/playbooks/820-setup-network-cloudflare-tunnel.yml` | Deploy playbook (reference for resources created) |
| `ansible/playbooks/806-remove-tailscale-internal-ingress.yml` | Existing partial removal (ingress only) |
| `networking/tailscale/802-tailscale-tunnel-deploy.sh` | Legacy deploy script (reference) |
| `networking/cloudflare/820-cloudflare-tunnel-setup.sh` | Legacy setup script (reference) |
| `website/docs/networking/tailscale-setup.md` | User docs: Tailscale setup guide |
| `website/docs/networking/tailscale-internal-ingress.md` | User docs: Tailscale internal ingress |
| `website/docs/networking/tailscale-network-isolation.md` | User docs: Tailscale network isolation |
| `website/docs/networking/cloudflare-setup.md` | User docs: Cloudflare setup guide |
