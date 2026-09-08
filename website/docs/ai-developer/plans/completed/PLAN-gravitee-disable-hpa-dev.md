# Feature: System-wide `DEFAULT_AUTOSCALING` toggle, adopted first by Gravitee

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed

**Completed**: 2026-05-04 — Round 5 PASS confirmed by UIS tester (`talk.md:1305+`). All four layers verified, default deploy yields 4 pods + 0 HPAs, `-e _gravitee_autoscaling=true` override re-enables HPAs (chart actually creates HPA templates for all four components, not just ui+portal — see Implementation Notes for the corollary). Round 3 OQ4 chart change unaffected.

**Goal**: Introduce a system-wide `DEFAULT_AUTOSCALING` knob in `default-secrets.env`, propagate it through every setup playbook via ansible extra-vars, and adopt it in Gravitee as the first consumer. With the knob's default value (`false`), `./uis deploy gravitee` produces 4 pods (one each: api, gateway, ui, portal) and zero HPAs. Future autoscaling-aware services (openwebui, jupyterhub, …) adopt the same knob with a 2-line playbook change each.

**Last Updated**: 2026-05-04

**History**: This PLAN's first iteration (2026-05-03) hardcoded `autoscaling: { enabled: false }` in chart values for the four gravitee components — symmetric, but per-service. Maintainer asked for the toggle to be a single system-wide variable that other services can adopt later, defined in `default-secrets.env`. Re-executed under that design.

**Reported in**: Finding 8 of [INVESTIGATE-gravitee-post-deploy-config.md](./INVESTIGATE-gravitee-post-deploy-config.md). Maintainer's verbatim direction: *"we don't need hpa when this is running in development on the local rancher desktop cluster… there might be others that can adopt this later. if we define it in the default-secrets.env and then use that to set _gravitee_autoscaling."*

---

## Problem

Two layered problems:

1. **Gravitee-specific (Finding 8)**: chart-default HPA on `ui` and `portal` scales to max=3 because their idle RSS exceeds the 128 MB memory request. `manifests/090-gravitee-config.yaml` disables autoscaling on `api` and `gateway` but leaves `ui`/`portal` to chart defaults — values-file asymmetry. Every fresh deploy lands with 6 pods, three of which are redundant ui replicas.
2. **System-wide gap**: UIS has no canonical way to express "this is a local-dev install, default to off for production-shaped knobs (HPA, replicas, larger memory requests, …)". Each service inventing its own toggle would fragment the ecosystem.

---

## Solution — Three-layer toggle

### Layer 1 — Single source of truth

Add `DEFAULT_AUTOSCALING=false` to `provision-host/uis/templates/default-secrets.env`. One line plus a comment block explaining the system-wide pattern and adoption guidance for future services.

### Layer 2 — Wrapper passes every `DEFAULT_*` as ansible extra-vars

Modify `provision-host/uis/lib/service-deployment.sh:deploy_single_service` (around the ansible_args build at line 142) to source `default-secrets.env` once and forward every `DEFAULT_*` variable as a lowercased ansible extra-var (e.g. `DEFAULT_AUTOSCALING` → `default_autoscaling`). Future system-wide knobs land here with zero wrapper change.

Lowercase mapping is the convention because ansible vars are case-sensitive and lowercase by community style. The `DEFAULT_` prefix is preserved so the namespace is clear in the playbook.

### Layer 3 — Per-service mapping in playbook

In `ansible/playbooks/090-setup-gravitee.yml`:

```yaml
vars:
  _gravitee_autoscaling: "{{ default_autoscaling | default('false') }}"
```

Then task 24 (helm install) adds four `--set` overrides:

```
--set api.autoscaling.enabled={{ _gravitee_autoscaling }}
--set gateway.autoscaling.enabled={{ _gravitee_autoscaling }}
--set ui.autoscaling.enabled={{ _gravitee_autoscaling }}
--set portal.autoscaling.enabled={{ _gravitee_autoscaling }}
```

### Chart values cleanup

Remove all four `autoscaling: { enabled: false }` blocks from `manifests/090-gravitee-config.yaml` (`api`, `gateway`, `ui`, `portal`). Single source of truth for the autoscaling state is now the helm `--set`. Comments stay, slightly reworded to point at the system-wide knob.

### Override paths

- **System-wide flip on**: edit `default-secrets.env`, set `DEFAULT_AUTOSCALING=true`, redeploy. All adopting services switch on simultaneously.
- **Per-service flip** (e.g. test prod-shape Gravitee while leaving others as dev-shape): `./uis exec ansible-playbook /mnt/urbalurbadisk/ansible/playbooks/090-setup-gravitee.yml -e _gravitee_autoscaling=true` (raw ansible invocation).
- **Future CLI flag** (out of scope here): `./uis deploy gravitee --autoscaling` would plumb through `uis-cli.sh` / `service-deployment.sh` into an explicit extra-var. Separate plan if needed.

---

## Phase 1: System-wide knob plumbing + Gravitee adoption

### Tasks

- [x] 1.1 Add `DEFAULT_AUTOSCALING=false` to `provision-host/uis/templates/default-secrets.env` with a documented comment block. ✓
- [x] 1.2 Modify `provision-host/uis/lib/service-deployment.sh:deploy_single_service` to source `default-secrets.env` and forward every `DEFAULT_*` as lowercased ansible extra-var. ✓
- [x] 1.3 Add `_gravitee_autoscaling: "{{ default_autoscaling | default('false') }}"` to vars block in `090-setup-gravitee.yml` with documentation. ✓
- [x] 1.4 Add four `--set <component>.autoscaling.enabled={{ _gravitee_autoscaling }}` lines to task 24 (helm install). ✓
- [x] 1.5 Remove the four `autoscaling: { enabled: false }` blocks from `manifests/090-gravitee-config.yaml`. Top-of-file comment updated to point at `DEFAULT_AUTOSCALING`. ✓
- [x] 1.6 Run `./uis build`. ✓ (image `uis-provision-host:local`, manifest sha256:ccb43d6a…)

### Validation

```bash
# 1. Layer 1: variable defined.
./uis exec grep DEFAULT_AUTOSCALING /mnt/urbalurbadisk/provision-host/uis/templates/default-secrets.env

# 2. Layer 2: wrapper sources defaults.
./uis exec grep -A2 'default-secrets.env' /mnt/urbalurbadisk/provision-host/uis/lib/service-deployment.sh

# 3. Layer 3: playbook maps the var.
./uis exec grep _gravitee_autoscaling /mnt/urbalurbadisk/ansible/playbooks/090-setup-gravitee.yml

# 4. Helm --set lines present.
./uis exec grep -c 'autoscaling.enabled={{ _gravitee_autoscaling' /mnt/urbalurbadisk/ansible/playbooks/090-setup-gravitee.yml
# Expected: 4

# 5. Chart-values blocks removed.
./uis exec grep -c 'autoscaling:' /mnt/urbalurbadisk/manifests/090-gravitee-config.yaml
# Expected: 0
```

---

## Phase 2: Tester verification

### Tasks

- [x] 2.1 Round 5 brief appended to `talk.md`. ✓
- [x] 2.2 Tester report received: PASS. 4 pods + 0 HPAs default; `-e _gravitee_autoscaling=true` brings 4 HPAs back (not 2 as the brief expected — chart has HPA templates for all four components). Bidirectional flip verified. OQ4 unregressed. ✓

### Validation

Tester confirms:
- Default deploy: 4 pods, 0 HPAs.
- Override probe: with `-e _gravitee_autoscaling=true` (or `DEFAULT_AUTOSCALING=true` flipped in `default-secrets.env` then `./uis secrets generate`), redeploy yields HPAs back.
- Round 3 OQ4 not regressed (`baseURL` still `/management`, management API still 200 at the relative path).

---

## Acceptance Criteria

- [x] `DEFAULT_AUTOSCALING=false` in `default-secrets.env` with a comment block explaining its system-wide nature. ✓
- [x] `service-deployment.sh:deploy_single_service` sources `default-secrets.env` and forwards every `DEFAULT_*` variable as a lowercased ansible extra-var. Comment block documents the convention. ✓
- [x] `090-setup-gravitee.yml` has `_gravitee_autoscaling` mapped from `default_autoscaling` and applies it via four `--set` lines on helm install. Comment documents the pattern. ✓
- [x] `manifests/090-gravitee-config.yaml` has no `autoscaling:` blocks. ✓
- [x] Default `./uis deploy gravitee` produces 4 pods, 0 HPAs. ✓ confirmed by tester
- [x] Override path (`-e _gravitee_autoscaling=true`) re-enables HPAs. ✓ confirmed by tester (4 HPAs come back, not 2 — see Implementation Notes corollary)
- [x] Round 3 OQ4 chart change (relative `ui.baseURL`) still functions — no regression on `constants.json` content or management-API reachability. ✓ confirmed by tester

---

## Files to Modify

- `provision-host/uis/templates/default-secrets.env` — new `DEFAULT_AUTOSCALING=false` line + documentation comment.
- `provision-host/uis/lib/service-deployment.sh` — wrapper sources defaults, passes extra-vars.
- `ansible/playbooks/090-setup-gravitee.yml` — `_gravitee_autoscaling` var + 4 `--set` lines on task 24.
- `manifests/090-gravitee-config.yaml` — remove the four `autoscaling: { enabled: false }` blocks (api, gateway, ui, portal).

---

## Implementation Notes

**Why the wrapper sources the *whole* `default-secrets.env` rather than per-knob plumbing**: future-proofing. When the next system-wide knob lands (e.g. `DEFAULT_REPLICA_COUNT`, `DEFAULT_DEBUG_MODE`, `DEFAULT_LOG_LEVEL`), it's a one-line addition to `default-secrets.env` and a one-line mapping in whichever playbook adopts it. The wrapper change happens once.

**Why ansible extra-vars rather than a vars-file include**: extra-vars have the highest precedence in ansible's variable hierarchy, so a per-deploy `-e` override always wins over both the defaults and any playbook-specified value. Matches existing UIS conventions (`_purge`, `_app_name`, `_url_prefix`).

**Why lowercase mapping (`DEFAULT_AUTOSCALING` → `default_autoscaling`)**: ansible vars are case-sensitive and the community convention is lowercase. The `DEFAULT_` prefix is preserved so playbook readers can grep `default_` to find all system-wide-knob mappings.

**Why chart values are emptied** (vs keeping `autoscaling: { enabled: false }` as a static fallback): single source of truth. With chart values keeping `false` AND `--set false` from the playbook, both say the same thing — but if someone flipped `DEFAULT_AUTOSCALING=true` and forgot to update chart values, the chart values would silently win for direct-helm-invocations. Easier to reason about with one canonical place.

**No separate PR** — folds into next gravitee-config commit per existing maintainer direction.

**Documentation surface** (per maintainer's "remember to document the behavior" directive):
- `default-secrets.env` itself: comment block above `DEFAULT_AUTOSCALING` explaining system-wide intent + how new services adopt it.
- `service-deployment.sh:deploy_single_service`: comment block above the source-defaults code explaining the wrapper's responsibility.
- `090-setup-gravitee.yml`: comment near `_gravitee_autoscaling` referencing the layered pattern.
- `manifests/090-gravitee-config.yaml`: short comment at top of file noting that autoscaling is now driven by `DEFAULT_AUTOSCALING` (rather than chart values).
