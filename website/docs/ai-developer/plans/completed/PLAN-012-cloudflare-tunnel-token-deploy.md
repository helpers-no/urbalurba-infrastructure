# PLAN-012: Token-Based Cloudflare Tunnel Deployment

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed

**Goal**: Deploy Cloudflare tunnel via `./uis deploy cloudflare-tunnel` using a token-based approach that follows the same secrets pattern as all other UIS services.

**Last Updated**: 2026-02-24

**Priority**: Medium — Cloudflare is the production networking solution (custom domains, wildcard routing, CDN)

**Parent**: [INVESTIGATE-cloudflare-tunnel-uis-integration.md](../completed/INVESTIGATE-cloudflare-tunnel-uis-integration.md)

---

## Problem Summary

Cloudflare tunnel exists in the codebase but uses an interactive credential-file-based approach (browser auth, generated JSON credentials, local config files). This doesn't match the UIS secrets pattern. The existing service metadata has 3 bugs (wrong namespace, wrong playbook, missing remove playbook). The interactive scripts work but are complex and fragile.

**Token-based approach**: User creates tunnel in Cloudflare dashboard, gets a single token, puts it in `00-common-values.env.template`, deploys. All routing configured in dashboard, not in K8s ConfigMaps.

---

## Phase 1: Secrets Configuration

### Tasks

- [x] 1.1 Add `CLOUDFLARE_TUNNEL_TOKEN` to `provision-host/uis/templates/secrets-templates/00-common-values.env.template` (after existing `CLOUDFLARE_DNS_TOKEN` line 59)
- [x] 1.2 Update Cloudflare section in `provision-host/uis/templates/secrets-templates/00-master-secrets.yml.template`:
  - Replaced `CLOUDFLARE_TEST_*` and `CLOUDFLARE_PROD_*` variables with `CLOUDFLARE_TUNNEL_TOKEN` and `BASE_DOMAIN_CLOUDFLARE`
  - Deleted hardcoded `cloudflared-credentials` secret with old tunnel JSON
- [x] 1.3 Add `CLOUDFLARE_TUNNEL_TOKEN` default placeholder to `provision-host/uis/templates/default-secrets.env`
- [x] 1.4 Add `CLOUDFLARE_TUNNEL_TOKEN` to `show_secrets_status()` in `provision-host/uis/lib/secrets-management.sh`

---

## Phase 2: Move Legacy Scripts

### Tasks

- [x] 2.1 Create directories: `networking/cloudflare/legacy/` and `ansible/playbooks/legacy/`
- [x] 2.2 `git mv` the 5 legacy files:
  - `networking/cloudflare/820-cloudflare-tunnel-setup.sh` → `networking/cloudflare/legacy/`
  - `networking/cloudflare/821-cloudflare-tunnel-deploy.sh` → `networking/cloudflare/legacy/`
  - `networking/cloudflare/822-cloudflare-tunnel-delete.sh` → `networking/cloudflare/legacy/`
  - `ansible/playbooks/820-setup-network-cloudflare-tunnel.yml` → `ansible/playbooks/legacy/`
  - `ansible/playbooks/821-deploy-network-cloudflare-tunnel.yml` → `ansible/playbooks/legacy/`
- [x] 2.3 Create `networking/cloudflare/legacy/README.md` explaining these are the old interactive scripts
- [x] 2.4 Create `ansible/playbooks/legacy/README.md` explaining these are the old Cloudflare playbooks
- [x] 2.5 Delete `manifests/820-cloudflare-tunnel-base.yaml.j2` (old Jinja2 manifest)

---

## Phase 3: Manifest and Playbooks

### Tasks

- [x] 3.1 Create `manifests/820-cloudflare-tunnel-base.yaml` (static, not Jinja2):
  - Token from `urbalurba-secrets` via `secretKeyRef` (env var `TUNNEL_TOKEN`)
  - 2 replicas, `--no-autoupdate`, `--metrics 0.0.0.0:2000`, liveness/readiness probe on `/ready:2000`
  - No ConfigMap, no credentials volume mount
  - Namespace: `default`, label: `app: cloudflared`

- [x] 3.2 Create `ansible/playbooks/820-deploy-network-cloudflare-tunnel.yml`:
  - Validate kubeconfig exists
  - Extract `CLOUDFLARE_TUNNEL_TOKEN` and `BASE_DOMAIN_CLOUDFLARE` from `urbalurba-secrets`, fail if placeholder
  - Apply the static manifest
  - Wait for pods to be running
  - 15-second pause for tunnel registration
  - End-to-end HTTP connectivity test (12 retries, accepts 200/301/302/404)

- [x] 3.3 Create `ansible/playbooks/821-remove-network-cloudflare-tunnel.yml`:
  - Delete manifest resources (`kubernetes.core.k8s` state=absent)
  - Clean up legacy resources (ConfigMap `cloudflare-tunnel-config`, Secret `cloudflared-credentials`)
  - Wait for pod termination
  - Print manual cleanup reminder (delete tunnel in Cloudflare dashboard)

- [x] 3.4 Create `ansible/playbooks/822-verify-cloudflare.yml`:
  - Check 1: `CLOUDFLARE_TUNNEL_TOKEN` in secrets, not placeholder
  - Check 2: Network connectivity (DNS `region1.v2.argotunnel.com`, TCP port 7844)
  - Check 3: Pod status if deployed
  - Check 4: Pod logs summary if deployed
  - Check 5: End-to-end HTTP connectivity through tunnel

---

## Phase 4: Service Metadata and CLI

### Tasks

- [x] 4.1 Fix `provision-host/uis/services/network/service-cloudflare-tunnel.sh`:
  - `SCRIPT_PLAYBOOK` → `820-deploy-network-cloudflare-tunnel.yml`
  - `SCRIPT_CHECK_COMMAND` → `kubectl get pods -n default -l app=cloudflared --no-headers 2>/dev/null | grep -q Running`
  - `SCRIPT_REMOVE_PLAYBOOK` → `821-remove-network-cloudflare-tunnel.yml`

- [x] 4.2 Add Cloudflare commands to `provision-host/uis/manage/uis-cli.sh`:
  - Add `cmd_cloudflare()` with subcommands: `verify`, `teardown`
  - Add `cmd_cloudflare_verify()` → calls `822-verify-cloudflare.yml`
  - Add `cmd_cloudflare_teardown()` → calls remove playbook + prints manual cleanup steps
  - Add `cloudflare)` case in main routing (after `tailscale)`)
  - Add `cloudflare|cloudflare-tunnel)` case in `cmd_verify()`
  - Add to help text and examples

---

## Phase 5: Build and Test

### Tasks

- [x] 5.1 Build: `./uis build`
- [x] 5.2 Write tester instructions to `talk.md`
- [x] 5.3 Tester tests (5 rounds):
  - `./uis help` — shows Cloudflare section
  - `./uis cloudflare` — shows usage
  - `./uis cloudflare verify` — checks secrets, network, pod status, logs, E2E
  - `./uis deploy cloudflare-tunnel` — deploys tunnel pods
  - `./uis cloudflare verify` — shows healthy status (all 5 checks PASS)
  - `./uis undeploy cloudflare-tunnel` — removes pods
  - `./uis cloudflare teardown` — removes + shows manual cleanup steps
  - `./uis verify cloudflare` — backwards-compat alias works

---

## Phase 6: Documentation

### Tasks

- [x] 6.1 Update `website/docs/networking/cloudflare-setup.md`:
  - Fix Traefik namespace: `traefik.kube-system.svc.cluster.local:80` (not `default`)
  - Fix secrets file path: `.uis.secrets/secrets-config/00-common-values.env.template` (not `.uis.secrets/config/00-common-values.env`)
  - Add `./uis secrets edit` as recommended editing method
  - Add missing `./uis secrets apply` step
  - Update pod count from singular to 2 replicas (HA)
  - Document all 5 verification checks in Step 6

---

## Bugs Found and Fixed During Implementation

### Bug 1: Template sync — new secrets keys not reaching K8s (Rounds 1-3)

**Symptom**: `CLOUDFLARE_TUNNEL_TOKEN` added to source templates in Docker image, but after `./uis secrets generate`, the key was missing from the K8s secret.

**Root cause**: `copy_secrets_templates()` in `first-run.sh` had an early return when `00-common-values.env.template` already existed — it skipped ALL template copies, including the master template. So when a new key was added to the source master template (in the Docker image), existing user installations never got the update.

**Fix (Round 2)**: Added diff+copy logic inside the early-return guard in `copy_secrets_templates()`:
- When common-values template exists, diff the master template against the source
- If different, copy the updated master template and log "Updated master secrets template"

**Fix (Round 3)**: The sync logic was unreachable because `copy_secrets_templates()` was only called during first-run initialization, not from `./uis secrets generate`. Added `copy_secrets_templates` as the first call in `generate_secrets()` in `secrets-management.sh`.

**Files modified**:
- `provision-host/uis/lib/first-run.sh` — master template sync logic
- `provision-host/uis/lib/secrets-management.sh` — call sync from `generate_secrets()`

### Bug 2: Traefik namespace in Cloudflare dashboard (Round 4)

**Symptom**: 502 Bad Gateway on E2E HTTP test through the tunnel.

**Root cause**: Cloudflare dashboard routes pointed to `traefik.default.svc.cluster.local:80` but Traefik runs in `kube-system` namespace (Rancher Desktop standard).

**Fix**: User manually updated Cloudflare Zero Trust dashboard routes to `traefik.kube-system.svc.cluster.local:80`. Also fixed all references in `cloudflare-setup.md`.

### Bug 3: `default-secrets.env` variable naming

**Symptom**: Default value not applied during secrets generation.

**Root cause**: Initially used `DEFAULT_CLOUDFLARE_TUNNEL_TOKEN` but the `get_default_secret()` function does indirect variable expansion — the variable name must match exactly (no `DEFAULT_` prefix).

**Fix**: Changed to `CLOUDFLARE_TUNNEL_TOKEN=your-cloudflare-tunnel-token-here` in `default-secrets.env`.

---

## Acceptance Criteria

- [x] `./uis deploy cloudflare-tunnel` deploys 2 cloudflared pods using token from urbalurba-secrets
- [x] `./uis undeploy cloudflare-tunnel` removes the deployment cleanly
- [x] `./uis cloudflare verify` checks secrets, network connectivity (port 7844), pod status, logs, and E2E HTTP
- [x] `./uis cloudflare teardown` removes pods and prints Cloudflare dashboard cleanup instructions
- [x] Tunnel connects to Cloudflare and status changes to "Healthy" in dashboard
- [x] End-to-end HTTP 200 verified through tunnel
- [x] Legacy interactive scripts preserved in `legacy/` directories
- [x] Old unused secrets variables removed from master template
- [x] Hardcoded `cloudflared-credentials` secret removed from master template
- [x] Template sync mechanism ensures new keys propagate to existing installations
- [x] Documentation updated with correct paths, namespace, and procedures

---

## Files Modified

| File | Action |
|------|--------|
| `provision-host/uis/templates/secrets-templates/00-common-values.env.template` | Add `CLOUDFLARE_TUNNEL_TOKEN` |
| `provision-host/uis/templates/secrets-templates/00-master-secrets.yml.template` | Clean up Cloudflare section, add `CLOUDFLARE_TUNNEL_TOKEN` + `BASE_DOMAIN_CLOUDFLARE`, remove hardcoded credentials |
| `provision-host/uis/templates/default-secrets.env` | Add placeholder |
| `provision-host/uis/lib/secrets-management.sh` | Add to status display, add `copy_secrets_templates` call in `generate_secrets()` |
| `provision-host/uis/lib/first-run.sh` | Add master template sync logic in `copy_secrets_templates()` |
| `manifests/820-cloudflare-tunnel-base.yaml.j2` | Deleted (replaced by static .yaml) |
| `manifests/820-cloudflare-tunnel-base.yaml` | Created (token-based deployment, 2 replicas) |
| `ansible/playbooks/820-deploy-network-cloudflare-tunnel.yml` | Created (deploy playbook with E2E test) |
| `ansible/playbooks/821-remove-network-cloudflare-tunnel.yml` | Created (remove playbook) |
| `ansible/playbooks/822-verify-cloudflare.yml` | Created (5-check verify playbook) |
| `provision-host/uis/services/network/service-cloudflare-tunnel.sh` | Fixed 3 bugs (playbook, namespace, remove playbook) |
| `provision-host/uis/manage/uis-cli.sh` | Added cloudflare commands (verify, teardown) |
| `networking/cloudflare/820-cloudflare-tunnel-setup.sh` | Moved to `networking/cloudflare/legacy/` |
| `networking/cloudflare/821-cloudflare-tunnel-deploy.sh` | Moved to `networking/cloudflare/legacy/` |
| `networking/cloudflare/822-cloudflare-tunnel-delete.sh` | Moved to `networking/cloudflare/legacy/` |
| `ansible/playbooks/820-setup-network-cloudflare-tunnel.yml` | Moved to `ansible/playbooks/legacy/` |
| `ansible/playbooks/821-deploy-network-cloudflare-tunnel.yml` | Moved to `ansible/playbooks/legacy/` |
| `networking/cloudflare/legacy/README.md` | Created |
| `ansible/playbooks/legacy/README.md` | Created |
| `website/docs/networking/cloudflare-setup.md` | Fixed namespace, paths, pod count, added secrets apply step, documented 5 verify checks |

---

## Implementation Notes

- The manifest is **static YAML** (not `.j2`) because the token is read via `secretKeyRef` — no Jinja2 needed.
- The `TUNNEL_TOKEN` env var name is the **official cloudflared env var** that triggers token-based mode.
- 2 replicas for HA — Cloudflare handles failover automatically between connectors.
- No per-service expose/unexpose needed — wildcard routing (`*.urbalurba.no`) makes all IngressRoute services accessible automatically.
- Port 7844 TCP/UDP is required for tunnel connections — corporate networks may block it.
- Traefik runs in `kube-system` namespace (Rancher Desktop) — Cloudflare dashboard routes must use `traefik.kube-system.svc.cluster.local:80`.
- The template sync fix (Bug 1) is a general improvement — it ensures any future new secret keys added to the Docker image will propagate to existing installations on next `./uis secrets generate`.

## Testing Summary

5 rounds of testing via contributor/tester workflow (talk.md):
- **Round 1**: 6/8 pass, 2 fail — `CLOUDFLARE_TUNNEL_TOKEN` missing from K8s secret (template sync bug)
- **Round 2**: Fix unreachable — sync logic added but `copy_secrets_templates()` not called from generate path
- **Round 3**: 8/8 pass — all CLI commands work, secrets flow correctly
- **Round 4**: E2E added, 502 error — Cloudflare dashboard had wrong Traefik namespace
- **Round 5**: All 5 verify checks PASS, HTTP 200 end-to-end confirmed
