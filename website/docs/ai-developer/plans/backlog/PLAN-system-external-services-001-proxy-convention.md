# Plan: ship the external-service proxy that production already runs by hand

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

**Goal**: `uis deploy postgresql` gives an in-cluster PostgreSQL on a laptop and a
transparent proxy to the external one on a production installation — **same
command, same in-cluster address, consumers unchanged** — with the topology
declared in `.uis.extend/` rather than hand-built.

**Last Updated**: 2026-08-13

---

## Dependencies

**Investigation**: [INVESTIGATE-system-external-or-in-cluster-services](./INVESTIGATE-system-external-or-in-cluster-services.md) — EXT-F1, EXT-F2, EXT-F3.

**Prerequisites**: none.

**Blocks**: the OpenBao / registry-cache / backup service plans. All three need
this convention, and three separate answers would never converge.

**Priority**: High

---

## Problem Summary

Principle 0 says every service must run on a developer's laptop, and production
may differ in topology but never in interface. PostgreSQL already lives that
shape — and the mechanism that makes it work is **hand-built, undocumented, and
would not survive a rebuild**.

### What production actually runs (measured 2026-08-13)

`.uis.extend/pg-external-proxy.yaml` on the reference installation deploys, into
`default`, under the name and labels of the real service:

| Piece | Why |
|---|---|
| `Deployment/postgresql`, label `app.kubernetes.io/name=postgresql` | so `SCRIPT_CHECK_COMMAND` and `uis list` work **unchanged** |
| first container `postgres:18`, `sleep infinity` | so playbooks that `kubectl exec` into "the postgres pod" for `psql` work **unchanged** |
| sidecar `alpine/socat` → `10.10.0.105:5432` | forwards to the real database on Odin |
| `Service/postgresql` | so `PGHOST=postgresql.default` resolves **identically** in both topologies |

That last row is the whole trick. Every consumer — openwebui, gravitee, temporal,
unity-catalog, openmetadata — reads `${PGHOST}`, and **none of them change**.
Interface identical, topology different, exactly as Principle 0 requires.

The socat target is deliberately the backplane address (`10.10.0.105`, CT 105 over
`vmbr1`) and **not** the tailnet one: asgard and the database sit on the same
Proxmox host, so this traffic must not depend on WireGuard or on Tailscale's
coordination server being reachable.

### Why this is a problem rather than a success

- It exists only as a file someone wrote by hand on one machine. Rebuild asgard
  and PostgreSQL connectivity is reconstructed from memory.
- `minio-external-proxy.yaml` is the same pattern applied a second time, also by
  hand — so it is a convention already, just an unowned one.
- Nothing in UIS knows the topology differs. `uis list` reports PostgreSQL exactly
  as if it were deployed in-cluster, which is true of the *pod* and false of the
  *database*.
- 14 files sit in that installation's `.uis.extend/`, including `bao-reviewer.yaml`
  and `eso-store.yaml`. This plan productises one pattern; the rest remain
  evidence of how much of the reference installation is hand-built.

**This plan does not design a convention. It ships the one that already works.**

---

## Phase 1: Template the proxy

### Tasks

- [ ] 1.1 `ansible/playbooks/templates/040-postgresql-external-proxy.yml.j2`,
      parametrised by external host and port — the existing multi-instance
      templates are the shape to follow
- [ ] 1.2 Keep all four properties above. Each is load-bearing and each was
      learned the hard way; the template must carry the comments explaining why
- [ ] 1.3 Render it against the reference installation's values and **diff against
      the hand-written file** — the template is correct when the diff is empty

### Validation

Generated output is byte-equivalent to the file production runs today, modulo the
declared values.

---

## Phase 2: Declare the topology

### Tasks

- [ ] 2.1 `.uis.extend/external-services.yaml` — per installation, absent by
      default:

      ```yaml
      postgresql:
        host: 10.10.0.105      # never a secret; addresses are not credentials
        port: 5432
        why: "production database on Odin CT 105, over the vmbr1 backplane"
      ```

- [ ] 2.2 Require `why:` per entry — the rule
      [kuma-005](./PLAN-service-uptime-kuma-005-ship-the-pipeline.md) already
      holds. An external dependency nobody can justify is one nobody maintains,
      and when it breaks the first question is why it was pointed there
- [ ] 2.3 `uis deploy <id>` consults the file: absent ⇒ deploy in-cluster exactly
      as today; present ⇒ render the proxy instead
- [ ] 2.4 **Absent is the default and must stay silent.** A stock laptop install
      declares nothing and never learns this feature exists

### Validation

`uis deploy postgresql` with no file behaves exactly as it does today.

---

## Phase 3: Say which topology is running

### Tasks

- [ ] 3.1 `uis list` / `uis status` distinguish in-cluster from external, showing
      the target address
- [ ] 3.2 `uis verify postgresql` proves the *database* answers, not that a pod is
      Running — the proxy makes those two different claims, and only one matters

### Validation

The output tells the truth about where the data is. Reporting `✅ Deployed` for a
proxy to an unreachable host is the same defect class as Grafana reporting
`✅ Deployed` while absent from `list-enabled`.

---

## Phase 4: Prove both topologies

### Tasks

- [ ] 4.1 **Rancher Desktop**: `uis deploy postgresql` → in-cluster database,
      consumers work
- [ ] 4.2 **Reference installation**: replace the hand-written file with the
      generated one, redeploy, confirm consumers are unaffected
- [ ] 4.3 Delete `.uis.extend/pg-external-proxy.yaml` once the generated form has
      replaced it — two sources for one object is how they drift apart
- [ ] 4.4 Rebuild-from-nothing test on the reference installation: the proxy comes
      back from the declaration alone

### Validation

The same command, run on a laptop and on production, produces a working
PostgreSQL for consumers in both — and neither required a hand-written file.

---

## Out of Scope

- **MinIO**, which has the same hand-built proxy. Deliberately second: prove the
  convention on one service, then migrate the other as its first real test.
- OpenBao, registry cache, backup — they consume this convention, they do not
  define it.
- The other 11 files in the reference installation's `.uis.extend/`.

---

## Note on a wrong turn

This plan was nearly written as "design a mechanism for declaring external
services". Looking at what the reference installation actually runs showed the
mechanism already exists and is better than what would have been designed —
particularly the choice to keep the real service's name, labels and first
container, so that *nothing downstream knows the difference*.

The earlier claim that "asgard runs PostgreSQL in-cluster" was also wrong. That
pod is the proxy; `2/2 Running` is `postgres:18` plus `socat`, not a database.
