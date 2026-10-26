# Investigate: sitespeed.io for page-speed testing, user journeys, CI gating and monitoring

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog — investigation only, per explicit instruction (`urb-agents#2036`)

**Not to be built from this document without a separate decision and PLAN.** Terje's own
words: "Ask tor-agent to look into it, but not implement it now."

**Goal**: answer whether sitespeed.io (engine: Browsertime) fits UIS for four related but
separable uses — page-speed/visual-metrics testing, scripted user journeys, CI/CD budget
gating, and recurring synthetic monitoring — and what each would actually cost to build.

**Related**: `urb-agents#2036` (the request, including Terje's own five numbered questions,
answered in Part 3 below)

**Created**: 2026-10-26

---

## Background

The request came from comparing page-load speed fairly across a single-page app and a
server-rendered app — a stopwatch isn't fair there, a video-derived "visually complete" metric
is. That specific comparison is the requester's own use, not UIS's; this document is about
whether the underlying tool is worth adopting as UIS capability, independent of that one
motivating case.

## Part 1: What already exists that this can build on

### F1 — Prometheus already has a live, working Pushgateway

`ansible/playbooks/030-setup-prometheus.yml` deploys Prometheus with
`pushgateway.enabled: true` and its own install-time test proves data ingestion works
(`prometheus-prometheus-pushgateway.monitoring.svc.cluster.local:9091`, a real push verified
during setup). This matters because sitespeed.io has **no native Prometheus export** (see F-sitespeed-2
below) — a bridge would push into this already-proven endpoint, not stand up new
infrastructure.

### F2 — Garage (S3-compatible object storage) already exists as a UIS service

`provision-host/uis/services/storage/service-garage.sh`. sitespeed.io's HTML reports and
per-page videos need somewhere to live; Garage is the obvious target if its endpoint
override works the way the "Open questions" section below needs it to (unconfirmed, not
assumed).

### F3 — A proven pattern for seeded test-user credentials already exists in Authentik

`manifests/073-authentik-1-test-users-groups-blueprint.yaml` creates real test users with
known usernames/passwords (`ok1`/`re1`/`it1`/… with full group membership) specifically so
automated tooling can sign in without a human credential. This directly answers half of
Terje's question 5 (sign-in for UIS's own services) — the mechanism already exists, this
would reuse it, not invent one.

### F4 — No existing UIS service is shaped as a Job/CronJob

Every `uis deploy <service>` today is a long-running Deployment or StatefulSet (checked:
`grep -rl 'kind: CronJob' manifests/` returns nothing, and `adding-a-service.md` never
mentions a batch/one-shot shape). sitespeed.io itself has **no persistent/server mode at all**
— it is a one-shot CLI invocation that exits (see Part 2). A scheduled-monitoring use of it
would be the **first** CronJob-shaped UIS service, not a variation on an existing pattern —
this is a platform-level gap, not a sitespeed.io-specific one.

## Part 2: What this is NOT

- **Not a replacement for Uptime Kuma.** Uptime Kuma answers "is it up" cheaply and
  continuously; sitespeed.io answers "how fast does it feel to a real browser," at a much
  higher per-check cost (a real Chrome launch, several page loads, video encoding). Different
  question, different cost, complementary rather than overlapping.
- **Not a replacement for Prometheus/Grafana.** sitespeed.io would feed metrics *into* that
  existing stack (via a bridge — see Open Questions), not duplicate it.
- **For the CI/CD use (Terje's question 3) this may not need to be a "UIS service" at all.**
  Running the Docker image directly as a workflow step against a freshly-deployed URL, with a
  budget file, needs no cluster-resident component — it is CI tooling, not something
  `uis deploy` would ever install.

## Part 3: Terje's five questions, answered

### 1. sitespeed.io as a UIS service

Confirmed from source (see citations in Open Questions / sitespeed.io docs below): the image
is `sitespeedio/sitespeed.io`, runs as a one-shot CLI command (not a server), needs
`--shm-size=1g` (Chrome) because the container default `/dev/shm` (64 MiB) is too small and
causes Chrome crashes — the exact same class of failure this repo already fixed for Authentik
(`urb-agents#2021`), so that lesson transfers directly if this is ever built. It would **not**
fit the existing Deployment-shaped `uis deploy` pattern (F4) — it is fundamentally a Job
(CI) or CronJob (monitoring), and CronJob support doesn't exist in UIS yet.

### 2. User journeys as scripts

Real and documented: Browsertime's own scripting API (navigate/click/type/wait helpers,
including a documented login-form example). "One journey per app, kept with the app" (Terje's
own framing) matches this well — a script is naturally scoped to one app's pages, the same
way this repo already keeps a service's manifests/blueprints next to that service's own
definition.

### 3. CI/CD

Real feature: a JSON performance-budget file, non-zero exit on a budget failure. No official
GitHub Action exists — every example invokes the Docker image directly inside a workflow
`run:` step, which matches how this repo already prefers direct tool invocation in its own
CI over marketplace actions where practical. This is the lowest-risk, most self-contained of
the four uses — it needs nothing beyond a workflow step and a budget file, no new UIS
service, no new infrastructure.

### 4. Monitoring

The harder one. This needs F4's gap (no CronJob-shaped UIS service exists) resolved first,
plus a real Prometheus bridge (sitespeed.io has no native Prometheus export — see Open
Questions) and a confirmed Garage-compatible storage path for the reports/videos. A real
synergy worth noting: the *same* journey script written for CI gating (question 3) could be
reused unchanged for scheduled monitoring, just on a different trigger (a deploy event vs. a
schedule) — one script, two consumers, not two things to build and maintain.

### 5. Sign-in for journeys

**Splits cleanly by audience, and only half of it is solved:**

- **UIS's own services** (behind Authentik): solved by reuse, not new design — F3's existing
  test-user blueprint pattern provides real credentials a journey script can log in with, the
  same way `test-users-groups-blueprint` already exists for exactly this class of purpose.
- **An external identity provider the journey doesn't control** (the case that motivated this
  request): Terje described reusing a browser profile a human signed into by hand once, so no
  credential ever lives in a script. **This specific mechanism is not confirmed as a
  sitespeed.io feature** — the tool's own documented login pattern is the opposite: a
  `preScript` that logs in fresh *before every single measured run*, which does put a
  credential in the script. A persistent authenticated profile might still be reachable via
  raw Chrome launch flags (`--user-data-dir` is a real Chrome flag, and Browsertime allows
  passing through arbitrary Chrome options) — but this is plausible, not verified, and is a
  materially different, untested claim from what's actually documented. Flagging as a real
  gap between what Terje described and what the tool is confirmed to support, not quietly
  assuming it works.

## Open questions — explicitly not decided here

1. **The Prometheus bridge does not exist and must be custom-built.** sitespeed.io exports
   natively to Graphite only (confirmed: `--graphite.host`/`.port`/`.namespace`); there is no
   Prometheus or Pushgateway integration, native or via a known plugin. The realistic design is
   a small script parsing sitespeed.io's own JSON result output and pushing selected metrics to
   the Pushgateway F1 already proves works — not standing up a second metrics stack (Graphite)
   next to Prometheus just to satisfy this one tool. Not designed here, not sized here.
2. **Whether Garage actually accepts a custom S3 endpoint from sitespeed.io is unconfirmed.**
   The CLI flags (`--s3.bucketname`/`.key`/`.secret`/`.region`) are real and documented; a
   custom non-AWS `endpoint` only appears in a JSON config example (for DigitalOcean Spaces),
   not confirmed as an equivalent CLI flag. Needs a hands-on check against a real Garage
   instance before this is assumed to work — explicitly implementation work, out of scope
   here.
3. **No CronJob-shaped UIS service exists yet (F4).** Scheduled monitoring specifically needs
   this platform capability decided and designed before it can be built — bigger than this
   investigation, and bigger than sitespeed.io itself (any future scheduled-job UIS service
   would hit the same gap).
4. **The persistent-authenticated-browser-profile mechanism for an external IdP is unconfirmed**
   (see question 5 above) — needs either confirming the Chrome-flags-passthrough path works in
   practice, or accepting the documented fresh-login-per-run pattern instead (which the
   requester specifically wanted to avoid, for credential-handling reasons).
5. **Iteration count is a real tension between the CI and monitoring uses.** sitespeed.io
   defaults to 3 runs/page for a stable median; its own docs suggest 5+ for noisier pages. A
   CI gate wants fast feedback on every deploy; a monitoring run can afford to be slower and
   more iterations for a steadier trend line. Not reconciled here — a future PLAN would need to
   pick (possibly different) iteration counts for each use.

## Part 4: Recommendation

Worth pursuing, but as two separable efforts with very different cost and risk, not one PLAN:

- **CI/CD budget gating (question 3) is the cheap, low-risk starting point** if this gets
  picked up at all: a workflow step plus a budget file, no new UIS service, no new
  infrastructure, nothing blocked on the open questions above. Could be its own small PLAN
  independent of everything else here.
- **Scheduled monitoring (question 4) is materially bigger**: it is blocked on a platform-level
  gap (no CronJob-shaped UIS service exists), a metrics bridge that must be built from
  scratch (no native Prometheus support), and an unconfirmed storage integration. This
  deserves its own PLAN only after those three things are each individually resolved or at
  least sized — not bundled into a single "add sitespeed.io" effort.
- **The sign-in question needs Terje to decide, not guess**: UIS's own services are a solved
  case (reuse F3); the external-IdP / persistent-profile case described for the original
  motivating comparison may need a different approach than the one described, since that
  mechanism isn't confirmed to exist in sitespeed.io itself.

## Honest limits of what's in this document

No code has been written and no cluster was used to verify anything here — same standing
caveat as every other `platforms/` and service INVESTIGATE document in this repository. F1-F4
are read from this repository's own existing, merged code and docs, not guessed. Everything
about sitespeed.io itself is sourced from its own official documentation
(sitespeed.io/documentation/sitespeed.io/ — installation, docker, graphite, s3, scripting,
performance-budget, continuous-integration, and configuration pages), with the specific gaps
called out above (the S3 custom-endpoint CLI flag, and the persistent-profile login mechanism)
flagged as unconfirmed rather than asserted.
