# Define what the watchdog watches

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Active — all 19 monitors defined and reconciling; **nothing notifies
anyone yet, and no monitor has been seen to go red**

**How they are defined changed.** When this plan was written the assumption was
monitors created in the UI. They are now declared in
`odin-ops/monitoring/monitors.yaml` (private repo, installation-specific) and
reconciled into Kuma by AutoKuma. Adding a monitor is an edit to that file, not a
click. The product-side path for this is
[PLAN-system-observability-006-service-probes](../backlog/PLAN-system-observability-006-service-probes.md).

**Goal**: Every incident from the investigation's F1 table would be caught, and
nothing is monitored twice for the sake of it.

**Investigation**: [INVESTIGATE-service-uptime-kuma.md](../backlog/INVESTIGATE-service-uptime-kuma.md)
**Prerequisites**: [PLAN-service-uptime-kuma-001-deploy.md](./PLAN-service-uptime-kuma-001-deploy.md)

**Priority**: High

**Last Updated**: 2026-08-08

---

## Problem

A watchdog with the wrong monitors is worse than none: it produces confidence
without coverage. The monitor set must be derived from failures that actually
happened, not from what is easy to probe.

## Principle

> Probe the **thing a user depends on**, not the process that provides it.

A pod being `Running` is the in-cluster stack's job. Whether the endpoint answers
is this one's.

---

## Phase 1: Hosts and infrastructure

### Tasks

- [x] 1.1 Odin host — Proxmox UI (TCP 8006) ✓ `odin-proxmox-ui`
- [x] 1.2 `asgard` — the k3s API (TCP 6443) ✓ `asgard-k3s-api`. **This is the one
      the in-cluster stack structurally cannot report** (investigation F3)
- [x] 1.3 `pg` — TCP 5432 ✓ `pg-postgresql`, but **via the LAN address
      `192.168.68.62`, not the backplane `10.10.0.105`**. The backplane is
      host-only to Odin; the watchdog deliberately runs outside Odin and cannot
      reach it. Any monitor of an Odin guest has to use LAN or tailnet — the
      deviation is inherent to being an external watchdog, not an oversight
- [x] 1.4 `minio` — HTTP `/minio/health/live` ✓ `minio-s3`
- [x] 1.5 `bao` — HTTPS `/v1/sys/health` ✓ `bao-vault`, sealed treated as DOWN
      (`accepted_statuscodes: 200-299`; a sealed vault answers 503). Two things
      this plan did not anticipate:
      **(a)** it is HTTPS with an internal self-signed cert — plain `http`
      returns 400, which reads as a broken vault rather than a misconfigured
      probe, so `ignore_tls` was needed;
      **(b)** bao's nftables ruleset blocked assist entirely. assist was added to
      the allow-list by **both MAC and IP** (`wlan0`, not `eth0` — reading the
      wrong interface cost a debugging round). Recorded in
      `odin-ops/runbooks/odin-platform-runbook.md`
- [x] 1.6 `registry` — HTTP `/v2/` ✓ `registry-cache`
- [x] 1.7 `nas` — TCP 445 ✓ `nas-smb`

### Validation

⏳ **Not done.** Stop one guest deliberately; confirm it goes red and recovers.
All seven report UP, which proves the probe reaches something — it does **not**
prove the probe would notice failure. Until one has been seen red, this is
untested in the direction that matters.

---

## Phase 2: Services users actually reach

### Tasks

- [x] 2.1 LiteLLM `GET /v1/models` with the API key ✓ `litellm-gateway`, keyword
      `gemma3`, Authorization header resolved at render time from a gitignored
      secret file — **never in the YAML**. The `auth_header_secret` field was
      declared in the schema before it was implemented, so the monitor sat at 401
      for a while: a monitor that is DOWN for probe reasons is noise that trains
      you to ignore it
- [x] 2.2 Grafana, Temporal Web, Authentik via tailnet hostnames ✓ — `grafana`
      (keyword `database` on `/api/health`), `temporal-web`, `authentik`
      (`/-/health/live/`). **MinIO console is NOT monitored** — only the S3 API
      via 1.4. The console is a UI over the same process; if 1.4 is UP the
      console being down is a Traefik/ingress fault, which is worth a monitor but
      was not added
- [x] 2.3 Home Assistant on assist itself ✓ `home-assistant`

### Validation

⏳ **Not done** — same gap as Phase 1. Nothing has been stopped on purpose.

---

## Phase 3: The Ollama backends

### Tasks

- [x] 3.1 M1 `/api/version` via `192.168.68.70` ✓ `m1-ollama`
- [x] 3.2 M4 `/api/version` via `192.168.68.58` ✓ `m4-ollama`. **Tailnet address
      still pending** — it is on DHCP and not on the tailnet yet, so this URL
      changes when it moves after the holiday
- [x] 3.3 Both set to `maxretries: 3` ✓ — though with no notification channel
      configured, "notify after 3 failures" currently means nothing. The setting
      is right; the mechanism it feeds does not exist yet

### Validation

The M4 sleeps in 9–16 minute cycles (investigation F1). These monitors must
record that pattern without paging for every nap.

⏳ **24 h review not done** — and the history was wiped by the purge/rebuild on
2026-08-08, so the clock restarts from then.

⚠️ **Still undecided: probing every 60s may keep a Mac awake** — the same side
effect `ollama-endpoint-manager` has. Both Macs have read UP continuously, which
is *weak evidence the probe is doing exactly that*: a sleeping Mac should have
produced DOWN beats by now, and none have appeared. Worth checking before
treating these two monitors as free.

---

## Phase 4: Heartbeats — the capability nothing else provides

These catch *absence of work*, which metrics handle badly (investigation F4).

### Tasks

- [x] 4.1 Push monitor **`enrichment-worker`**, expiry 15 min ✓ created
- [x] 4.2 Push monitor **`pg-dump`**, expiry 26 h ✓ created
- [x] 4.3 Push monitor **`vzdump`**, expiry 26 h ✓ created
- [x] 4.4 Push monitor **`restic-offsite`**, expiry 26 h ✓ created
- [x] 4.5 Push monitor **`pgbackrest`**, expiry 26 h ✓ created
- [ ] 4.6 **NOT DONE — this is the gap that matters.** No job calls its push URL.
      All five monitors exist with working tokens and are simply waiting. Until
      4.6 lands, Phase 4 delivers **nothing**: the 8.4-hour stall this exists to
      catch would still go unnoticed, and 4.1 will read DOWN forever rather than
      "no data", which is noise that teaches you to ignore it.
      Add the call **after** each job's success check, so a failed job cannot
      report success

### Validation

⏳ Blocked on 4.6. One push has been tested by hand — `HTTP 200`, monitor went
UP — so the URLs work; nothing calls them on a schedule.

⚠️ **Push tokens are derived, not random**: `HMAC-SHA256(salt, monitor name)`.
A purge-and-rebuild therefore reissues **identical** URLs, so whatever is wired
in 4.6 keeps working across a rebuild. Verified over two full cycles. The salt is
in OpenBao at `platform/uptime-kuma`; losing it silently orphans every caller.

> 26 h rather than 24 h leaves headroom for a late run without a false alarm —
> and note the daylight-saving hazard recorded in the backup investigation:
> avoid expiries that straddle 02:00–03:00 local.

---

## Acceptance Criteria

- [ ] Every row of the investigation's F1 table would now be caught — **not yet.**
      The infrastructure and service rows would; the *absence-of-work* rows (the
      8.4-hour stall) would not, because no job pushes a heartbeat (4.6)
- [x] No monitor duplicates something the in-cluster stack does better
- [ ] Backup and pipeline heartbeats are live — **no.** The monitors exist; no
      caller does
- [ ] The M4's sleep cycles are visible but do not page — vacuously true, since
      **no notification channel exists at all**
      ([PLAN-service-uptime-kuma-003-alerting](../backlog/PLAN-service-uptime-kuma-003-alerting.md))
- [ ] Each monitor has been seen to go red at least once — **none has**

⚠️ **Read the state honestly: 14 monitors are UP, 5 are waiting for a caller, and
nothing pages anyone.** A dashboard of green with no notification channel is the
same failure this plan exists to fix, one level up — *absence renders as green*,
including the absence of alerting. 003 is the blocker on this being real.

---

## Implementation Notes

**Probe from outside, by the address users use.** Monitoring `pg` on the
backplane checks the database; monitoring it via the shim would also exercise the
path that Temporal and Authentik depend on. Both are defensible — 1.3 chooses the
database itself, because the shim is covered indirectly by the service monitors
in Phase 2.

**Keyword matching matters more than status codes.** The LiteLLM case is the
proof: HTTP 200 with a broken database.
