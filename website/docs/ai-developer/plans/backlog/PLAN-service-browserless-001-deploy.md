# Ship browserless as a UIS service, and open an AUTOMATION category for it

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog — ⚠️ AWAITING TERJE'S APPROVAL of name, category and scope

**Decision already made (Terje, 2026-08-21)**: the browser platform becomes a UIS
service. Not reopened here.

**Proposed by the maintainer, for Terje to approve or change** — nothing in this
plan is self-approved:

| Decision | Proposal |
|---|---|
| Service name | `browserless` (upstream name) |
| Category | **`AUTOMATION`** — new, this is its first service |
| Manifest range | **400–429**, with 430–499 reserved for future automation services |
| Priority | `25` (before uptime-kuma at 30) |
| Scope | This plan ships **browserless only**. `neko` is a separate, separately-approvable plan |

**Handoff**: `ai-developer/for-uis-maintainer-browser-service.md` (home repo, ops
→ maintainer, 2026-08-21). Everything is built and proven on the reference
installation; this plan productises it.

**Companion**: [PLAN-service-neko-001-optional-addon](./PLAN-service-neko-001-optional-addon.md)
— the second half of the platform, deliberately split out. Approve or decline
independently.

**Last Updated**: 2026-08-21

**Priority**: Medium

---

## Problem

### UIS ships a service with a dependency it cannot satisfy

UIS ships Uptime Kuma (see [PLAN-service-uptime-kuma-001-deploy](../active/PLAN-service-uptime-kuma-001-deploy.md),
[002-monitors](../active/PLAN-service-uptime-kuma-002-monitors.md)). Uptime Kuma
has a `real-browser` monitor type. Verified in upstream source
(`server/monitor-types/real-browser-monitor-type.js`):

```js
async function getRemoteBrowser(remoteBrowserID, userId) {
    ...
    browser = await chromium.connect(remoteBrowser.url);
```

It needs either a Chrome binary inside its own container or a **remote browser
URL**. The image UIS deploys has no Chrome. **So that monitor type is dead in
every UIS installation today** — present in the UI, unusable.

browserless is exactly the remote browser it wants. Verified in upstream source
(`src/shared/chromium.playwright.ws.ts`) that it serves the Playwright websocket
routes `chromiumPlaywright` / `playwrightChromium` — so
`chromium.connect("ws://browserless.browser.svc.cluster.local:3000/chromium/playwright?token=…")`
is the whole integration.

⚠️ **Precision that will otherwise cost a day**: Uptime Kuma uses Playwright's
`connect()` (Playwright server protocol), **not** `connectOverCDP()`. Browserless
serves both, on different paths. Agent tooling (`@playwright/mcp`) uses the CDP
path; Uptime Kuma uses the Playwright path. Wire the right one to the right
consumer.

### Nothing in UIS can assert that a page renders

UIS's existing "E2E tests" are API-level — push a log to Loki and read it back,
send a trace to Tempo and query it. Valuable, and not the same thing. No UIS
installation can currently answer *"does the login page actually render for a
human?"* for any of the ten-plus services it ships with a web UI (Grafana,
Authentik, Backstage, ArgoCD, OpenWebUI, pgAdmin, Gravitee, Nextcloud,
RedisInsight, OpenMetadata).

This gap has already bitten. OBS-F6 — the flaky Grafana E2E race — is a test
asserting on API responses because asserting on the rendered dashboard was not
possible.

---

## The second-user test

Applying the rule from
[INVESTIGATE-system-roaming-dependency-addresses](./INVESTIGATE-system-roaming-dependency-addresses.md):
*"the pattern generalises" ≠ "another installation would use it."*

**browserless passes, and not on speculation.** The argument does not rest on
"someone might want browser automation." It rests on a **concrete unmet
dependency in a service UIS already ships**: every installation running Uptime
Kuma has a monitor type it cannot use, and this is the missing piece. Synthetic
monitoring and rendered-page assertions follow from the same deployment.

It also passes the Rancher Desktop test properly — not merely "it runs there,"
but *it is useful there*: a developer authoring a browser check against an
in-cluster service needs a browser in the cluster, on the laptop exactly as on
the server.

---

## Phase 1: Open the AUTOMATION category

browserless is its first inhabitant, so the category lands with it.

### Tasks

- [ ] 1.1 Add `AUTOMATION` to the category list in `CLAUDE.md` and `AGENTS.md`,
      with manifest range **400–429** (browserless), 430–499 reserved
- [ ] 1.2 Add the category to `services.json` / the docs-site navigation and the
      services page grouping
- [ ] 1.3 Create `provision-host/uis/services/automation/`
- [ ] 1.4 Write the category description: *"Browser automation, synthetic checks,
      and agent tooling"* — the umbrella term "the browser platform" is a
      **category description, not a service name**

### Validation

```bash
./uis list                 # AUTOMATION appears, empty until Phase 2
```

Docs site builds with the new category present and no broken links.

---

## Phase 2: The service definition and manifests

### Tasks

- [ ] 2.1 `provision-host/uis/services/automation/service-browserless.sh` —
      `SCRIPT_ID="browserless"`, `SCRIPT_CATEGORY="AUTOMATION"`,
      `SCRIPT_NAMESPACE="browser"`, `SCRIPT_PRIORITY="25"`,
      `SCRIPT_KIND="Component"`, `SCRIPT_TYPE="service"`, `SCRIPT_REQUIRES=""`
- [ ] 2.2 `manifests/400-browserless-config.yaml` — Deployment + Service,
      **pinned image tag** (`ghcr.io/browserless/chromium`), no `:latest`
- [ ] 2.3 Token from `urbalurba-secrets` via `secretKeyRef` only — never a
      literal, never a default that ships as a real value
- [ ] 2.4 LocalDev default for the token in `00-common-values`, so Rancher
      Desktop is **zero-config**
- [ ] 2.5 Resource requests/limits — a Chromium pool is memory-hungry and will
      otherwise evict things on a laptop
- [ ] 2.6 `SCRIPT_CHECK_COMMAND` against the pod, and a remove playbook

### Validation

```bash
./uis deploy browserless
./uis status browserless
```

A first deploy on Rancher Desktop needs no secret setup and no manual step.

---

## Phase 3: Prove both consumers

The two paths are different protocols on different routes; both must be shown to
work or the service is half-delivered.

### Tasks

- [ ] 3.1 **Playwright path** — register browserless as a Remote Browser in
      Uptime Kuma and make one `real-browser` monitor go green against an
      in-cluster service. This is the product story; it must be demonstrated,
      not asserted
- [ ] 3.2 **CDP path** — `@playwright/mcp --cdp-endpoint http://…:3000` connects
      and drives a page (the agent-tooling story from the handoff)
- [ ] 3.3 Verify playbook `NNN-test-browserless.yml`, reached through
      `uis verify` — per [PLAN-service-grafana-deploy-gate-fix](./PLAN-service-grafana-deploy-gate-fix.md)
      Phase 4, E2E belongs in a verify playbook, **not** on the deploy gate
- [ ] 3.4 Confirm the verify playbook is actually registered and runs — the
      exact defect [PLAN-cli-verify-registration-fix](./PLAN-cli-verify-registration-fix.md)
      exists for. Do not repeat it here

### Validation

Uptime Kuma shows a green browser-based monitor. `uis verify browserless` runs
and reports real numbers.

---

## Phase 4: Exposure, security and docs

### Tasks

- [ ] 4.1 Exposure differs by environment, the pod does not — same
      interfaces-over-backends rule as secrets. Rancher Desktop: localhost /
      Traefik. Proxmox: keep the reference installation's manifest as the
      documented example. Cloud: out of scope, say so
- [ ] 4.2 Carry the security model over verbatim from `platform/browser/README.md`
      (home repo): private-network-only, and **why**
- [ ] 4.3 Service docs page: the tool-choice ladder (plain HTTP → browserless →
      neko), so users pick the cheapest tool that works
- [ ] 4.4 Document the Uptime Kuma Remote Browser recipe as the headline use

### Validation

Docs build. A reader can go from `uis deploy browserless` to a green browser
monitor without reading this plan.

---

## Acceptance Criteria

- [ ] Terje has approved the name, category and scope **before** Phase 1 starts
- [ ] `uis deploy browserless` works on Rancher Desktop with no secret setup
- [ ] An Uptime Kuma `real-browser` monitor runs green against an in-cluster service
- [ ] `@playwright/mcp` connects over CDP
- [ ] The image tag is pinned
- [ ] No token literal anywhere in the repo
- [ ] The verify playbook is registered and demonstrably runs
- [ ] Nothing on the reference installation changed as a side effect

---

## Implementation Notes

**Why a new category rather than an existing one.** `OBSERVABILITY` was the
tempting choice, because synthetic monitoring is the headline use and Uptime Kuma
already lives there. It is wrong: browserless is not an observability tool, it is
a capability observability *consumes* — and filing it there would make "an agent
reads a JS-rendered page" look like monitoring, which it is not.
`MANAGEMENT` is where uncategorisable tools go and would say nothing.
`TESTING` describes one of three uses and would misname the other two.
`AUTOMATION` is honest and leaves room for the next service of this shape.

**The cost of a new category is real** and should be weighed by whoever approves:
it touches `CLAUDE.md`, `AGENTS.md`, `services.json`, docs navigation, and
allocates a manifest range. That is more than adding a service. It is proposed
anyway because miscategorising the first member is harder to undo later.

**Do not declare `SCRIPT_REQUIRES="browserless"` on uptime-kuma.** Browser
monitors are optional; making browserless mandatory for Uptime Kuma would force a
Chromium pool onto installations that only want HTTP checks. The dependency is
optional and belongs in documentation, which is why browserless sits at priority
25 — available before Uptime Kuma registers monitors, without being required by it.

**Memory.** A Chromium pool is the heaviest thing in this category. On a laptop
already running the full UIS stack, limits are not optional.

---

## Files to Modify

- `CLAUDE.md`, `AGENTS.md` — the category list
- `provision-host/uis/services/automation/service-browserless.sh` (new)
- `manifests/400-browserless-config.yaml` (new)
- `ansible/playbooks/400-setup-browserless.yml`, `400-remove-browserless.yml` (new)
- `ansible/playbooks/400-test-browserless.yml` (new, verify)
- `provision-host/uis/templates/secrets-templates/` — the token key
- `00-common-values` — LocalDev default
- `website/docs/services/automation/browserless.md` (new)
- `services.json` / docs navigation — the new category
