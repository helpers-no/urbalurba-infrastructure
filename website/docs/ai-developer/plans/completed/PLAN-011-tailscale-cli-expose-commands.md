# PLAN-011: Tailscale CLI Commands (expose/unexpose/verify)

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed

**Goal**: Group all Tailscale operations under `./uis tailscale` — expose/unexpose services and verify configuration — so users don't need to enter the shell or know internal script paths.

**Last Updated**: 2026-02-23

**Priority**: Low — quality-of-life improvement

**Completed**: 2026-02-23 — All tests passed first round (see talk13.md → talk.md)

**Parent**: Follows from PLAN-010 (Tailscale API device cleanup and verify command)

---

## Problem Summary

Adding or removing a service from Tailscale Funnel currently requires entering the provision-host shell and knowing internal script paths:

```bash
# Current workflow (too many steps, user needs to know internals):
./uis shell
cd /mnt/urbalurbadisk
./networking/tailscale/802-tailscale-tunnel-deploy.sh whoami
./networking/tailscale/803-tailscale-tunnel-deletehost.sh whoami
exit
```

This should be exposed as top-level `uis` commands:

```bash
# Proposed workflow:
./uis tailscale expose whoami
./uis tailscale unexpose whoami
```

The full user workflow becomes:
```bash
./uis deploy tailscale-tunnel          # 1. one-time: install operator
./uis deploy whoami                    # 2. deploy the service
./uis tailscale expose whoami          # 3. expose via Tailscale Funnel
./uis tailscale unexpose whoami        # 4. remove from Tailscale
./uis tailscale verify                 # diagnostics
```

---

## Implementation Plan

### Phase 1: Add `tailscale` command to UIS CLI

- [x] 1.1 Add `cmd_tailscale()` function to `provision-host/uis/manage/uis-cli.sh` with subcommand routing (`expose`, `unexpose`, `verify`)
- [x] 1.2 Add `cmd_tailscale_expose()` that calls `802-tailscale-tunnel-deploy.sh <service>`
- [x] 1.3 Add `cmd_tailscale_unexpose()` that calls `803-tailscale-tunnel-deletehost.sh <service>`
- [x] 1.4 Move existing `cmd_verify_tailscale()` into `cmd_tailscale_verify()` (so `./uis tailscale verify` replaces `./uis verify tailscale`)
- [x] 1.5 Add `tailscale)` case in main command routing
- [x] 1.6 Add to help text under a "Tailscale:" section
- [ ] 1.7 Validate that tailscale-tunnel service is deployed before expose/unexpose (check for operator pod) — skipped, underlying scripts handle this
- [x] 1.8 Decide whether to keep `./uis verify tailscale` as a backwards-compatible alias or remove it — kept as alias

### Phase 2: Build and Test

- [x] 2.1 Build with `./uis build`
- [x] 2.2 Test full cycle: deploy tailscale-tunnel, deploy whoami, expose whoami, unexpose whoami
- [x] 2.3 Test error cases: no-args usage, missing service parameter

---

## Acceptance Criteria

- [x] `./uis tailscale expose <service>` adds the service to Tailscale Funnel
- [x] `./uis tailscale unexpose <service>` removes the service from Tailscale Funnel (including API device cleanup)
- [x] `./uis tailscale verify` runs pre-deployment checks (`./uis verify tailscale` kept as alias)
- [x] Help text shows the new commands

---

## Files to Modify

| File | Action | Description |
|------|--------|-------------|
| `provision-host/uis/manage/uis-cli.sh` | Modify | Add `tailscale` command with `expose`/`unexpose` subcommands |

## Reference Files

| File | Pattern |
|------|---------|
| `provision-host/uis/manage/uis-cli.sh` | Existing `cmd_verify()` pattern for subcommand routing |
| `networking/tailscale/802-tailscale-tunnel-deploy.sh` | Script called by `expose` |
| `networking/tailscale/803-tailscale-tunnel-deletehost.sh` | Script called by `unexpose` |
