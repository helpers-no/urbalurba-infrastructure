# PLAN-002: Tailscale network CLI port

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Completed (talk54 R1-R10 PASS on `dog-pence.ts.net`)

**Goal**: Port Tailscale from `uis tailscale expose/unexpose/verify` + `uis deploy tailscale-tunnel` to a first-class `uis network <verb> tailscale` family symmetric with the Cloudflare port (PRs #169–#172), including per-service `expose`/`unexpose` sub-verbs.

**Last Updated**: 2026-05-14

**Investigation**: [INVESTIGATE-tailscale-architecture-cleanup.md](./INVESTIGATE-tailscale-architecture-cleanup.md) — Decisions 5, 7, 8, 9, 10, 14; Contracts C-1 through C-11.

**Prerequisites**: [PLAN-001-tailscale-variable-cleanup-and-deletions](../completed/PLAN-001-tailscale-variable-cleanup-and-deletions.md) — ✅ shipped in PR #173 (`c02c2e5`) + #174 (`9129a08`) + #175 (`f5c56c8`). Talk52 closed with full clean-slate verification on `:latest`.

**Blocks**: PLAN-003-tailscale-docs-lift-up depends on the new CLI surface existing.

**Priority**: High — main user-facing deliverable of the Tailscale architecture-cleanup initiative.

---

## Overview

After PLAN-001 lands the cleanup, this plan builds the new CLI surface. Five core verbs (`init`, `up`, `down`, `status`, `verify`) mirror the Cloudflare port shape; two additional sub-verbs (`expose`, `unexpose`) are Tailscale-specific because per-service Funnel devices are the canonical exposure model (Decision 8 — Tailscale tailnets have no wildcard subdomain DNS, so per-service is the only viable shape for multi-service demos).

A critical user-facing fact this plan must surface (per Decision 10 / C-8): **Tailscale Funnel bypasses Traefik**. The operator's per-service proxy pod forwards directly to the backend Kubernetes Service. Authentik forward-auth, Traefik middleware, and HostRegexp matching do not apply on Tailscale-exposed URLs. The wizard banner, the `expose.sh` first-use prompt, and (in PLAN-003) the `networking/tailscale.md` callout all surface this.

After this plan ships, the new CLI replaces the legacy. `cmd_tailscale` becomes a redirect stub mirroring `cmd_cloudflare`. `tailscale-tunnel` is removed from `services.json`.

---

## Phase 1: Operator install split + core scripts

Decision 5 splits the operator install into its own playbook so it's idempotent and reusable. C-1 through C-4 + C-9 define the four core scripts.

### Tasks

- [x] 1.1 Created `ansible/playbooks/800-tailscale-operator-install.yml` (Decision 5). Idempotent Helm install of `tailscale-operator` in `namespace: tailscale`. Cleans up stale operator devices via API pre-install. Numbered 800 (not 8XX) to share the operator-config Jinja2 manifest number.
- [x] 1.2 Replaced `802-deploy-network-tailscale-tunnel.yml` with `802-tailscale-funnel-ingress.yml` (operator install lifted to 800; cluster Funnel ingress logic only here, opt-in). Also re-pointed the four stale references at the new playbook: legacy `802-tailscale-tunnel-deploy.sh`, `service-tailscale-tunnel.sh`, `services.json` entry, and `800-tailscale-operator-config.yaml.j2` comment header.
- [x] 1.3 Created `networking/tailscale/scripts/init.sh` (C-3). 4-prompt wizard:
  - Prompt order: `TAILSCALE_TAILNET`, `TAILSCALE_CLIENTID`, `TAILSCALE_CLIENTSECRET`, `TAILSCALE_OWNER_ID`
  - `OWNER_ID` prompt validates `^[a-z0-9-]+$` and max length 32 chars
  - Banner lists 4 admin-console prereqs (Q5 resolution): OAuth client with right scopes, MagicDNS, Funnel `nodeAttrs`, tailnet name
  - First paragraph surfaces the Traefik-bypass fact (C-8 surfacing #1)
  - 3-option Skip/Re-prompt/Show menu when `.uis.secrets/service-keys/tailscale.env` exists
  - Writes `service-keys/tailscale.env` (mode 0600) AND patches the matching lines in `secrets-config/00-common-values.env.template`; preserves comment blocks intact
- [x] 1.4 Created `networking/tailscale/scripts/up.sh` (C-2 + C-9 + C-11):
  - Refuse if `TAILSCALE_OWNER_ID` empty (C-9 defensive guard)
  - Detect owner-id change vs running operator (C-11) — refuse with "tear down first" pointer if mismatch
  - Parse `--with-cluster-funnel` flag
  - Chain `uis secrets generate && uis secrets apply`
  - Invoke `ansible-playbook 8XX-tailscale-operator-install.yml`; if `--with-cluster-funnel`, also `802-tailscale-funnel-ingress.yml`
  - Closing banner: operator pod state + cluster Funnel URL (if applicable) + `Next: ./uis network expose tailscale <svc>` hint
- [x] 1.5 Created `networking/tailscale/scripts/down.sh`:
  - Invoke `ansible-playbook 801-remove-network-tailscale-tunnel.yml` (cleans operator + cluster Funnel + per-service devices + tailnet API device cleanup)
  - Preserve `.uis.secrets/service-keys/tailscale.env` (symmetric to cloudflare)
  - Closing banner: cluster cleanup confirmed + admin-console cleanup hints (revoke OAuth client + delete stale devices) for full retirement
- [x] 1.6 Created `networking/tailscale/scripts/status.sh` (C-1):
  - Default mode: human-readable summary — operator pod state, list of exposed services with their `<svc>-<owner_id>` device names, cluster Funnel state if deployed
  - `--summary` flag emits `<state>\t<hint>` for `uis network list`. States: `not-initialized | configured-not-running | running | unreachable`
- [x] 1.7 Created `networking/tailscale/scripts/verify.sh` (C-4). Chains `ansible-playbook 803-verify-tailscale.yml`. Note: the verify playbook runs 4 checks (Secrets / API Connectivity / Stale Devices / Operator), not 5 — the SECRET check was never a separate check, just a sub-validation inside check 1 (see talk52 R5 Nit 1).

### Validation

```bash
# Operator install playbook syntax + idempotency dry-run
ansible-playbook ansible/playbooks/8XX-tailscale-operator-install.yml --syntax-check
ansible-playbook ansible/playbooks/802-tailscale-funnel-ingress.yml --syntax-check

# All 5 scripts pass syntax check
for s in init up down status verify; do
  bash -n "networking/tailscale/scripts/$s.sh" && echo "✓ $s.sh OK"
done

# Status --summary contract — empty state should emit "not-initialized\t<hint>"
./networking/tailscale/scripts/status.sh --summary
```

User confirms phase is complete.

---

## Phase 2: Per-service expose / unexpose

Decision 8 ports the legacy per-service shell-script logic into the new scripts namespace. C-7 + C-8 + C-10 define the contract.

### Tasks

- [x] 2.1 Created `networking/tailscale/scripts/expose.sh` (C-7, C-8, C-10). Device name correction vs the original task copy: per-service device name is `<service>.<tailnet>` (no owner_id prefix) — talk52 R6 verified this; the addhost playbook constructs the FQDN as `ingress_hostname + '.' + tailnet`. Invokes `802-tailscale-tunnel-addhost.yml` with `-e service_name=<svc> -e tailscale_tailnet=<tailnet>` (no `device_hostname` flag).
- [x] 2.2 Created `networking/tailscale/scripts/unexpose.sh` (C-7). Idempotent — unexposing a never-exposed service is a successful no-op. Deletes the `<svc>-tailscale` Ingress from `default`, then invokes `803-tailscale-device-cleanup.yml` for immediate API-side cleanup.
- [x] 2.3 Deleted `networking/tailscale/802-tailscale-tunnel-deploy.sh`.
- [x] 2.4 Deleted `networking/tailscale/803-tailscale-tunnel-deletehost.sh`.

### Validation

```bash
# Syntax checks
bash -n networking/tailscale/scripts/expose.sh && echo "✓ expose.sh OK"
bash -n networking/tailscale/scripts/unexpose.sh && echo "✓ unexpose.sh OK"

# Confirm deleted legacy scripts are gone
[ ! -f networking/tailscale/802-tailscale-tunnel-deploy.sh ] && echo "✓ 802-deploy.sh deleted"
[ ! -f networking/tailscale/803-tailscale-tunnel-deletehost.sh ] && echo "✓ 803-deletehost.sh deleted"

# Expose refuses cleanly when operator not deployed
./networking/tailscale/scripts/expose.sh whoami 2>&1 | grep -q 'operator not deployed' && echo "✓ expose refuses without operator"
```

User confirms phase is complete.

---

## Phase 3: CLI dispatcher port (`uis-cli.sh`)

C-6 defines the redirect-stub shape. New `cmd_network` subcommands for `expose`/`unexpose`.

### Tasks

- [x] 3.1 `tailscale` works in `cmd_network` for `init / up / down / status / verify` — the dispatcher already discovered providers by script presence; the scripts created in Phase 1 wired tailscale in automatically.
- [x] 3.2 Added `expose` and `unexpose` subcommands of `cmd_network`. Both refuse cleanly for cloudflare with a pointer to the cluster-tunnel model (Cloudflare has no per-service expose concept).
- [x] 3.3 Refactored `cmd_network_list` to share row rendering via `_print_network_provider_row` helper. Tailscale row now reads `status.sh --summary` (dropping the hardcoded "port pending" placeholder).
- [x] 3.4 Replaced `cmd_tailscale` (and its `_expose`/`_unexpose`/`_verify` helpers) with a redirect stub mirroring `cmd_cloudflare`. Maps `expose` → `network expose tailscale`, `unexpose` → `network unexpose tailscale`, `verify` → `network verify tailscale`. Exits 1.
- [x] 3.5 Updated `cmd_verify` — the legacy `uis verify tailscale` alias now dispatches to `cmd_network_verify tailscale` (mirroring the cloudflare alias).
- [x] 3.6 Help text — added `expose`/`unexpose` to the `Network:` block; removed the legacy `Tailscale (legacy verbs)` section; updated the example block to show the `uis network ... tailscale` flow.

### Validation

```bash
bash -n provision-host/uis/manage/uis-cli.sh && echo "✓ uis-cli.sh OK"

# Help shows the new shape
./uis help 2>&1 | grep -A 12 "^Network:"
# Expected: init/up/down/status/verify/expose/unexpose for tailscale + cloudflare

# Redirect stubs fire
./uis tailscale expose whoami 2>&1 | grep -q "moved to 'uis network'" && echo "✓ tailscale expose redirects"
./uis tailscale verify 2>&1 | grep -q "moved to 'uis network'" && echo "✓ tailscale verify redirects"
```

User confirms phase is complete.

---

## Phase 4: Service abstraction cleanup

Decision 7 removes `tailscale-tunnel` from `services.json`, mirroring the Cloudflare port pattern.

### Tasks

- [x] 4.1 Deleted the `tailscale-tunnel` entry from `website/src/data/services.json`.
- [x] 4.2 Deleted `provision-host/uis/services/networking/service-tailscale-tunnel.sh`.
- [x] 4.3 Cleared the entire `SKIP_SERVICES_CONDITIONAL` body in `provision-host/uis/lib/integration-testing.sh` (was tailscale-only; no other services use it today). The gate line is gone.
- [x] 4.4 `./uis deploy tailscale-tunnel` now fails through the standard "service not found" path (the service file is gone, so the service registry doesn't list it). No custom redirect message yet — that's a small follow-up if the friction is noticed.

### Validation

```bash
# services.json parses + no tailscale-tunnel entry
python3 -c "import json; data=json.load(open('website/src/data/services.json')); assert not any(s.get('id')=='tailscale-tunnel' for s in data.get('@graph', data) if isinstance(s, dict))"

# Legacy deploy errors with redirect
./uis deploy tailscale-tunnel 2>&1 | grep -q "moved to './uis network up tailscale'" && echo "✓ legacy deploy redirects"
```

User confirms phase is complete.

---

## Phase 5: Local verification

### Tasks

- [x] 5.1 `cd website && npm run build` — `[SUCCESS] Generated static files in "build".`
- [x] 5.1b `bash provision-host/uis/tests/run-tests.sh` — all 7 test scripts pass (static + unit). Caught `service-tailscale-tunnel.sh` removal early; the structure tests had no assertion for it.
- [x] 5.2 GHCR `Build UIS Container` workflow rebuilds `:latest` on every main merge; talk54 retest pulled the latest image with the dispatcher fix landed.
- [x] 5.3 Tester cycled the container (`./uis stop` + `./uis pull`) — talk54 Message 2 pre-flight confirms.
- [x] 5.4 Smoke test the new CLI surface — talk54 R1-R10 PASS against `dog-pence.ts.net`.

### Validation

```bash
cd website && npm run build 2>&1 | tail -3
# Expected: [SUCCESS] Generated static files in "build".

# Smoke tests above all PASS
```

User confirms phase is complete.

---

## Acceptance Criteria

- [x] `uis help` shows Network section with 7 subcommands and `tailscale` listed as a provider — talk54 pre-flight ✓
- [x] `uis network list` shows real tailscale state (not the placeholder) — talk54 R6 ✓
- [x] All 7 scripts exist under `networking/tailscale/scripts/`: init, up, down, status, verify, expose, unexpose
- [x] Operator install is a separate playbook (Decision 5), idempotent — talk54 R3/R4 confirmed
- [x] `uis tailscale expose/unexpose/verify` all fire the redirect stub (C-6) — talk54 R7 + pre-flight ✓
- [x] `uis deploy tailscale-tunnel` errors with redirect (Decision 7 mirrors cloudflare) — talk54 pre-flight ✓
- [x] Traefik-bypass fact surfaced in wizard banner + `expose.sh` first-use prompt (C-8 surfacing #1 + #3) — talk54 R2 + R5 ✓
- [x] Local `npm run build` succeeds; `bash -n` clean on all scripts
- [x] Cluster verification round complete — talk54 R1-R10 PASS on `dog-pence.ts.net`

---

## Files to Modify

**Create:**
- `ansible/playbooks/8XX-tailscale-operator-install.yml`
- `networking/tailscale/scripts/init.sh`
- `networking/tailscale/scripts/up.sh`
- `networking/tailscale/scripts/down.sh`
- `networking/tailscale/scripts/status.sh`
- `networking/tailscale/scripts/verify.sh`
- `networking/tailscale/scripts/expose.sh`
- `networking/tailscale/scripts/unexpose.sh`

**Rename:**
- `ansible/playbooks/802-deploy-network-tailscale-tunnel.yml` → `ansible/playbooks/802-tailscale-funnel-ingress.yml`

**Edit:**
- `provision-host/uis/manage/uis-cli.sh` (cmd_network adds tailscale; cmd_network adds expose/unexpose; cmd_tailscale → redirect stub; cmd_verify alias; cmd_network_list reads real summary; help text)
- `provision-host/uis/lib/integration-testing.sh` (drop tailscale-tunnel gate line)
- `website/src/data/services.json` (delete tailscale-tunnel entry)

**Delete:**
- `provision-host/uis/services/networking/service-tailscale-tunnel.sh`
- `networking/tailscale/802-tailscale-tunnel-deploy.sh`
- `networking/tailscale/803-tailscale-tunnel-deletehost.sh`

---

## Implementation Notes

- **Mirror `cmd_cloudflare` shape precisely.** The redirect-stub pattern, the wizard structure, the script entry points, the `_uis_cluster_banner` walk-in/walk-out per verb — all of it should match the Cloudflare port. Reviewers familiar with PRs #169–#172 should find the diff structurally familiar.
- **C-10 is intentionally narrow.** `expose.sh` assumes `default` namespace + port 80 because that's what every UIS-deployed service uses today. If a real use case for non-default port or namespace surfaces, add `--port` / `--namespace` flags in a follow-up. Don't pre-build.
- **C-11 (owner-id-change detection) is the only piece that's genuinely new logic.** Decisions 13 + 14 made owner-id the cross-cutting identity; if the user changes it after deploy, the cluster's operator and tailnet devices are still under the old name. The detection compares env-file value vs the operator's actual device name annotation. Implementation: read the operator Deployment's pod template label or annotation; bail if mismatch with a clear pointer to `down` first.
- **Tester verification round is scoped to PLAN-003**, not here. PLAN-002 ends at local smoke tests against `:local` image. The real cluster work (init → up → expose → curl from phone → unexpose → down) waits for PLAN-003.
