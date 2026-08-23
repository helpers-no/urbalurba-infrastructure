# Ship browserless as a UIS service, and open an AUTOMATION category for it

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Built — handed to the independent tester 2026-08-23

**Build complete on branch `feature/browserless-automation-category`.** All four
phases done: AUTOMATION category, service definition, manifests, setup/remove/test
playbooks, secrets, docs page and logo. Awaiting the imac tester's verdict; this
plan moves to `completed/` on PASS, not before.

Two defects were found and fixed **by my own smoke checks during the build**, both
of the same shape — the service looked healthy and could not do its job:

| Defect | Symptom | Cause |
|---|---|---|
| Probe on a token-gated route | Restart loop while the HTTP server was fine | `httpGet /pressure` got 401; liveness killed the container |
| `DATA_DIR` destroyed by a mount | Pod `1/1 Ready`, `/pressure` `isAvailable: true`, **every render failed** | `emptyDir` at `/tmp` replaced the image's `/tmp`, so `/tmp/browserless` vanished |

The second is why `400-test-browserless.yml` renders a real page rather than
polling health. That assertion was checked against the bug: reintroducing the
`/tmp` mount makes test A fail with browserless's own error
(`"/tmp/browserless" Directory doesn't exist`) while the pod stays `1/1 Running`.
A verify that only reads `/pressure` passes throughout.

### Status: Backlog — ✅ APPROVED 2026-08-21, ships first

**Terje approved** (2026-08-21): the two-service split, the `AUTOMATION`
category, and **browserless ships before neko**. Names and manifest ranges as
proposed below.

**Decision already made (Terje, 2026-08-21)**: the browser platform becomes a UIS
service. Not reopened here.

As approved:

| Decision | Proposal |
|---|---|
| Service name | `browserless` (upstream name) |
| Category | **`AUTOMATION`** — new, this is its first service |
| Manifest range | **400–429**, with 430–499 reserved for future automation services |
| Priority | `25` (before uptime-kuma at 30) |
| Scope | This plan ships **browserless only** |
| Order | **First.** [neko-001](../backlog/PLAN-service-neko-001-optional-addon.md) is planned and follows |

**Handoff**: `ai-developer/for-uis-maintainer-browser-service.md` (home repo, ops
→ maintainer, 2026-08-21). Everything is built and proven on the reference
installation; this plan productises it.

**Companion**: [PLAN-service-neko-001-optional-addon](../backlog/PLAN-service-neko-001-optional-addon.md)
— the second half of the platform, also approved to plan, sequenced after this
one. It depends on the `AUTOMATION` category that Phase 1 here creates.

**Last Updated**: 2026-08-23

**Priority**: Medium

---

## Test environment: the iMac's Rancher Desktop, not asgard

**Terje, 2026-08-21**: test on the iMac so the production cluster on Odin/tor is
not disturbed. Verified suitable the same day — and it is the *right* target,
not merely a safe one: the laptop requirement is specifically about Rancher
Desktop, and this is Rancher Desktop. `assist` (the Pi) is bare k3s on **arm64**,
where browserless's amd64-first images are a problem in themselves.

| | iMac (`imac`, 100.84.7.57 / 192.168.68.55) |
|---|---|
| Arch | **x86_64** — matches browserless's published images |
| Cluster | Rancher Desktop, k3s `v1.36.3+k3s1`, Ready 45d, docker runtime |
| VM capacity | 4 CPU, **~11.7 GiB** allocatable, ~95 GiB ephemeral |
| In use | 11 pods total — effectively empty |
| UIS | installed and **initialised** (`.uis.secrets`, `.uis.extend` present) |

### What has to happen before Phase 3 can run there

- [ ] T.1 **`uptime-kuma` is not deployed on this cluster.** The headline
      acceptance criterion — a green `real-browser` monitor — needs it.
      `uis deploy uptime-kuma` there first. (It runs on `assist` today, a
      different cluster; do not try to span the two)
- [ ] T.2 **`docker` is not on the non-interactive PATH.** `./uis` fails over SSH
      with `docker: command not found`; Rancher Desktop puts it in `~/.rd/bin`.
      Every scripted run needs `export PATH=$HOME/.rd/bin:$PATH`. Small, and it
      will bite every automated invocation until it is handled

### Constraints to respect on that box

- ⚠️ **Not a scratch cluster.** Namespace `ai` runs litellm, open-webui and tika,
  up 19 days. browserless lands in namespace `browser`, so the blast radius is
  small — but this is someone's working AI stack, not a throwaway
- **Host RAM is tight**: 15 GiB total with ~5 GiB free; the Lima VM holds 12 GiB.
  Inside the cluster there is room, but conservative browserless limits matter
  more here than they would on a bigger box (task 2.11)
- **Disk 74% used** (28 GiB free). The image is ~1 GiB and the docs build wants
  ~1.7 GiB for `node_modules` + `build`. Fits; not roomy. Clean up after
- **2011 i5-2400S, 4 cores.** Fine for correctness. **Not** a performance target
  — do not draw conclusions about parallel-scrape throughput from this machine
- **Powered off for long stretches.** Usable for hands-on testing, not as an
  always-available CI target

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
[INVESTIGATE-system-roaming-dependency-addresses](../backlog/INVESTIGATE-system-roaming-dependency-addresses.md):
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

⚠️ **Rewritten 2026-08-21 after reading
[adding-a-service.md](../../../contributors/guides/adding-a-service.md).** The
first draft of this plan invented its own step list. The guide is authoritative
and the registry is `provision-host/uis/lib/categories.sh`, not the narrative
lists in `CLAUDE.md`.

browserless is the category's first inhabitant, so the category lands with it.

### Tasks

- [ ] 1.1 Add the row to `_CATEGORY_DATA` in `provision-host/uis/lib/categories.sh`.
      Format is `ID|Display Name|Description|tags|icon|logo`:
      `AUTOMATION|Automation|Browser automation, synthetic checks, and agent tooling|automation,browser,testing|robot|automation-logo.svg`
- [ ] 1.2 Add `AUTOMATION` to the `CATEGORY_ORDER` array — **position controls
      display order** (it becomes the generated `order` field), so place it
      deliberately rather than appending. Suggested: after `ANALYTICS`
- [ ] 1.3 Create `website/static/img/categories/automation-logo.svg` (plus the
      `src/` variant if the other categories carry one) — the registry row
      references a file that must exist
- [ ] 1.4 Add the category row to the table in
      `website/docs/contributors/guides/adding-a-service.md` (Step 1) —
      **manifest range 400–429**, 430–499 reserved
- [ ] 1.5 Add the same row to `website/docs/contributors/rules/kubernetes-deployment.md`
- [ ] 1.6 Update the narrative category lists in `CLAUDE.md` and `AGENTS.md`
- [ ] 1.7 Create `provision-host/uis/services/automation/`

### Validation

```bash
./uis list                 # AUTOMATION appears, empty until Phase 2
```

Generated `services.json` contains the category with a sane `order` and a `logo`
that resolves.

---

## Phase 2: The service, following the guide and the rules docs

⚠️ **Second rewrite 2026-08-21**, after reading `rules/provisioning.md`,
`rules/secrets-management.md`, `rules/kubernetes-deployment.md` and
`architecture/manifests.md`. Corrections to the previous draft are noted inline —
they were not cosmetic.

### Tasks

- [ ] 2.1 **Step 2** — `provision-host/uis/services/automation/service-browserless.sh`:
      `SCRIPT_ID="browserless"`, `SCRIPT_CATEGORY="AUTOMATION"`,
      `SCRIPT_NAMESPACE="browser"`, `SCRIPT_PRIORITY="25"`,
      `SCRIPT_KIND="Component"`, `SCRIPT_TYPE="service"`, `SCRIPT_REQUIRES=""`,
      `SCRIPT_PLAYBOOK="400-setup-browserless.yml"`,
      `SCRIPT_REMOVE_PLAYBOOK="400-remove-browserless.yml"`, `SCRIPT_CHECK_COMMAND`,
      website metadata, `SCRIPT_LOGO="browserless-logo.svg"`.
      **Metadata contains no logic** — variable assignments only; all deployment
      logic lives in the playbook (`rules/provisioning.md`, Metadata + Ansible)
- [ ] 2.2 ⚠️ **`SCRIPT_PLAYBOOK` and `SCRIPT_MANIFEST` are mutually exclusive**
      deployment methods. Use the playbook — the service needs two-stage readiness
      checks and an IngressRoute, which a bare `kubectl apply` cannot do
- [ ] 2.3 **Step 3** — `manifests/400-browserless-deployment.yaml`.
      ⚠️ **Corrected**: `*-config.yaml` means *Helm values file* in this repo.
      browserless has no Helm chart, so the Helm-less naming applies —
      precedent `320-unity-catalog-deployment.yaml`, `230-uptime-kuma-statefulset.yaml`.
      **Pinned image tag** (`ghcr.io/browserless/chromium`), never `:latest`
- [ ] 2.4 **Step 4** — `manifests/400-browserless-ingressroute.yaml`.
      ⚠️ **Corrected to 400, not 401**: *"manifest number must match the
      corresponding Ansible playbook number"* (`architecture/manifests.md`).
      Multiple manifests may share a prefix — uptime-kuma has four at `230`
- [ ] 2.5 **Step 5/6** — `ansible/playbooks/400-setup-browserless.yml` and
      `400-remove-browserless.yml`. Search `ansible/playbooks/` for an existing
      playbook to extend before creating new ones, per the rules
- [ ] 2.6 Playbook must follow `rules/provisioning.md`:
      - use `_target` (`{{ target_host | default('rancher-desktop') }}`); never
        reference `target_host` directly in the body
      - **two-stage readiness**: wait for `Running`, then for
        `containerStatuses[0].ready == true`
      - progress feedback via Ansible `retries`/`delay`, not silent `kubectl wait`
      - **never test `.localhost` from Ansible** — it resolves to the host, not
        the cluster
      - no `ignore_errors: true` on anything a later step depends on
      - verify the IngressRoute exists after applying it
- [ ] 2.7 **Step 7 — secrets, per `rules/secrets-management.md`**:
      - secret name is **`urbalurba-secrets`** in namespace `browser` — never a
        service-specific secret name
      - define `BROWSERLESS_TOKEN` once in
        `.uis.secrets/secrets-config/00-common-values.env.template`
        (shipped template: `provision-host/uis/templates/secrets-templates/`)
      - reference it as `BROWSERLESS_TOKEN: "${BROWSERLESS_TOKEN}"` in
        `00-master-secrets.yml.template` under the `browser` namespace
      - pod reads `secretKeyRef` only. **Never** a literal, never a real value
        shipped as a default
      - a LocalDev default keeps Rancher Desktop zero-config
- [ ] 2.8 **Step 8** — N/A, no Helm chart and therefore no Helm repo
- [ ] 2.9 **Step 9** — commented-out entry in
      `provision-host/uis/templates/uis.extend/enabled-services.conf.default`.
      (`./uis deploy browserless` auto-enables; the template documents availability)
- [ ] 2.10 **Step 10** — `provision-host/uis/lib/stacks.sh`. Recommendation:
      **no change**. browserless is a dependency of one optional monitor type,
      not part of the metrics/logs/traces set; pulling a Chromium pool into every
      `uis stack install observability` would be wrong
- [ ] 2.11 Resource requests/limits — the heaviest thing in this category; on a
      laptop already running the full stack, limits are not optional

### Validation

```bash
./uis deploy browserless
./uis status
./uis list --category AUTOMATION
./uis undeploy browserless        # three-tier removal via the remove playbook
```

First deploy on Rancher Desktop needs no secret setup and no manual step.

---

## Phase 3: Verify playbook — and actually register it, in three places

**Step 5b.** The guide names two registration points. **There is a third**, and
missing it is invisible: `cmd_verify()` in `uis-cli.sh` carries a hardcoded
usage list of verifiable services. A service registered in the other two but
absent there works, yet is undiscoverable — the same allowlist-that-new-things-
never-join shape as the secrets validator.

⚠️ **Report this gap back to the guide** — see Implementation Notes.

### Tasks

- [ ] 3.1 `ansible/playbooks/400-test-browserless.yml`. Reference implementations
      per the guide: `025-test-argocd.yml`, `085-test-enonic.yml`,
      `300-test-openmetadata.yml`
- [ ] 3.2 Register in `VERIFY_SERVICES` in `provision-host/uis/lib/integration-testing.sh`
- [ ] 3.3 Add the `browserless)` case to `cmd_verify()` in
      `provision-host/uis/manage/uis-cli.sh`, implementing `cmd_browserless_verify()`
- [ ] 3.4 **Add the line to the hardcoded help list inside `cmd_verify()`** — the
      step the guide omits
- [ ] 3.5 ⚠️ **Do not copy the connectivity-test idiom from `rules/provisioning.md`
      verbatim.** It uses `kubectl run --rm -i` with
      `until: rc == 0 and stdout.find('HTTP_CODE:200')`, and that call can return
      `rc=0` with **empty stdout** when the container outlives the attach — so a
      healthy service reads as failing after exhausting retries. This is the
      defect in [INVESTIGATE-system-verification-playbooks-usage](../backlog/INVESTIGATE-system-verification-playbooks-usage.md);
      the rules doc still teaches it. Assert on something that cannot be silently
      empty
- [ ] 3.6 **Prove both consumers** — different protocols on different routes,
      both required or the service is half-delivered:
      - **Playwright path**: register browserless as a Remote Browser in Uptime
        Kuma; one `real-browser` monitor goes green against an in-cluster
        service. This is the product story — demonstrate it, do not assert it
      - **CDP path**: `@playwright/mcp --cdp-endpoint http://…:3000` drives a page
- [ ] 3.7 Confirm it is reachable from `uis verify browserless` **and** from
      `test-all` — uptime-kuma's verify was invisible to `test-all`
- [ ] 3.8 E2E stays in the verify playbook, **not** on the deploy gate, per
      [PLAN-service-grafana-deploy-gate-fix](../backlog/PLAN-service-grafana-deploy-gate-fix.md) Phase 4

### Validation

`uis verify` with no argument **lists browserless**. `uis verify browserless`
runs and reports real numbers. `test-all` includes it. Uptime Kuma shows a green
browser-based monitor.

---

## Phase 4: Exposure, security and documentation

### Tasks

- [ ] 4.1 Exposure differs by environment, the pod does not — the same
      interfaces-over-backends rule as secrets. Rancher Desktop: localhost /
      Traefik. Proxmox: the reference installation's manifest as the documented
      example. Cloud: **explicitly out of scope**, stated rather than inferred
- [ ] 4.2 Security model carried verbatim from `platform/browser/README.md`
      (home repo): private-network-only, and **why**
- [ ] 4.3 **Step 11** — `website/docs/services/automation/browserless.md`, added
      to `website/sidebars.ts` under the new category
- [ ] 4.4 Document the Uptime Kuma Remote Browser recipe as the headline use, and
      the tool-choice ladder (plain HTTP → browserless → neko)
- [ ] 4.5 Create `website/static/img/services/browserless-logo.svg` (plus the
      `src/` variant the other service logos carry)
- [ ] 4.6 IngressRoute follows `rules/ingress-traefik.md` patterns — do not
      invent routing conventions here
- [ ] 4.7 Build the docs site **in the Node container** — neither the workstation
      nor provision-host ships Node:
      ```bash
      cd website && docker run --rm -u $(id -u):$(id -g) \
        -v "$PWD":/w -w /w -e HOME=/tmp -e CI=true node:20 \
        sh -c 'npm ci && npm run build'
      ```
      ⚠️ **Read the warnings, not the exit code.** Broken links and anchors are
      warnings; the build still exits 0 and CI does not fail on them

### Validation

Docs build with no new broken-link warnings. A reader gets from
`uis deploy browserless` to a green browser monitor without reading this plan.

---

## Acceptance Criteria

- [ ] Terje has approved the name, category and scope **before** Phase 1 starts
      — ✅ **approved 2026-08-21** (split into two services, category `AUTOMATION`)
- [ ] The service meets the laptop requirement: `uis deploy browserless` on
      Rancher Desktop, nothing else, no second machine, no hand-built step
- [ ] The verify playbook is registered in **both** files and demonstrably runs
- [ ] `uis deploy browserless` works on Rancher Desktop with no secret setup
- [ ] An Uptime Kuma `real-browser` monitor runs green against an in-cluster service
- [ ] `@playwright/mcp` connects over CDP
- [ ] The image tag is pinned
- [ ] No token literal anywhere in the repo
- [ ] The verify playbook is registered and demonstrably runs
- [ ] Nothing on the reference installation (Odin/asgard) changed as a side effect
- [ ] The iMac's existing `ai` namespace is untouched

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

**Two gaps found in the contributor docs while writing this plan.** Both are
small, both cost someone a debugging session, and neither belongs to this
service — they should be fixed in the docs, not worked around here:

1. `adding-a-service.md` Step 5b says verify registration is **two files**. It is
   three: `cmd_verify()` in `uis-cli.sh` also carries a hardcoded usage list, and
   a service missing from it is undiscoverable while appearing to work.
2. `rules/provisioning.md` teaches the connectivity test as `kubectl run --rm -i`
   with `until: rc == 0 and stdout.find(...)`. That idiom is the subject of
   [INVESTIGATE-system-verification-playbooks-usage](../backlog/INVESTIGATE-system-verification-playbooks-usage.md)
   — the call can return `rc=0` with empty stdout, so a healthy service reads as
   failing. The rules doc still recommends it.

**What the first two drafts of this plan got wrong**, recorded so the pattern is
visible rather than quietly fixed: it invented a step list instead of following
`adding-a-service.md`; it missed the category registry (`categories.sh`) entirely
and named only the narrative lists in `CLAUDE.md`; it missed `enabled-services.conf`,
`stacks.sh`, `sidebars.ts` and the category logo; it used `-config.yaml` for a
manifest that is not Helm values; and it numbered the IngressRoute `401` against
a `400` playbook. Writing plans from inference rather than from the documented
process produced a plan that looked complete and was not.

---

## Files to Modify

**Category (Phase 1)**
- `provision-host/uis/lib/categories.sh` — `_CATEGORY_DATA` row + `CATEGORY_ORDER`
- `website/static/img/categories/automation-logo.svg` (new)
- `website/docs/contributors/guides/adding-a-service.md` — Step 1 category table
- `website/docs/contributors/rules/kubernetes-deployment.md` — category table
- `CLAUDE.md`, `AGENTS.md` — narrative category lists

**Service (Phase 2)**
- `provision-host/uis/services/automation/service-browserless.sh` (new)
- `manifests/400-browserless-deployment.yaml` (new — not `-config`; that suffix
  means Helm values, and there is no chart)
- `manifests/400-browserless-ingressroute.yaml` (new — same number as the playbook)
- `ansible/playbooks/400-setup-browserless.yml`, `400-remove-browserless.yml` (new)
- `provision-host/uis/templates/secrets-templates/00-common-values.env.template`
  — `BROWSERLESS_TOKEN` defined once
- `provision-host/uis/templates/secrets-templates/00-master-secrets.yml.template`
  — `urbalurba-secrets` in namespace `browser`, referencing `${BROWSERLESS_TOKEN}`
- `provision-host/uis/templates/uis.extend/enabled-services.conf.default`
- `provision-host/uis/lib/stacks.sh` — see task 2.9 (recommendation: no change)

**Verify (Phase 3)**
- `ansible/playbooks/400-test-browserless.yml` (new)
- `provision-host/uis/lib/integration-testing.sh` — `VERIFY_SERVICES`
- `provision-host/uis/manage/uis-cli.sh` — `cmd_verify()` dispatch **and** its
  hardcoded usage list (two edits in one file; the guide names only the first)

**Docs (Phase 4)**
- `website/docs/services/automation/browserless.md` (new)
- `website/sidebars.ts`
- `website/static/img/services/browserless-logo.svg` (+ `src/` variant) (new)
