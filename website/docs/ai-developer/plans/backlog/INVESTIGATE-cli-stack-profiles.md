# Investigate: a stack installs the same way on a laptop and a server

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog

**Goal**: Give UIS a way to express *how much* of a stack to install and *how
big* to size it, so one stack definition serves both a developer's Rancher
Desktop and a production cluster. Today `uis stack install observability`
installs five components at fixed sizes regardless of the machine — and the one
flag intended to slim it down cannot work.

**Related**: [INVESTIGATE-system-observability](./INVESTIGATE-system-observability.md)
— answers its **Q3** (what Grafana should require) and **Q4** (retention and
sizing, whose premise it also corrects). Its **Q2** (opt-in vs default) is
*not* answered here: Part 7 Q5 shows the RAM figure that decision rests on is
not yet established.

**Finding IDs**: findings here are prefixed `CLI-`; the companion document uses
`OBS-`. Both documents number findings from 1, so an unprefixed "F3" is
ambiguous — always use the prefix.

**Depends on**: `PLAN-cli-stack-002-profiles` cannot be implemented before the
parent's `PLAN-system-observability-001-log-collection`, which creates the Alloy
service the profiles reference. See CLI-F9.

**Created**: 2026-08-05 — findings traced against `main` @ `ca59e7c`

---

## Background

UIS has two deployment situations that pull in opposite directions:

| | Developer | Production |
|---|---|---|
| Platform | Rancher Desktop (Lima VM) | k3s / AKS on real hardware |
| RAM available | often 8–12 GB total | tens of GB |
| What they need | all signals, almost no history | full retention, alerting, tracing |

The observability stack is where this bites hardest — it is the largest stack
UIS ships (5 components, 40 GiB of claims) — but the gap is in the **stack
mechanism**, not in observability. Any future stack will hit it.

This investigation is scoped to the CLI surface. The Alloy migration and the
telemetry gaps live in the parent investigation.

---

## Part 1: Findings (traced from source, with file:line)

### CLI-F1 — `--skip-optional` already exists, and it cannot succeed (severity: high, bug)

The mechanism is half-built. `uis stack install <stack> [--skip-optional]` is
implemented, and the stack schema in `stacks.sh` already carries an
`optional_services` field:

```
observability|…|services=prometheus,tempo,loki,otel-collector,grafana|optional=otel-collector|…
```

But two files disagree about whether `otel-collector` is optional:

| File | Declares |
|---|---|
| `provision-host/uis/lib/stacks.sh` | `optional_services = "otel-collector"` |
| `provision-host/uis/services/observability/service-grafana.sh` | `SCRIPT_REQUIRES="prometheus loki tempo otel-collector"` |

And dependencies are enforced by hard failure, not by auto-install:

```bash
# provision-host/uis/lib/service-deployment.sh:292
check_dependencies() {
    for dep in $requires; do
        if ! check_service_deployed "$dep"; then
            die_dependency "Required service '$dep' is not deployed"
        fi
```

So the execution path is:

```
uis stack install observability --skip-optional
  → uis-cli.sh:823   skips otel-collector
  → deploys prometheus, tempo, loki          ✅
  → deploy_single_service grafana            (grafana is last in the stack order)
  → service-deployment.sh:120 check_dependencies "prometheus loki tempo otel-collector"
  → otel-collector not deployed
  → die_dependency                           ❌ stack install fails
```

**The only existing mechanism for a smaller install is broken by a
contradiction in the service metadata.** The same applies to a bare
`uis deploy grafana`, which demands all four services today.

*Repro (not yet run against a cluster — traced from source; worth confirming
before implementing):*

```bash
uis stack install observability --skip-optional
# expected: fails at grafana with "Required service 'otel-collector' is not deployed"
```

### CLI-F2 — Grafana's dependency declaration is the real blocker (severity: high)

`SCRIPT_REQUIRES="prometheus loki tempo otel-collector"` makes every slim
scenario impossible, not just `--skip-optional`. A metrics-only install —
the single most useful configuration for a developer laptop — cannot be
expressed at all while Grafana hard-requires a log store and a trace store it
does not need in order to run.

This is the parent investigation's Q3. It is not a design question; it is a bug
with a small diff.

### CLI-F3 — Sizing is fixed, and unrelated to retention (severity: medium)

The parent investigation's Q4 states the PVCs have "no documented retention
policy". **That is not correct** — retention is configured in all three stores:

| Component | Retention | PVC | Assessment |
|---|---|---:|---|
| prometheus-server | `retention: 15d` | 8Gi | the only sensible ratio |
| alertmanager | — | 2Gi | silences/state; ~100Mi would do |
| tempo | `retention: 24h` | 10Gi | oversized for the window |
| loki | `retention_period: 24h` + compactor `retention_enabled: true` | 10Gi | oversized for the window |
| grafana | — | 10Gi | SQLite + dashboards, typically < 100Mi |
| | | **40Gi** | matches the measured figure |

The actual defect is different: **PVC sizes were chosen independently of the
retention windows.** 24 hours of logs or traces from a small cluster is tens to
low hundreds of MB, against 10Gi claims.

And the real risk neither document has flagged: **all retention is time-based;
there is no size cap anywhere.**

```bash
grep -riE 'retentionSize|retention_size' manifests/03*.yaml   # → no matches
```

Time-based retention does not protect a disk. If scrape volume grows,
Prometheus fills 8Gi long before 15d elapses, and a full TSDB is an ugly
failure mode. `server.retentionSize` set just below the claim is the missing
backstop.

### CLI-F4 — Three of five components declare no resources at all (severity: medium)

```bash
grep -c 'resources:' manifests/031-tempo-config.yaml \
                     manifests/032-loki-config.yaml \
                     manifests/034-grafana-config.yaml
# → 0, 0, 0
```

Prometheus and the OTel Collector set requests/limits; Loki, Tempo and Grafana
do not, so they run on chart defaults. **A sizing feature cannot be built on
top of this** — there is nothing to scale. Declaring resources is a
prerequisite, not a nice-to-have.

Credit where due: the Loki values are otherwise well-tuned —
`deploymentMode: SingleBinary` with `chunksCache` and `resultsCache` explicitly
disabled, which avoids that chart's multi-GB memcached default.

### CLI-F5 — Two Grafana values files; one is dead

`ansible/playbooks/034-setup-grafana.yml:16` uses
`manifests/034-grafana-config.yaml` (10Gi). `manifests/030-grafana-config.yaml`
(5Gi) is referenced by nothing but its own header comments. It should be
deleted before someone tunes the wrong file.

### CLI-F6 — Components enabled by default that a small install does not need

| Component | Where | Note |
|---|---|---|
| `pushgateway` | `030-prometheus-config.yaml:78` `enabled: true` | nothing pushes to it; it occupies a scrape target |
| `gateway` | not set in `032-loki-config.yaml` | chart default enables it — an nginx proxy unnecessary for in-cluster SingleBinary access |
| `lokiCanary` | not set in `032-loki-config.yaml` | chart default enables it; continuously writes synthetic logs |

The canary is worth calling out: it is part of why the parent investigation
found Loki containing only test data. A small profile should disable all three.

### CLI-F7 — The platform layer exists, and is the wrong place to put sizing

UIS already models *where* a cluster runs: `uis platform list` / `uis platform
use`, backed by `platforms/rancher-desktop` and `platforms/azure-aks`
(`provision-host/uis/lib/platform-switching.sh`).

It is tempting to hang install size off platform — "rancher-desktop means
small". That hard-codes the wrong relationship. See Part 2.

### CLI-F8 — The tests cannot detect any of this (severity: high)

This is why the gap went unnoticed. `u10-verify-observability-tasks.yml` runs 15
checks, and **every one of them is either "is the API up" or "can I read back
data I just wrote"**:

| Steps | What they do |
|---|---|
| VERIFY 1–4, 11–13 | health / API availability / datasource presence |
| VERIFY 5–7 | push a trace to the collector → wait → query Tempo for *that trace* |
| VERIFY 8–10 | push a log to the collector → wait → query Loki for *that log* |

Not one check asks whether telemetry from a **real workload** arrives. The log
test pushes over OTLP directly, so it passes with **no log-shipping agent
installed at all** — which is exactly the parent's OBS-F2. The suite is
structurally incapable of catching the failure it exists to prevent.

Worse, it never runs. `u10-verify-observability-tasks.yml` has **no caller** —
independently found in
[INVESTIGATE-system-verification-playbooks-usage](./INVESTIGATE-system-verification-playbooks-usage.md)
("no active caller found"). For contrast, `u02-verify-postgres.yml` *is* wired
in, from `650-setup-backstage.yml`, so the pattern works; this file is
specifically orphaned.

There is also no hook to wire it to. Service metadata has `SCRIPT_PLAYBOOK`,
`SCRIPT_REMOVE_PLAYBOOK` and `SCRIPT_CHECK_COMMAND`, but **no `SCRIPT_TEST`**:

```bash
grep -rhoE '^SCRIPT_[A-Z_]+=' provision-host/uis/services/ | sort -u   # no SCRIPT_TEST
```

That absence is why `NNN-test-<service>.yml` files and `u10-*` float unattached.

One consequence for the work proposed here: **VERIFY 13 hard-asserts that
Grafana has both a `tempo` and a `loki` datasource.** The Grafana dependency fix
(CLI-F2) will break that assertion. The test currently encodes the bug.

### CLI-F9 — The profiles reference a service that does not exist yet (severity: high)

```bash
ls provision-host/uis/services/*/service-alloy.sh   # → no such file
```

Every profile in Part 3 lists `alloy`, but **Alloy is not a UIS service**. It is
created by the parent's `PLAN-system-observability-001-log-collection`.

`PLAN-cli-stack-002-profiles` is therefore **not startable on its own** — anyone
picking it up first is blocked immediately. Either sequence the parent's PLAN-001
ahead of it, or have the profiles name `otel-collector` until Alloy lands and
switch afterwards. This is a hard cross-investigation dependency, not a
preference.

### CLI-F10 — A PersistentVolumeClaim cannot be shrunk (severity: high)

Kubernetes supports volume **expansion** only. There is no in-place shrink.

Consequently `--size small` applies cleanly to a **fresh** install and **cannot
be applied to the existing 40 GiB deployment**. Moving an existing install to a
smaller size means deleting and recreating the PVCs, which destroys the
historical metrics, logs and traces they hold.

This is the gap most likely to cause damage in practice, because the natural
reading of "add a `--size` flag" is that it can be applied to what you already
have. It cannot. Any sizing work must therefore state:

- which sizes are **install-time only** versus safely changeable later
- that going *up* a size is possible (expansion) while going *down* is not
- what the documented procedure is for deliberately resizing down, including the
  data loss it entails

Growing is not automatic either: it requires the StorageClass to have
`allowVolumeExpansion: true`, which should be verified on both Rancher Desktop's
`local-path` and whatever production uses before promising it.

### CLI-F11 — Production is not an install; it is a migration (severity: high)

Everything in Part 3 is written as `stack install` — a fresh cluster choosing a
profile and a size. **The production case is not that.** The parent
investigation's appendix records `asgard` as already running 13 UIS services
*including the full observability stack*, with Prometheus scraping 18 targets.

So the production command is not:

```bash
uis stack install observability --profile full --size medium   # asgard already has this stack
```

There is no defined answer today for what that does to a cluster where the stack
exists — re-run the Helm upgrades, fail, refuse, or partially apply. That
undefined behaviour is the gap, and production is the only place it occurs.

What the migration path can and cannot do follows from CLI-F10:

| Move on an existing install | Possible? | How |
|---|---|---|
| `small` → `medium` → `large` | yes | volume expansion, if `allowVolumeExpansion: true` |
| profile widened (`metrics` → `full`) | yes | additive; deploy the new components |
| profile narrowed (`full` → `metrics`) | yes, destructive | removing a component destroys its store |
| any size **downward** | **no** | delete + recreate PVCs; retained data is lost |

The good news for production specifically: **the direction production wants is
the allowed one.** asgard growing from today's fixed sizes up to a defined
`medium` is expansion, which is safe. Only shrinking is a one-way door.

Any sizing work must therefore ship an explicit answer for existing installs, not
only for clean clusters — most likely "growing is safe and supported; shrinking
requires deliberate recreation and accepts data loss", with the CLI refusing a
downward `--size` unless confirmed.

### CLI-F12 — The Grafana playbook enforces the dependency a second time (severity: high)

CLI-F2 identified `SCRIPT_REQUIRES` as "the real blocker" and called the fix a
small diff. **Tracing `034-setup-grafana.yml` shows that is only half of it.**
Reducing `SCRIPT_REQUIRES` on its own changes nothing observable: the deploy stops
failing at `check_dependencies` and starts failing at playbook task 20 instead,
with a worse message.

Task 20 (`FAIL deployment if core tests did not pass`) aborts the play unless the
Loki datasource, the Tempo datasource, an OTLP log round-trip *and* an OTLP trace
round-trip all succeed. Three things follow:

1. **`otel-collector` is a hidden dependency** beyond the four declared ones —
   tasks 14, 17, 24 and 25 push through
   `otel-collector-opentelemetry-collector`, which no metadata mentions.
2. **Datasource proxy IDs are positional** — every check uses
   `/api/datasources/proxy/1|2|3/…`, assuming Prometheus=1, Loki=2, Tempo=3. Under
   conditional datasources those positions shift, so a metrics-only install would
   proxy the *wrong datasource* rather than error. The repo has zero UID-based
   proxy calls today (`grep -c 'proxy/uid'` → 0). This is the one change here that
   fails silently instead of loudly.
3. **The shipped dashboards assume all three signals** —
   `035-grafana-test-dashboards.yaml` references the `loki` and `tempo`
   datasource UIDs twice each, `036-grafana-sovdev-metrics.yaml` references `loki`
   four times, and task 23 blocks until ≥4 dashboard ConfigMaps exist.

**Additionally, the Loki datasource URL collides with CLI-F6.** It points at
`loki-gateway.monitoring.svc.cluster.local:80`, while CLI-F6 recommends disabling
Loki's chart-default `gateway` in the small profile. Doing both breaks the
datasource; the URL must move to the Loki service directly when that lands.

This does not change the conclusion that the Grafana fix should be done first —
it is still the smallest *unblocking* change and still independently valuable. It
changes the size estimate: five files, not one line. See
[PLAN-service-grafana-optional-datasources](./PLAN-service-grafana-optional-datasources.md).

---

## Part 2: Platform, profile and size are three different things

The framing "we have two deploy situations" suggests one axis. There are three,
and collapsing them is the trap:

| Axis | Question it answers | Modelled today? |
|---|---|---|
| **Platform** | *Where* does the cluster run? | ✅ `uis platform use` |
| **Profile** | *Which* components get installed? | ❌ only a binary `--skip-optional` |
| **Size** | *How big* are they sized? | ❌ hardcoded in manifests |

Profile and size do not follow from platform:

- a **small production** k3s on a cheap VPS wants the lean install
- a **32 GB developer workstation** may want the full stack, traces included,
  precisely in order to develop against it

The evidence in this repo shows both ends: the parent investigation's findings
come from production k3s `asgard` with room to spare, while a Rancher Desktop VM
is commonly 8–12 GB.

The **storage** figure is solid and sufficient to make the case on its own: 40
GiB of claims (CLI-F3, summed from the manifests) against a laptop is
substantial regardless of RAM. The frequently-quoted "~4 GB RAM" is *not* used as
evidence here — see Part 7 Q5 for why it is not yet established.

**Size follows from the machine, not from dev-vs-prod.** So: add profile and
size as their own axes, and let the active platform supply *defaults* for them.

---

## Part 3: Proposed command surface

```bash
# which components
uis stack install observability --profile metrics    # prometheus + alloy + grafana
uis stack install observability --profile logs       # + loki
uis stack install observability --profile full       # + tempo

# how big — orthogonal
uis stack install observability --profile logs --size small
```

### Defaults — and the two cases they get wrong

The obvious rule is "`rancher-desktop` → `metrics`/`small`, everything else →
`full`/`medium`". **The `metrics` half of that is wrong**, for the reason below;
the recommended rule is `rancher-desktop` → **`full`/`small`**.

#### Why the developer default must be `full`, not `metrics`

"The developer" is two different people who want opposite things:

| | What they want | Observability is… |
|---|---|---|
| **A.** Building an app *against* the platform | Postgres, Redis, the cluster up | overhead — every GB matters |
| **B.** Instrumenting an app's telemetry | to see their traces and logs actually arrive | the entire point |

A `metrics` default serves A and **silently breaks B**. B is not hypothetical: it
is the parent investigation's PLAN-005, whose acceptance criterion is *"a
scaffolded app emits a trace locally and in production with no code change."* A
metrics-only local default means that trace goes nowhere — which is precisely the
failure in the parent's OBS-F3, where an application team defaulted to Grafana
Cloud because no local path was documented, while a self-hosted stack was running
the whole time.

The two-axis design in Part 2 handles this without contradiction, which is
evidence the split is the right one. A developer wants *all signals* with *almost
no history*:

```bash
uis stack install observability --profile full --size small
```

Profile = which signals. Size = how much history. That combination is coherent,
not a compromise.

Judge the default by which error is worse:

| Default | If the guess is wrong | Cost |
|---|---|---|
| `full` | dev only needed the cluster running | ~500 MB wasted; `--profile metrics` fixes it in one flag |
| `metrics` | dev is instrumenting an app | traces vanish with no error; they debug the wrong thing or conclude UIS cannot do it |

The second is far worse, and it is the one that loses users to a cloud APM
vendor. `metrics` remains available for person A and for genuinely small nodes.

#### How defaults are keyed

Two honest options:

1. **Platform-keyed defaults, with the limitation documented.** Simple and right
   most of the time; wrong for a small production cluster, where the operator
   must pass `--size small` explicitly. Note this is the exact case Part 2 gives
   as the reason *not* to bind size to platform — keying defaults off platform is
   a documented approximation, not a claim the axes collapse. Recommended as a
   starting point, because it is predictable and never silently *shrinks* a
   production install.
2. **Capacity-keyed defaults.** Read allocatable memory from the target nodes and
   pick a size from thresholds. Correct for the VPS case, but the default becomes
   a function of cluster state — the same command produces different installs on
   different days, which is harder to reason about and to support.

The failure modes are asymmetric, which decides it: option 1 errs toward
installing *more* than a small production cluster wants (visible, fixable with a
flag), while a mis-sized capacity heuristic could quietly under-provision
production monitoring. **Recommend option 1, and print the resolved
profile/size before installing** so the choice is never invisible.

Whichever is chosen, the defaults must be documented as machine-shaped, not
environment-shaped — see Part 7 Q4.

### Schema change

Add a `profiles` field to `_STACK_DATA` in `stacks.sh`:

```
profiles = metrics:prometheus,alloy,grafana;logs:prometheus,alloy,loki,grafana;full:prometheus,alloy,loki,tempo,grafana
```

This is **additive, not a replacement.** An earlier draft proposed superseding
`optional_services` outright; that breaks the other stacks. `analytics` declares
`unity-catalog` as optional today and `--skip-optional` works there, but profiles
are defined here only for `observability` — so "resolve `--skip-optional` to the
next profile down" is undefined for every stack that has no profiles.

The rule instead:

- a stack **may** declare `profiles`; if it does not, nothing changes for it
- `optional_services` and `--skip-optional` keep working exactly as today
- `--profile` and `--skip-optional` are **mutually exclusive**; passing both is
  an error rather than a silently-resolved precedence
- only once a stack declares profiles is `--skip-optional` deprecated *for that
  stack*

This keeps `analytics` and `ai-local` untouched by this work.

Note that with Alloy replacing the OTel Collector (parent investigation,
PLAN-001), the `optional_services` contradiction in CLI-F1 disappears on its own —
the disputed component ceases to exist. Fixing CLI-F2 is still required.

### Where size lives

Helm values overlays, applied after the base values:

```
helm upgrade --install prometheus … -f 030-prometheus-config.yaml \
                                    -f 030-prometheus-config.small.yaml
```

Each size sets the **triple** `{PVC, retention window, retentionSize cap}`
together. Setting one without the others is exactly what produced the
24h-retention-on-a-10Gi-claim mismatch in CLI-F3.

Indicative targets — today's fixed 40Gi is roughly `medium`-shaped in storage but
`small`-shaped in retention, which is the CLI-F3 mismatch in one line:

| Claim | Now | `small` | `medium` | `large` |
|---|---:|---:|---:|---:|
| prometheus | 8Gi | 4Gi | 20Gi | 60Gi |
| alertmanager | 2Gi | 1Gi | 1Gi | 2Gi |
| loki | 10Gi | 2Gi | 20Gi | 60Gi |
| tempo | 10Gi | 2Gi | 10Gi | 30Gi |
| grafana | 10Gi | 1Gi | 2Gi | 5Gi |
| **total** | **40Gi** | **~10Gi** | **~53Gi** | **~157Gi** |

| Retention | `small` | `medium` | `large` |
|---|---|---|---|
| metrics | 7d + `retentionSize: 3GB` | **30d** + `retentionSize: 16GB` | **90d** + `retentionSize: 50GB` |
| logs | 24h | **7d** | **30d** |
| traces | 24h | **3d** | **7d** |

**`medium` and `large` are not a scaled-up `small`; the retention windows differ
in kind.** 24 hours of logs is adequate for a laptop, where you are looking at
what you just did. It is not adequate for production, where you frequently learn
about a problem days after it started — a 24h window means the evidence is
already gone when the investigation begins. That is why `medium` moves logs to 7d
and traces to 3d rather than simply widening the claims.

Two constraints on these numbers:

- They are **indicative and unmeasured.** Ingest volume per GB is workload-shaped;
  `PLAN-cli-stack-003-sizing` should measure a real day of asgard ingest before
  fixing them. The relationship between the rows (`{PVC, retention window,
  retentionSize cap}` set together) is the part that matters and is not
  negotiable.
- **Undershooting is recoverable; overshooting is not** — see CLI-F10. Going up a
  size is volume expansion; going down requires recreating the PVC and losing its
  data. So when uncertain between two sizes for production, pick the smaller one
  and grow into the larger.

There is prior art worth copying rather than inventing: Grafana's own
`k8s-monitoring` chart ships **small / medium / large / xlarge** presets.

---

## Part 4: Test strategy

Every change below alters what gets installed. Without tests that can tell the
difference, "the stack still deploys" will again be mistaken for "the stack
still works" (CLI-F8).

### The rule: a test must observe a signal no test wrote

The existing suite pushes synthetic telemetry and reads it back. That proves the
*store* works and says nothing about the *pipeline*. Every new test here asserts
on data produced by a workload that is not part of the test harness.

### T1 — Unattended log arrival (proves OBS-F2 is closed)

Deploy a workload that only writes to stdout — `whoami` already exists for this
(`025-setup-whoami-testpod.yml`) — then query Loki for logs carrying **that
pod's** labels, pushing nothing.

Anti-cheat assertion, straight from the parent investigation's repro:

```bash
curl -s "$LOKI/loki/api/v1/label/job/values"
# FAIL if the only value is the validation job — that is today's broken state
```

### T2 — Alerts exist, and actually fire (proves OBS-F1 is closed)

Static check is necessary but weak:

```bash
curl -s "$PROM/api/v1/rules" | jq '.data.groups | length'   # FAIL if 0
```

The real test is dynamic: scale a deployment to zero, then assert an alert
reaches `firing` within the rule's window. "Monitoring installed" and "monitored"
differ exactly here.

### T3 — Profile matrix (guards the Grafana dependency fix)

For each profile, assert the component set is *exactly* what the profile
declares — no more, no less — and that Grafana is healthy with datasources
matching the profile:

| Profile | Must exist | Must NOT exist | Grafana datasources |
|---|---|---|---|
| `metrics` | prometheus, alloy, grafana | loki, tempo | prometheus only |
| `logs` | + loki | tempo | + loki |
| `full` | + tempo | — | + tempo |

The "must NOT exist" column is the important half — it is what catches a profile
silently installing more than it claims. **VERIFY 13 must become profile-aware
as part of this**, or it fails the moment the dependency fix lands.

### T4 — Sizing assertions (guards `--size`)

Cheap, static, and catches drift:

- sum of PVC capacity in the namespace ≤ the profile's documented budget
- every component declares both requests and limits (fails today — CLI-F4)
- Prometheus `retentionSize` is set and is below its claim (fails today — CLI-F3)

### T5 — Alloy equivalence (run during the collector swap)

Before/after comparison rather than a fixed expectation: capture the scrape
target list and a successful trace ingestion with the OTel Collector, then assert
both still hold with Alloy. Proves the swap is non-regressive rather than merely
green.

### When these run

**During each change** — every plan below ships with a test that **fails before
the change and passes after**. The expected-fail is stated in the plan, so a test
that passes beforehand is treated as a broken test, not as good news.

**After** — the suite runs per profile, so the matrix in T3 is exercised on every
profile rather than only the one a developer happened to install.

### Where each test can actually run

The tests are not uniform in cost or safety, and treating them as one suite would
put a destructive check into a routine command:

| Test | Cost | Safe on a live cluster? | Where |
|---|---|---|---|
| T3 profile matrix | seconds | yes — read-only | every `stack test` run |
| T4 sizing assertions | seconds | yes — read-only | every `stack test` run |
| T1 log arrival | ~1 min (ingest lag) | yes — deploys one pod | every `stack test` run |
| T5 Alloy equivalence | minutes | yes | during the collector swap only |
| **T2 alerts fire** | minutes | **no — scales a workload to zero** | throwaway/dev cluster, or explicit opt-in flag |

T2 is the only genuinely disruptive one. It must not run by default against a
production cluster; gate it behind something like `uis stack test observability
--include-disruptive`, and use a workload deployed by the test itself as the
scale-to-zero target rather than a real service.

Note also that T1 depends on log ingest latency, and T5 on Tempo's block flush —
the same class of timing that makes today's Grafana E2E flaky (OBS-F6). Both must
poll to a deadline rather than sleep-and-hope, or they will teach the same lesson
that produced CLI-F8.

### Where they live — and the hook that is missing

This intersects
[INVESTIGATE-system-verification-playbooks-usage](./INVESTIGATE-system-verification-playbooks-usage.md),
whose Q5 asks whether verification belongs in setup playbooks, dedicated test
playbooks, or reusable utility includes. This investigation's answer, for
stack-level tests:

1. Keep reusable task includes in `utility/` (the `u10-*` shape) — but **wire
   them in**, which is the fix for CLI-F8.
2. Add a **`SCRIPT_TEST`** field to service metadata, alongside the existing
   `SCRIPT_PLAYBOOK` / `SCRIPT_REMOVE_PLAYBOOK`. Its absence is the structural
   reason test playbooks float unattached.
3. Add `uis stack test <stack> [--profile <p>]` so the matrix is runnable as one
   command rather than by hand.

Point 2 is small and independently useful: it gives every existing
`NNN-test-<service>.yml` a defined place to be called from.

---

## Part 5: Proposed plans (ordered)

```
PLAN-cli-stack-001-test-harness.md             ← test hook + `uis stack test`; nothing below is verifiable without it
PLAN-service-grafana-optional-datasources.md   ← standalone bug fix, unblocks every profile
PLAN-cli-stack-002-profiles.md                 ← the --profile axis + schema
PLAN-cli-stack-003-sizing.md                   ← the --size axis + values overlays
PLAN-cli-stack-004-platform-defaults.md        ← defaults from the active platform
```

T1 (log arrival) and T2 (alerts fire) are **not** listed here — they belong with
the parent investigation's `PLAN-system-observability-001-log-collection` and
`-002-alert-baseline`, because a test asserting logs arrive can only pass once
something ships logs. The harness below provides the mechanism they plug into.

### PLAN-cli-stack-001-test-harness (do first)

Add the `SCRIPT_TEST` metadata field, wire the orphaned
`u10-verify-observability-tasks.yml` to an actual caller, and add
`uis stack test <stack>`. Split the existing 15 checks into *component* checks
(keep) and mark the push-and-read-back pairs as what they are, so nobody mistakes
them for pipeline coverage again.

Also fix the flaky Grafana E2E race (OBS-F6) while in here: it retries 3 times
against Tempo's block flush and aborts the play on a healthy stack. A test that
fails on timing teaches people to ignore failures, which is how CLI-F8 survived.

*Acceptance:* `uis stack test observability` runs the verification suite and
reports per-check results. **Expected-fail before:** the suite is unreachable by
any command today.

### PLAN-service-grafana-optional-datasources (do next — biggest unblock)

**Drafted:** [PLAN-service-grafana-optional-datasources](./PLAN-service-grafana-optional-datasources.md)

Reduce `SCRIPT_REQUIRES` to `"prometheus"`, provision the Loki and Tempo
datasources conditionally on whether those services are deployed, **and remove the
second enforcement of the same dependency inside `034-setup-grafana.yml`** —
which is five files, not the one-line diff CLI-F2 implied. See CLI-F12.

Independently valuable: it fixes today's broken `--skip-optional` (CLI-F1) and makes
`uis deploy grafana` usable on its own, whether or not the rest of this
investigation proceeds.

*Acceptance:* `uis deploy prometheus && uis deploy grafana` succeeds on a clean
cluster, and Grafana starts with a working Prometheus datasource and no
dangling Loki/Tempo datasources.

### PLAN-cli-stack-002-profiles

**Blocked by** the parent's `PLAN-system-observability-001-log-collection` —
the profiles name `alloy`, which is not a UIS service yet (CLI-F9). Either
sequence that plan first, or ship the profiles naming `otel-collector` and swap
the name when Alloy lands.

Add the `profiles` field to the stack schema and `--profile` to `stack install`,
with validation that lists valid profiles on error. Make `--profile` and
`--skip-optional` mutually exclusive. Leave `optional_services` in place for
stacks that declare no profiles, so `analytics` and `ai-local` are unaffected.

*Acceptance:* `uis stack install observability --profile metrics` installs
exactly the profile's components on a clean cluster and reports healthy, and
T3's must-NOT-exist assertions pass for all three profiles. **Expected-fail
before:** no `--profile` flag exists, and `--skip-optional` — the nearest
equivalent — dies at Grafana (CLI-F1).

### PLAN-cli-stack-003-sizing

Declare `resources:` for Loki, Tempo and Grafana (CLI-F4 — prerequisite), add
per-size values overlays, add `--size`, and delete the dead
`030-grafana-config.yaml` (CLI-F5). Disable `pushgateway`, Loki `gateway` and
`lokiCanary` in the small overlay (CLI-F6).

Define all three sizes, not just `small` — production is the case that needs
`medium`, and its retention windows differ in kind from `small`, not only in
magnitude.

Must also document the CLI-F10 constraint (sizes apply at install time, going up
is possible via volume expansion, going down is not) **and ship the existing-install
path from CLI-F11** — `asgard` already runs this stack, so "what happens when the
stack is already there" is the production case, not an edge case.

*Acceptance:* claims stay within the budget **for the profile installed** — the
threshold is per `(profile, size)` pair, not per size, since a `metrics` install
has three claims and a `full` install has five:

| Profile at `--size small` | Claims | Budget |
|---|---|---:|
| `metrics` | prometheus, alertmanager, grafana | ≤ 6Gi |
| `logs` | + loki | ≤ 8Gi |
| `full` | + tempo | ≤ 10Gi |

Plus: every component declares requests and limits, and Prometheus has a
`retentionSize` below its claim. **Expected-fail before:** three components
declare no resources (CLI-F4) and no `retentionSize` exists anywhere (CLI-F3).

### PLAN-cli-stack-004-platform-defaults

Resolve unspecified `--profile` / `--size` from the active platform, and print
the resolved values before installing so the behaviour is never a surprise.

*Acceptance:* on `rancher-desktop`, a bare `uis stack install observability`
installs the **`full` profile at `small` size** and says so — all signals, almost
no history, so that an instrumented app's traces arrive locally (parent PLAN-005).

---

### Scope limit: none of this makes production observability *useful*

Worth stating plainly, because the plan list above can read as a path to a
production-ready stack. It is not one.

`uis stack install observability --profile full --size medium` on asgard yields a
cluster that still **will not tell you** the database host is out of disk, or that
backups stopped a week ago. The parent investigation's two highest-severity
production findings are:

| Parent finding | What is missing | Delivered by a profile or size? |
|---|---|---|
| **OBS-F1** | no alert rules exist at all | **no** |
| **OBS-F4** | only Kubernetes is scraped — nothing outside the cluster | **no** |

Neither is expressible as a `--profile` value or a `--size`, because neither is
about *which components* or *how big*. They are the parent's `PLAN-002`
(baseline alerts) and `PLAN-004` (external targets).

**Profiles and sizes make the stack fit the machine. They do not make it useful.**
Fitting is the developer's problem; usefulness is production's. The sequencing
should say so rather than implying this CLI work moves production forward — for
asgard, the parent's PLAN-002 and PLAN-004 are worth more than everything in
Part 5.

---

## Part 6: Rollback

Observability is the system you would normally use to diagnose a bad change. If
one of these changes breaks it, that diagnostic capability is what breaks — so
each plan needs a stated way back before it starts.

| Change | Reversible? | How back |
|---|---|---|
| Grafana `SCRIPT_REQUIRES` reduced | yes, trivially | revert one metadata line and redeploy Grafana |
| `--profile` added | yes | flag is additive; omitting it preserves today's behaviour |
| Collector → Alloy | yes, with care | keep the OTel Collector manifests until Alloy is verified; both can receive OTLP during the overlap |
| `--size` **down** | **no** | PVCs cannot shrink (CLI-F10) — recreating them destroys retained data |
| `--size` **up** | yes | volume expansion, if the StorageClass allows it |

Two consequences worth designing around:

1. **Sequence the Alloy swap as add-then-remove, not replace.** Deploy Alloy
   alongside the existing collector, confirm T5 equivalence, and only then remove
   the collector. A straight swap has a window with no working telemetry path and
   no easy way back.
2. **The one-way door is `--size` downward.** It is the only change here that
   destroys data, and it should require explicit confirmation rather than being
   reachable by a flag typo.

There is no need for a `uis stack rollback` verb: every reversible item above is
either a flag omission or a normal redeploy.

---

## Part 7: Open questions for the maintainer

1. **Should `--size` be per-stack or global?** A `uis config set size small`
   applying to every stack is less typing, but observability is the only stack
   large enough to care today. Suggest per-invocation now, global later if a
   second stack needs it.
2. **Are `metrics` / `logs` / `full` the right profile names?** They are
   observability-shaped. A stack like `analytics` would want different names,
   which is fine if profiles are per-stack — but it means no cross-stack
   vocabulary like `--profile minimal`.
3. **Should a profile be recorded after install?** There is no `uis stack
   upgrade` today — the subcommands are `list`, `info`, `install`, `remove` — so
   this is about future need, not a current break. The cases that would want it:
   re-running `stack install` to add a component, `uis status` reporting what was
   intended versus what is running, and any later upgrade verb. `.uis.extend/` is
   the natural home. Cheap to add now, awkward to backfill once installs exist in
   the wild.
4. **Are the proposed retention windows right?** Part 3 now defines all three
   sizes, with `medium`/`large` differing from `small` in retention *kind*
   (30d/7d/3d rather than 7d/24h/24h). The numbers are indicative and unmeasured —
   measuring a day of asgard ingest would replace them with real ones. Sizes
   should still be documented as machine-shaped ("fits a 12 GB laptop"), not
   environment-shaped ("dev"), to avoid re-introducing the platform/size
   conflation in the naming.
5. **Does the parent's ~4 GB RAM figure hold?** It drives the opt-in decision
   (parent Q2), but the parent's appendix reports *node* usage of 4.7 GiB across
   13 services plus observability — it does not isolate the stack. Worth
   measuring the observability namespace's actual working set before sizing
   decisions rest on it.

---

## Appendix: how the findings were produced

Traced against `main` @ `ca59e7c` by source inspection, not by running a
cluster. Every claim above is reproducible with:

```bash
# CLI-F1 — the contradiction
grep -n 'observability|' provision-host/uis/lib/stacks.sh
grep -n 'SCRIPT_REQUIRES' provision-host/uis/services/observability/service-grafana.sh
sed -n '292,305p' provision-host/uis/lib/service-deployment.sh

# CLI-F3 — claims, retention, and the missing size cap
grep -nE 'size:|retention' manifests/03[0-4]-*.yaml
grep -riE 'retentionSize|retention_size' manifests/03*.yaml

# CLI-F4 — components with no resources declared
grep -c 'resources:' manifests/031-tempo-config.yaml \
                     manifests/032-loki-config.yaml \
                     manifests/034-grafana-config.yaml

# CLI-F5 — the dead values file
grep -rn '030-grafana-config' --include='*.yml' --include='*.sh' .

# CLI-F6 — defaults left unset in the Loki values
grep -cE '^(gateway|lokiCanary):' manifests/032-loki-config.yaml
```

The one thing **not** verified against a live cluster is CLI-F1's failure mode. The
code path is unambiguous, but running `uis stack install observability
--skip-optional` once would turn a traced conclusion into a measured one.
