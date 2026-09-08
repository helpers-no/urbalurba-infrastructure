# PLAN: Cloudflare tunnel fixes — reduce replicas, clean up deploy output, create undeploy playbook

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed

**Goal**: Reduce Cloudflare tunnel from 2 replicas to 1, clean up confusing deploy output, and create `821-remove-network-cloudflare-tunnel.yml` so `./uis undeploy cloudflare-tunnel` works.

**Last Updated**: 2026-02-26

**Priority**: Low — deploy works, undeploy is the missing half

**Parent**: [STATUS-service-migration.md](STATUS-service-migration.md) — Phase 3

---

## Problem Summary

1. **Unnecessary replicas**: The manifest `820-cloudflare-tunnel-base.yaml` runs 2 replicas of cloudflared. For a local dev environment this is wasteful — 1 replica is sufficient.
2. **Confusing deploy output**: The deploy playbook (`820-deploy-network-cloudflare-tunnel.yml`) uses three mutually exclusive tasks (15, 15a, 15b) for the connectivity test result. Ansible prints "skipping" for the two that don't apply, including `"Skip connectivity test - domain not configured"` even when the domain IS configured. This is confusing — users think something is wrong.
3. **Missing undeploy**: `service-cloudflare-tunnel.sh` references `SCRIPT_REMOVE_PLAYBOOK="821-remove-network-cloudflare-tunnel.yml"` but the playbook doesn't exist. Running `./uis undeploy cloudflare-tunnel` will fail.

---

## What the deploy creates

The deploy playbook (`820-deploy-network-cloudflare-tunnel.yml`) applies a single manifest (`820-cloudflare-tunnel-base.yaml`) which creates:

| Resource | Name | Namespace |
|----------|------|-----------|
| Deployment | `cloudflare-tunnel` | `default` |

That's it — no Helm release, no separate namespace, no CRDs, no Cloudflare-side API cleanup needed (tunnel persists in Cloudflare dashboard independently).

---

## Phase 1: Reduce replicas to 1 — DONE

### Tasks

- [x] 1.1 In `manifests/820-cloudflare-tunnel-base.yaml`: change `replicas: 2` to `replicas: 1` ✓

---

## Phase 2: Clean up deploy playbook output — DONE

### Tasks

- [x] 2.1 Delete tasks 15, 15a, 15b from `ansible/playbooks/820-deploy-network-cloudflare-tunnel.yml` — redundant with final summary ✓
- [x] 2.2 Also removed legacy cleanup tasks (ConfigMap, Secret) from remove playbook — not used by token-based deploy ✓

---

## Phase 3: Create the remove playbook — DONE

### Tasks

- [x] 3.1 Created `ansible/playbooks/821-remove-network-cloudflare-tunnel.yml` ✓
  1. Validates kubeconfig exists
  2. Checks if the deployment exists
  3. Deletes the deployment using `kubernetes.core.k8s` with `state: absent`
  4. Waits for pods to terminate
  5. Displays summary with note that tunnel still exists in Cloudflare dashboard

---

## Phase 4: Test — DONE

### Tasks

- [x] 4.1 Deploy cloudflare-tunnel: `./uis deploy cloudflare-tunnel` ✓
- [x] 4.2 Verify only 1 pod running (not 2) ✓
- [x] 4.3 Verify deploy output has no confusing "skipping" messages ✓
- [x] 4.4 Verify `./uis list` shows Deployed ✓
- [x] 4.5 Undeploy: `./uis undeploy cloudflare-tunnel` ✓
- [x] 4.6 Verify removed: `./uis list` shows Not deployed ✓
- [x] 4.7 Redeploy to confirm clean cycle: `./uis deploy cloudflare-tunnel` ✓
- [x] 4.8 End-to-end connectivity test passed (HTTP 200 via https://urbalurba.no) ✓

---

## Acceptance Criteria

- [x] Cloudflare tunnel runs 1 pod (not 2)
- [x] Deploy output is clean — no misleading "skipping" messages
- [x] `./uis undeploy cloudflare-tunnel` successfully removes the deployment
- [x] `./uis list` shows "Not deployed" after undeploy
- [x] No cloudflared pods remain after undeploy
- [x] Clean redeploy works after undeploy
- [x] Summary message tells user the tunnel still exists in Cloudflare dashboard

---

## Files Modified

| File | Change |
|------|--------|
| `manifests/820-cloudflare-tunnel-base.yaml` | Changed `replicas: 2` to `replicas: 1` |
| `ansible/playbooks/820-deploy-network-cloudflare-tunnel.yml` | Deleted redundant tasks 15, 15a, 15b |

## Files Created

| File | Purpose |
|------|---------|
| `ansible/playbooks/821-remove-network-cloudflare-tunnel.yml` | Remove playbook |

## Files Already Correct

| File | Status |
|------|--------|
| `provision-host/uis/services/network/service-cloudflare-tunnel.sh` | Already has `SCRIPT_REMOVE_PLAYBOOK="821-remove-network-cloudflare-tunnel.yml"` |
