# Package Uptime Kuma as a first-class UIS service

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Completed

**Goal**: `./uis deploy uptime-kuma` works like any other service, with the same
metadata, lifecycle, verify tests and docs.

**Investigation**: [INVESTIGATE-service-uptime-kuma.md](./INVESTIGATE-service-uptime-kuma.md)
**Supersedes**: the hand-written manifest from
`PLAN-service-uptime-kuma-001-deploy.md`, which was applied directly with
`kubectl` and is not reproducible through UIS.

**Priority**: Medium

**Last Updated**: 2026-08-07

**Completed**: 2026-08-07

---

## Problem

The watchdog was deployed by hand: a single YAML applied with `kubectl`, living
in `hosts/assist/`. It works, but it is the only service on the platform that
cannot be deployed, removed, verified, listed or documented the way every other
service can. That makes it a special case for anyone who inherits it.

## Solution

Follow [adding-a-service.md](../../../contributors/guides/adding-a-service.md)
in full. Uptime Kuma has no official Helm chart and uses embedded SQLite, so it
is the **StatefulSet pattern** (guide Step 5c) — the same shape as Enonic XP.

| Decision | Value | Why |
|---|---|---|
| `SCRIPT_ID` | `uptime-kuma` | |
| Category | `OBSERVABILITY` | it is monitoring; see the caveat below |
| Manifest number | **230** | `230-239` is entirely unused |
| Namespace | `monitoring` | alongside the rest of the observability stack |
| Pattern | StatefulSet + PVC + Service | no maintained Helm chart, embedded SQLite |
| Image | `louislam/uptime-kuma:2.5.0` | pinned; arm64 and amd64 both published |

### ⚠️ The category is a compromise, and the service must say so

Grouping it with Prometheus/Grafana/Loki is taxonomically right — it is
observability tooling — but those all run *inside* the cluster, and this one
**must not**. A watchdog inside the thing it watches cannot report that thing
being down (investigation F3).

`./uis deploy uptime-kuma` will happily install it on the cluster it is meant to
watch, and **UIS has no way to express "deploy this somewhere else"**. That is
finding F8 made concrete. Until UIS can model it, the constraint lives in the
service description, the docs page and the playbook output — which is weaker
than a mechanism, and should be called out as such rather than papered over.

---

## Phase 1: Service definition and manifests

### Tasks

- [x] 1.1 `provision-host/uis/services/observability/service-uptime-kuma.sh` —
      full metadata block, `SCRIPT_DESCRIPTION` carrying the "runs outside the
      monitored cluster" warning
- [x] 1.2 `manifests/230-uptime-kuma-statefulset.yaml` — PVC + StatefulSet +
      ClusterIP Service, image pinned, `Recreate`-equivalent semantics
- [x] 1.3 `manifests/230-uptime-kuma-ingressroute.yaml` — Traefik `HostRegexp`
      so it works across localhost, Tailscale and Cloudflare unchanged

### Validation

```bash
kubectl apply --dry-run=client -f manifests/230-uptime-kuma-statefulset.yaml
kubectl apply --dry-run=client -f manifests/230-uptime-kuma-ingressroute.yaml
./uis list | grep uptime-kuma
```

---

## Phase 2: Lifecycle playbooks

### Tasks

- [x] 2.1 `ansible/playbooks/230-setup-uptime-kuma.yml` — namespace, apply
      manifests, wait for Ready, print access instructions **and the
      outside-the-cluster warning**
- [x] 2.2 `ansible/playbooks/230-remove-uptime-kuma.yml` — remove workload and
      IngressRoute; PVC removal opt-in via `remove_pvc`, since it holds the
      monitor history
- [x] 2.3 Schema/readiness verification in setup rather than an unconditional
      success message — the lesson from
      `PLAN-service-litellm-001-schema-verify.md`

### Validation

```bash
./uis deploy uptime-kuma && ./uis status | grep uptime-kuma
./uis undeploy uptime-kuma
```

---

## Phase 3: Verify tests

### Tasks

- [x] 3.1 `ansible/playbooks/230-test-uptime-kuma.yml` — health endpoint,
      Traefik routing, and that the data volume is actually mounted
- [x] 3.2 Register in `VERIFY_SERVICES` in `provision-host/uis/lib/integration-testing.sh`
- [x] 3.3 Add the `cmd_verify` dispatch case in `provision-host/uis/manage/uis-cli.sh`

### Validation

```bash
./uis verify uptime-kuma
```

---

## Phase 4: Registration and docs

### Tasks

- [x] 4.1 Commented entry in `provision-host/uis/templates/uis.extend/enabled-services.conf.default`
- [x] 4.2 `website/docs/services/observability/uptime-kuma.md`
- [x] 4.3 Add to `website/sidebars.ts`
- [ ] 4.4 `cd website && npm run build` — NOT RUN: no Node toolchain on this host

### Validation

Docs build clean; the service page renders.

---

## Acceptance Criteria

- [ ] `./uis deploy uptime-kuma` deploys it — files complete and validated, not yet run against a cluster
- [ ] `./uis undeploy uptime-kuma` removes it, keeping the PVC by default
- [ ] `./uis list` and `./uis status` show it
- [ ] `./uis verify uptime-kuma` passes
- [x] Docs page written and linked from `sidebars.ts` (build not run — see 4.4)
- [x] Image pinned to 2.5.0, no `:latest`
- [x] The "must run outside the monitored cluster" warning appears in the
      service metadata, the docs page and the deploy output

---

## Implementation Notes

**No secrets needed.** Uptime Kuma creates its admin account through a
first-run wizard and stores it in its own SQLite database. Nothing goes in
`urbalurba-secrets`, so guide Step 7 is skipped — worth stating, because its
absence otherwise looks like an oversight.

**Storage differs by target.** The assist deployment uses a static PV because
that cluster's `local-path-usb` StorageClass is broken (see
`PLAN-service-uptime-kuma-001-deploy.md`). The UIS service should use the
cluster's default StorageClass like every other service, and leave host-specific
storage to host-specific overrides.

**The existing assist deployment is not migrated by this plan.** It keeps
running as-is. Converting it is a separate decision, because assist's k3s is not
a UIS-managed cluster.

---

## Files to Modify

- `provision-host/uis/services/observability/service-uptime-kuma.sh` (new)
- `manifests/230-uptime-kuma-statefulset.yaml` (new)
- `manifests/230-uptime-kuma-ingressroute.yaml` (new)
- `ansible/playbooks/230-setup-uptime-kuma.yml` (new)
- `ansible/playbooks/230-remove-uptime-kuma.yml` (new)
- `ansible/playbooks/230-test-uptime-kuma.yml` (new)
- `provision-host/uis/lib/integration-testing.sh`
- `provision-host/uis/manage/uis-cli.sh`
- `provision-host/uis/templates/uis.extend/enabled-services.conf.default`
- `website/docs/services/observability/uptime-kuma.md` (new)
- `website/sidebars.ts`
