# Make the watchdog able to wake someone — and watch itself

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

**Goal**: An alert reaches a human away from home, and the watchdog's own death
is detectable.

**Investigation**: [INVESTIGATE-service-uptime-kuma.md](./INVESTIGATE-service-uptime-kuma.md)
**Prerequisites**: `PLAN-service-uptime-kuma-002-monitors.md`

**Priority**: High — without this the whole thing is a dashboard nobody is looking at

**Last Updated**: 2026-08-07

---

## Problem

The in-cluster stack has Alertmanager deployed and **zero rules**: monitoring
that cannot notify anyone. Repeating that with a second system would be worse,
because the dashboard makes it *look* covered.

Two specific gaps to close:

1. **Notification must survive the thing being monitored.** A channel that
   depends on the home network is useless for "the home network is down".
2. **The watchdog itself is unmonitored** (investigation F6). The orphaned CNPG
   replica reported "healthy" for 82 days — the exact shape of this failure.

---

## Phase 1: A channel that works from elsewhere

### Tasks

- [ ] 1.1 Pick a notification provider that does not depend on home
      infrastructure. Uptime Kuma ships ~90; realistic options:
      **ntfy** (self-hostable but use the public instance for this),
      **Telegram**, **Pushover**, or plain **SMTP** via an external provider
- [ ] 1.2 Configure it and send a test
- [ ] 1.3 **Verify from a phone on mobile data, with home Wi-Fi off.** An alert
      that only arrives on the LAN has not been tested
- [ ] 1.4 Store the credential in OpenBao rather than only in Kuma's database

### Validation

Stop a monitored service; confirm the notification arrives on a phone that is
not on the home network.

---

## Phase 2: Sensible thresholds

### Tasks

- [ ] 2.1 Infrastructure (Odin, asgard, pg, minio): notify after **2** failures
- [ ] 2.2 Ollama backends: after **3** — the M4 sleeps in 9–16 minute cycles and
      must not page for a nap
- [ ] 2.3 Heartbeats: notify on **first** expiry; the expiry window is itself the
      grace period
- [ ] 2.4 Enable resend so an unacknowledged outage nags rather than scrolls away
- [ ] 2.5 Set a maintenance window mechanism for planned work

### Validation

Run for 48 h. Count notifications. **If any were noise, tune before adding
monitors** — an ignored alert channel is worse than none.

---

## Phase 3: Who watches the watchdog

### Tasks

- [ ] 3.1 Add a **dead-man's switch**: Uptime Kuma pushes a heartbeat to a free
      external service (healthchecks.io or equivalent) on a schedule; that
      service alerts if the push stops. This is the only mechanism that catches
      assist dying, losing power, or losing its internet connection
- [ ] 3.2 Once the in-cluster stack has any rules, add a Prometheus probe of
      Uptime Kuma — deliberate mutual monitoring, the one place duplication is
      correct (investigation F6)
- [ ] 3.3 Document the recovery path: what to check when the dead-man's switch
      fires, given that by definition the dashboard is unreachable

### Validation

Stop Uptime Kuma. Confirm the external service raises an alert.

---

## Acceptance Criteria

- [ ] An outage notification reaches a phone on mobile data with home Wi-Fi off
- [ ] 48 h of running produces zero false alarms
- [ ] The M4's sleep cycles are recorded but never page
- [ ] Killing Uptime Kuma raises an external alert
- [ ] Notification credentials are in OpenBao
- [ ] The recovery path is written down somewhere reachable when everything is down

---

## Implementation Notes

**The test that matters is Phase 1.3.** Every other check can pass while the one
that counts — a human being told, while away from home — silently does not work.
That is precisely how the in-cluster stack ended up with Alertmanager and no
rules: each piece looked deployed.

⚠️ **Do not point this at the same place the platform's own alerts will
eventually go.** If both end up in one muted channel, the redundancy built in
`001` and `002` is undone at the last hop.
