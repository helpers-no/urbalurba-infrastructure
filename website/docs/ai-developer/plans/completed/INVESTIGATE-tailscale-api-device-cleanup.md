# INVESTIGATE: Tailscale API Integration for Device Cleanup and Verification

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed

**Goal**: Use the Tailscale API to clean up stale devices during deletehost/undeploy, and add a `uis verify tailscale` command to check prerequisites before deployment.

**Last Updated**: 2026-02-23

**Completed**: 2026-02-22 — Implemented as PLAN-010, verified in 4 rounds (see talk13.md). All features working: device cleanup in deletehost, default cleanup on undeploy, hostname mismatch detection, verify command.

**Priority**: Medium — stale devices cause hostname suffixes (`whoami-1` instead of `whoami`) that confuse users. The verify command prevents misconfiguration failures.

**Parent**: Follows from PLAN-009 (Tailscale service deploy/undeploy) which is now working end-to-end.

---

## Context

After PLAN-009 implementation and 8 rounds of testing, the Tailscale service deploys and undeploys cleanly. Per-service ingress creation (`addhost`) and removal (`deletehost`) also work. However, two problems remain:

1. **Stale Tailscale devices**: When a per-service ingress is deleted (deletehost) or the tunnel is undeployed, the Tailscale device records remain in the Tailnet. On the next deploy, Tailscale assigns hostname suffixes (`whoami-1` instead of `whoami`) to avoid name collisions. Users see one URL in the script output but the actual URL is different.

2. **No pre-deployment validation**: Tailscale setup requires multiple manual portal steps (account, ACLs, auth key, OAuth client, MagicDNS). If any step is misconfigured, deployment fails with unclear errors. There's no way to validate the configuration before deploying.

## Key Finding: No New Secrets Needed

The existing OAuth credentials (`TAILSCALE_CLIENTID` + `TAILSCALE_CLIENTSECRET`) can authenticate API calls. The scopes already configured in the setup guide include `devices:core` (list/delete devices). The authentication works via HTTP basic auth with `curl -u clientid:clientsecret`.

The `804-tailscale-tunnel-delete.sh` script already implements this pattern successfully (lines 118-155).

---

## Investigation Findings

### Tailscale API Endpoints

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/api/v2/tailnet/{tailnet}/devices` | GET | List all devices in tailnet |
| `/api/v2/device/{deviceId}` | DELETE | Remove a device from tailnet |

Authentication: HTTP Basic Auth with `TAILSCALE_CLIENTID:TAILSCALE_CLIENTSECRET`

### Existing API Usage in Codebase

| File | API Usage | Scope |
|------|-----------|-------|
| `networking/tailscale/804-tailscale-tunnel-delete.sh` | Lists and deletes devices (lines 118-155) | Full cleanup |
| `ansible/playbooks/801-remove-network-tailscale-tunnel.yml` | Same API cleanup (lines 171-227) | Optional (`remove_tailnet_devices: false` by default) |
| `networking/tailscale/803-tailscale-tunnel-deletehost.sh` | **No API cleanup** | Per-service only |
| `networking/tailscale/802-tailscale-tunnel-deploy.sh` | **No API calls** | Deploy only |

### Secret Extraction Patterns

**Shell scripts** (from `804`):
```bash
TAILSCALE_CLIENTID=$(kubectl --kubeconfig="$KUBECONFIG_PATH" get secret urbalurba-secrets -n default \
    -o jsonpath='{.data.TAILSCALE_CLIENTID}' | base64 -d 2>/dev/null)
```

**Ansible playbooks** (from `802-deploy`):
```yaml
kubernetes.core.k8s_info:
  kind: Secret
  name: urbalurba-secrets
  namespace: default
# then: urbalurba_secrets.resources[0].data.TAILSCALE_CLIENTID | b64decode
```

### Device Name Matching

The `804` script uses `.name` field with `test()` for substring matching:
```bash
jq -r ".devices[] | select(.name | test(\"tailscale-operator|${CLUSTER_HOSTNAME:-k8s}|provision-host\"))"
```

The `.name` field contains the FQDN (e.g., `whoami.dog-pence.ts.net`). The `.hostname` field may contain the short name. For per-service cleanup, matching needs to catch both `whoami` and `whoami-1` variants.

### UIS CLI Structure

- No `verify` command exists
- Commands are `cmd_*()` functions in `provision-host/uis/manage/uis-cli.sh`
- Routing via `case "$command" in` at line 1162
- `$ANSIBLE_DIR` is available from `service-deployment.sh` (line 23): `/mnt/urbalurbadisk/ansible/playbooks`

---

## Problem Analysis

### Problem 1: Stale Device Cleanup

**Root cause**: `803-tailscale-tunnel-deletehost.sh` only removes the K8s ingress and waits for pod cleanup. It does NOT call the Tailscale API to remove the device from the Tailnet.

**Impact**: On next addhost, Tailscale sees a device with that hostname already exists and appends `-1`. The deploy script shows the expected URL but the actual URL is different.

**Solution**: Add Tailscale API device cleanup to `803-tailscale-tunnel-deletehost.sh`, following the pattern from `804-tailscale-tunnel-delete.sh`.

**Additionally**: Change `remove_tailnet_devices` default from `false` to `true` in `801-remove-network-tailscale-tunnel.yml` so `uis undeploy tailscale-tunnel` also cleans up devices by default.

### Problem 2: URL Mismatch in Deploy Script

**Root cause**: `802-tailscale-tunnel-deploy.sh` prints `https://$INGRESS_HOSTNAME.$TAILSCALE_DOMAIN` in its success message, using the configured values. The Ansible playbook correctly detects the actual hostname (via `actual_fqdn`), but the shell script wrapper doesn't read it back.

**Impact**: User sees one URL in script output, but the real URL is different.

**Solution**: After the ansible-playbook call, read the actual hostname from ingress status via kubectl and compare. Warn if different, use actual hostname in success message.

### Problem 3: No Pre-deployment Validation

**Root cause**: No way to verify Tailscale configuration is correct before deploying.

**Impact**: Users run `uis deploy tailscale-tunnel`, wait several minutes, then get cryptic errors if OAuth credentials are wrong, ACL tags don't exist, or secrets have placeholder values.

**Solution**: Create `uis verify tailscale` command that checks:
1. Secrets present and not placeholder values
2. API connectivity (can authenticate with OAuth credentials)
3. Stale device report (list devices, flag any with `-N` suffixes)
4. Operator status (is it already running?)

---

## Proposed Changes

### Change 1: Device Cleanup in Deletehost Script

**File**: `networking/tailscale/803-tailscale-tunnel-deletehost.sh`

Add after ingress deletion + pod cleanup:
- Extract API credentials from K8s secrets (same pattern as `804`, lines 66-83)
- Call `GET /api/v2/tailnet/{tailnet}/devices` to list devices
- Filter devices matching the hostname being deleted (including `-N` variants)
- Call `DELETE /api/v2/device/{id}` for each matching device
- Report results in status output

### Change 2: Default Device Cleanup on Undeploy

**File**: `ansible/playbooks/801-remove-network-tailscale-tunnel.yml`

One-line change: `remove_tailnet_devices: false` to `remove_tailnet_devices: true` (line 26)

### Change 3: Hostname Mismatch Detection on Deploy

**File**: `networking/tailscale/802-tailscale-tunnel-deploy.sh`

After the ansible-playbook call for ingress creation:
- Read actual hostname from ingress status via kubectl
- Compare to expected hostname
- Warn if different
- Use actual hostname in success message

### Change 4: Verify Command

**New file**: `ansible/playbooks/803-verify-tailscale.yml`

Verification playbook with checks:
1. Secrets existence and validity
2. API connectivity with OAuth credentials (using `ansible.builtin.uri`)
3. Stale device listing
4. Operator status

**Modified file**: `provision-host/uis/manage/uis-cli.sh`

Add `cmd_verify()` and `cmd_verify_tailscale()` functions, routing, and help text.

---

## Files Summary

| File | Action | Description |
|------|--------|-------------|
| `networking/tailscale/803-tailscale-tunnel-deletehost.sh` | Modify | Add API device cleanup |
| `ansible/playbooks/801-remove-network-tailscale-tunnel.yml` | Modify | Change default to `true` |
| `networking/tailscale/802-tailscale-tunnel-deploy.sh` | Modify | Add hostname mismatch detection |
| `provision-host/uis/manage/uis-cli.sh` | Modify | Add `verify` command |
| `ansible/playbooks/803-verify-tailscale.yml` | Create | Verification playbook |

## Reference Files (no changes)

| File | Pattern to Follow |
|------|-------------------|
| `networking/tailscale/804-tailscale-tunnel-delete.sh` | API cleanup pattern (lines 66-83, 118-155) |
| `ansible/playbooks/802-deploy-network-tailscale-tunnel.yml` | Secret extraction in Ansible (lines 42-55) |
| `provision-host/uis/lib/service-deployment.sh` | `ANSIBLE_DIR` definition (line 23) |

---

## Verification Plan

1. Build with `./uis build`
2. Deploy tailscale-tunnel + whoami
3. Add whoami via shell script — note if hostname gets `-1` suffix
4. Delete whoami via `803-tailscale-tunnel-deletehost.sh` — verify API cleanup message
5. Re-add whoami — should get clean `whoami` hostname (no suffix)
6. Run `uis verify tailscale` — verify output shows all checks passing
7. Undeploy tailscale-tunnel — verify device cleanup happens by default

## Open Questions

1. Should the Tailscale API device matching use `.name` (FQDN like `whoami.dog-pence.ts.net`) or `.hostname` (short name)? The `804` script uses `.name` with substring matching. Need to verify actual API response format with a live test.
2. Should `uis verify` be extensible to other services (e.g., `uis verify cloudflare-tunnel`) or Tailscale-specific for now?
3. Should the verify command check ACL policy configuration (requires additional API endpoint)?
