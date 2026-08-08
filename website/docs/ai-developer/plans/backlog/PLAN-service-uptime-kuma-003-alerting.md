# Make the watchdog able to wake someone — and watch itself

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Active — alerting is live on the reference installation; two items
outstanding (resend/maintenance windows, and true off-site dead-man cover)

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

- [x] 1.1 **ntfy** (`https://ntfy.sh`) ✓ — free, no account, self-hostable later
      infrastructure. Uptime Kuma ships ~90; realistic options:
      **ntfy** (self-hostable but use the public instance for this),
      **Telegram**, **Pushover**, or plain **SMTP** via an external provider
- [x] 1.2 Configured and tested ✓ — verified twice by deliberately failing a real
      monitor, not just by publishing to the topic directly
- [x] 1.3 **Confirmed on the user's phone 2026-08-08** ✓ — and more strongly than
      this task asks: the user is abroad, so the message arrived with the device
      on a foreign network, nowhere near home Wi-Fi. That is the condition that
      matters — an alert
      that only arrives on the LAN has not been tested
- [x] 1.4 In OpenBao at `platform/uptime-kuma` ✓ (`ntfy_topic`, `ntfy_server`,
      alongside `push_token_salt`). ⚠️ On the public ntfy.sh **the topic name IS
      the credential** — anyone who learns it can read the alerts and publish
      fakes. Self-host or set a topic password before treating it as private

### Validation

Stop a monitored service; confirm the notification arrives on a phone that is
not on the home network.

---

## Phase 2: Sensible thresholds

### Tasks

- [x] 2.1 Infrastructure: `maxretries: 2` ✓
- [x] 2.2 Ollama backends: `maxretries: 3` — **but that is not enough, so they do
      not page at all** (`notify: false`). A 9–16 minute nap at a 60s interval
      clears 3 retries every time. m4-ollama was DOWN while this was written and
      correctly silent. Revisit when the wake/sleep behaviour is settled. The M4 sleeps in 9–16 minute cycles and
      must not page for a nap
- [x] 2.3 Heartbeats notify on first expiry ✓ — the expiry window is itself the
      grace period
- [ ] 2.4 **NOT DONE** — resend is off, so a single missed push means the outage
      scrolls away and is never repeated
- [ ] 2.5 **NOT DONE** — no maintenance-window mechanism, so planned work pages

### Validation

Run for 48 h. Count notifications. **If any were noise, tune before adding
monitors** — an ignored alert channel is worse than none.

---

## Phase 3: Who watches the watchdog

### Tasks

- [x] 3.1 Dead-man's switch ✓ — **implemented the other way round.** Rather than
      Kuma pushing outward to a third party, **Odin** (a different physical
      machine) polls assist every 10 minutes via `watch-assist.timer` and pushes
      to ntfy *directly* when Kuma is unreachable — going through Kuma would be
      pointless when Kuma is what is down. It latches, so one alert plus one on
      recovery. Verified against a closed port.

      ⚠️ **This does not cover a whole-house failure.** Odin and assist watch each
      other; if power or internet goes, both are down and you get silence. True
      cover still needs something off-site — a free external service, or a
      Cloudflare Worker on the account that already exists. Original task text:
      Uptime Kuma pushes a heartbeat to a free
      external service (healthchecks.io or equivalent) on a schedule; that
      service alerts if the push stops. This is the only mechanism that catches
      assist dying, losing power, or losing its internet connection
- [ ] 3.2 Once the in-cluster stack has any rules, add a Prometheus probe of
      Uptime Kuma — deliberate mutual monitoring, the one place duplication is
      correct (investigation F6)
- [x] 3.3 Recovery path documented in `odin-ops/runbooks/odin-platform-runbook.md`
      §7e ✓ — deliberately in a **private GitHub repo**, which is reachable from a
      phone when the house is dark. A runbook that only exists on assist is
      useless in exactly the situation it is for. Original: what to check when the dead-man's switch
      fires, given that by definition the dashboard is unreachable

### Validation

Stop Uptime Kuma. Confirm the external service raises an alert.

---

## Acceptance Criteria

- [x] An outage notification reaches a phone off the home network ✓ — confirmed by
      the user while abroad
- [ ] 48 h of running produces zero false alarms — **clock starts 2026-08-08**
- [x] The M4's sleep cycles are recorded but never page ✓ (recorded; silenced)
- [x] Killing Uptime Kuma raises an external alert ✓ (from Odin; not house-wide)
- [x] Notification credentials are in OpenBao ✓
- [x] The recovery path is written down somewhere reachable when everything is
      down ✓ — private GitHub, readable from a phone

---

## Implementation Notes

**The test that matters is Phase 1.3.** Every other check can pass while the one
that counts — a human being told, while away from home — silently does not work.
That is precisely how the in-cluster stack ended up with Alertmanager and no
rules: each piece looked deployed.

⚠️ **Do not point this at the same place the platform's own alerts will
eventually go.** If both end up in one muted channel, the redundancy built in
`001` and `002` is undone at the last hop.
