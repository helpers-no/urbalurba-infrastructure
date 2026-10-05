# Plan: Bump Dagster from 1.13.19 to 1.13.25

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog — Phases 0-2 done 2026-10-05; Phase 3.4 (real cluster) is imac's, not mine

**Goal**: Move the pinned Dagster chart/core version from `1.13.19` to the current latest
stable (`1.13.25`) — same minor line, zero breaking changes between them — picking up a
real connection-leak fix on the exact webserver-connection-pool path this file already
documents at length, and a dequeue-performance fix for the tag-based concurrency limits
just shipped.

**Last Updated**: 2026-10-05

**Origin**: Terje, following up on the tag-concurrency-limits fix
([urb-agents#1850](https://github.com/terchris/urb-agents/issues/1850) /
[#1851](https://github.com/terchris/urb-agents/issues/1851), shipped as PR #535,
`manifests/360-dagster-config.yaml`'s `concurrency.runs.tagConcurrencyLimits`) — "plan for a
Dagster upgrade as part of the safety work added to prevent jobs from colliding."

**Phase 0 answer, corrected** ([urb-agents#1852](https://github.com/terchris/urb-agents/issues/1852)
→ corrected on [#1853](https://github.com/terchris/urb-agents/issues/1853), atlas,
2026-10-05): the first answer — `dagster==1.13.4` from `uv.lock` — was **wrong**, and atlas
caught it themselves. `atlas-data/deploy/Dockerfile` never reads `uv.lock`; it runs
`uv pip install --system --no-cache ./dagster[deploy]`, a fresh PyPI resolution at every build
bounded only by `pyproject.toml`'s `~=1.13`/`~=0.29` ranges. This is itself a known, documented
defect in that file (a 2026-09-25 incident: a floating transitive dependency shipped a
breaking SQLAlchemy version and killed every run pod) — the lockfile isn't a stale copy of the
truth, it's disconnected from it.

Checked against a real, already-published image instead (commit `311c0d8`,
`ghcr.io/terchris/atlas-data/uis:v20261004-311c0d8`,
[build log](https://github.com/terchris/atlas/actions/runs/37239325462)): **atlas-data is
already resolving `dagster==1.13.25` / `dagster-postgres==0.29.25` — exactly the platform's
target version, already.** No `pyproject.toml` change needed; every build already re-resolves
fresh, which is how it got there with zero deliberate action from anyone. Phase 1 (below) is
now "confirmed already satisfied," not "draft a bump."

**One real open question this does NOT answer**: *published* and *running on the cluster* are
different claims. Whether `1.13.25` is the image actually serving traffic right now, versus
merely built and pushed, is tracked separately on
[urb-agents#1845](https://github.com/terchris/urb-agents/issues/1845) (atlas's own deploy
request, with imac) — Phase 3's real-cluster verification needs to check this, not assume it.

**A second, durable risk this surfaced**: atlas-data's build-time floating resolution means
"what atlas-data runs" is not a fact that stays true — it can drift again on the *next*
rebuild, upward within the `~=1.13`/`~=0.29` ranges, with zero deliberate action, exactly as it
did this time. The "platform and tenants move together" assumption this plan's Phase 0 was
built to check is less a one-time fact to confirm than an ongoing property that depends on
atlas-data's build process staying unpinned the way it currently is. Worth flagging to atlas as
its own concern (that 2026-09-25 incident already argues for pinning); not this plan's to fix.

---

## Problem Summary

UIS pins Dagster at `1.13.19` (`dagster_chart_version` in
`ansible/playbooks/360-setup-dagster.yml`). The current latest stable release — both the PyPI
`dagster` package and the `dagster/dagster` Helm chart — is `1.13.25`, released 2026-10-01.
Read the real `CHANGES.md` at the `1.13.25` tag for every entry between `1.13.20` and
`1.13.25`: no `### Breaking Changes` section, no deprecation notices, in any of the six
releases. Two entries are directly relevant to work this platform has already done or just
shipped:

- **`1.13.21`** — *"Fixed a connection leak where checking for the existence of the event log
  table did not return its connection to the pool, which could exhaust the webserver's
  connection pool on instances with many asset nodes."* `manifests/360-dagster-config.yaml`
  carries a ~250-line comment block (`## 🔴 The webserver holds 21 database connections...` in
  `website/docs/services/analytics/dagster.md`) documenting exactly this pool —
  `pool_size=1, max_overflow=20`, denying unrelated reads after 30s during a check-heavy
  launch. Verified directly (not assumed from the changelog line) by installing both
  `dagster-postgres==0.29.19` and `==0.29.25` and diffing
  `dagster_postgres/event_log/event_log.py`'s table-existence check:

  ```diff
  -        return bool(self._engine.dialect.has_table(self._engine.connect(), table_name))
  +        with self._connect() as conn:
  +            return bool(self._engine.dialect.has_table(conn, table_name))
  ```

  The old code opened a connection and never returned it to the pool on this path. The fix
  doesn't remove the documented ceiling (that's `optimize_for_webserver`'s hardcoded
  `pool_size=1, max_overflow=20`, confirmed **byte-identical** between 1.13.19 and 1.13.25 —
  diffed directly, not reasoned about) — it removes one real, avoidable source of pressure on
  it.

- **`1.13.22`** — *"Run dequeuing is now significantly faster when concurrency pools are in
  use and many runs are queued, as pool state is read once per dequeue pass rather than
  repeatedly."* Directly serves the `tagConcurrencyLimits` mechanism this platform just
  shipped (PR #535) — once a tenant's rule causes runs to queue, this is the exact code path
  that drains that queue.

Also confirmed directly, not assumed: `dagster/_core/run_coordinator/queued_run_coordinator.py`
and the `concurrency` section of `dagster/_core/instance/config.py` — the mechanism `#535`
depends on — are **byte-identical** between 1.13.19 and 1.13.25. This bump changes nothing
about how `tagConcurrencyLimits` behaves; it only makes the daemon faster at acting on it.

### The real risk, checked rather than assumed

`360-dagster-config.yaml`'s own header: *"The pin is load-bearing: a code-location image pins
its own `dagster~=X.Y`, and a platform-only bump can break the gRPC handshake with it."*
Checked what actually enforces this: grepped `dagster/_grpc/` across both installed versions
for any explicit version-compatibility gate. **There is none** — no hard version check between
the webserver/daemon and a code location's gRPC server. The real risk is schema drift in the
*serialized* job/repository snapshots exchanged over that gRPC connection, which Dagster
maintains compatibility for across nearby versions but doesn't guarantee indefinitely. A
same-minor-line patch bump (`1.13.19` → `1.13.25`) is about as low-risk a version skew as
exists in this ecosystem — but "low risk" is not "no risk," and the one number that actually
determines it — what `atlas-data` currently *runs* (not what its lockfile says, which turned
out to be a different and wrong answer) — is confirmed in
[urb-agents#1853](https://github.com/terchris/urb-agents/issues/1853) at `1.13.25`/`0.29.25`:
already the target, not a gap to close.

---

## Phase 0: Confirm tenant compatibility — ANSWERED 2026-10-05, corrected same day

### Tasks

- [x] 0.1 Get atlas-data's current `dagster`/`dagster-postgres` pin from
  [urb-agents#1852](https://github.com/terchris/urb-agents/issues/1852). First answer
  (`1.13.4`, from `uv.lock`) was wrong — the Dockerfile doesn't read the lockfile. Corrected on
  [#1853](https://github.com/terchris/urb-agents/issues/1853) against a real published image:
  `dagster==1.13.25` / `dagster-postgres==0.29.25`.
- [x] 0.2 At the exact target version already: proceed as a platform-only change for the pin
  itself — Phase 1 is "confirm, don't draft."
- [ ] 0.3 ~~Meaningfully behind: coordinated bump.~~ Not the outcome, once corrected.
- [ ] 0.4 Check whether any other code location exists on any live installation (still open —
  atlas is the only tenant confirmed so far; ask whoever operates an installation other than
  atlas's, starting with imac per the #1847 incident, before treating Phase 1 as covering
  every tenant).
- [ ] 0.5 **New, from the correction itself**: confirm whether `1.13.25` is actually *running*
  on the cluster right now, not just published — see
  [urb-agents#1845](https://github.com/terchris/urb-agents/issues/1845). Needed before Phase 3
  treats "atlas's code location is already current" as a given.

### Validation — met, on the corrected answer

Atlas's actually-running-build version is known: `dagster==1.13.25` / `dagster-postgres==0.29.25`
— confirmed against a real published image's resolved dependencies, not a lockfile that turned
out to be disconnected from what the Dockerfile builds. Already at the platform's target;
0.4/0.5 remain open but don't block starting Phase 2.

---

## Phase 1: Tenant-side bump — confirmed already satisfied, nothing to draft

Originally scoped as "atlas drafts a coordinated bump," on the strength of the (wrong)
`1.13.4` answer. Atlas corrected it before drafting anything: atlas-data's build-time
resolution (not its lockfile) was already at `1.13.25`/`0.29.25` as of commit `311c0d8`,
because the Dockerfile re-resolves fresh against `pyproject.toml`'s `~=1.13`/`~=0.29` ranges on
every build, and those ranges already allowed it. Atlas's own build-time smoke tests
(asset-graph import, `dagster_postgres` importability, singular-test reachability) already ran
against this resolution and passed, or the image wouldn't have published — which covers this
plan's original "test atlas-data's own jobs against the new versions" ask.

### Tasks

- [x] 1.1 ~~Atlas drafts the bump.~~ Nothing to draft — already there. Evidence: commit
  `311c0d8`, `ghcr.io/terchris/atlas-data/uis:v20261004-311c0d8`,
  [build log](https://github.com/terchris/atlas/actions/runs/37239325462), resolved
  `dagster==1.13.25`, `dagster-postgres==0.29.25`, `dagster-dbt==0.29.25`,
  `dagster-k8s==0.29.25`, `dagster-pipes==1.13.25`, `dagster-shared==1.13.25`.
- [x] 1.2 ~~Agree rollout order (atlas publishes first, then platform bumps).~~ Collapsed —
  there's no atlas-side change to sequence ahead of the platform bump. Phase 2.5's
  `.uis.extend/dagster-code-locations.yaml` check is now "confirm this installation's entry
  already points at an image resolving `1.13.25`/`0.29.25` (e.g. `v20261004-311c0d8` or later),
  not an older one" rather than "point it at a new tag atlas is about to publish."
- [ ] 1.3 **Not resolved, optional, atlas's own call**: `uv.lock` itself still says `1.13.4` and
  is disconnected from what actually ships — a real documentation-accuracy problem (the file
  exists to tell a reader what's running and currently lies about it) but a *different* one
  from this plan's scope. Re-opened only if atlas wants it done as its own tracked item.
- [ ] 1.4 **Durable risk, not a one-time task**: atlas-data's unpinned build-time resolution
  means it can drift again, upward, on any future rebuild within the `~=1.13`/`~=0.29` ranges —
  with zero deliberate action, the same way it got to `1.13.25` this time. Flag to atlas as
  worth fixing on its own merits (ties to the 2026-09-25 floating-SQLAlchemy incident), not
  something this plan resolves by bumping the platform pin once.

### Validation — met, differently than planned

Atlas-data's build already resolves the platform's exact target version. No image needs
building or publishing for this plan's purpose; Phase 2 is not blocked on anything from
atlas-data.

---

## Phase 2: Bump the platform pin — DONE 2026-10-05

### Tasks

- [x] 2.1 `ansible/playbooks/360-setup-dagster.yml`: `dagster_chart_version: "1.13.19"` →
  `"1.13.25"`.
- [x] 2.2 **Re-verified, not relabeled, every version-specific source citation in
  `manifests/360-dagster-config.yaml`.** Installed both version pairs
  (`dagster`/`dagster-webserver`/`dagster-graphql` 1.13.19 vs 1.13.25,
  `dagster-postgres` 0.29.19 vs 0.29.25) and diffed every file a citation names:
  `queued_run_coordinator.py`, the `concurrency` section of `instance/config.py`,
  `events/__init__.py`, `storage/event_log/base.py`, `event_log.py`
  (`optimize_for_webserver`, `__init__`, `has_table`), `sql_event_log.py`,
  `dagster_webserver/cli.py`, `dagster_graphql/schema/roots/mutation.py`, and the chart's own
  `values.yaml` + `deployment-user.yaml` + `_helpers.tpl` templates (re-downloaded at 1.13.25).
  Everything claimed held, with two real findings along the way (below) and a few line-number
  shifts from unrelated additions elsewhere in those files, now cited at their new locations.
  - [x] 2.2.1 Every `(verified at the pinned 1.13.19)` / `dagster 1.13.19 / dagster_postgres
    0.29.19` citation now names `1.13.25`/`0.29.25` where the claim is about the CURRENT pin,
    or is explicitly kept as a dated "at 1.13.19" historical citation where it's describing a
    past measurement (e.g. imac's original pod reading) — not a blanket find-and-replace.
  - [x] 2.2.2 Added the `1.13.21` connection-leak fix as context next to the pool-pressure
    discussion, with the actual one-line diff (`has_table`'s `self._engine.connect()` → `with
    self._connect() as conn:`) rather than just citing the changelog sentence.
  - [x] 2.2.3/2.2.4 **Real finding, not a formality**: pulled and inspected the actual
    published `docker.io/dagster/dagster-celery-k8s:1.13.25` image's layers directly (not a
    local `pip install`, which — separately discovered — gives a WRONG answer here; see
    Implementation Notes). Webserver/daemon SQLAlchemy is `2.0.54` at this pin (was `2.0.52` at
    1.13.19) — diffed `pool/impl.py` between those two exact SQLAlchemy versions:
    byte-identical, so the QueuePool mechanism this file documents is confirmed unaffected by
    this bump. Atlas's code-location image's current SQLAlchemy could NOT be independently
    re-verified the same way (GHCR resolved the tag to a build attestation artifact, not the
    runnable image) — recorded as genuinely unverified rather than assumed, with a pointer to
    read it from the live pod instead.
- [x] 2.3 Both static tests re-run after the edits — `test-dagster-tag-concurrency-documented.sh`
  (7/7) and `test-dagster-pool-ceiling-documented.sh` (7/7) pass. The broader
  `test-config-comments-match-upstream.sh`, which asserts on this exact comment block's
  content including the `1.13.19`/`0.29.19` citation, also re-run: 28/28.
- [x] 2.4 `website/docs/services/analytics/dagster.md`: both version-specific mentions (the
  chart-version fact table row, the `concurrency.pools` paragraph) updated to `1.13.25`.
  Repo-wide `grep` for `1.13.19`/`0.29.19` also caught and fixed two more: a Jinja default
  fallback in `360-test-dagster.yml`'s error message, and this plan's own `22b1` validation
  task's comment in `360-setup-dagster.yml` (added by PR #535, citing the pin it was verified
  against). Three further hits (`361-dagster-automation.yml` ×2,
  `test-dagster-automation-start.sh`) are imac's own dated historical narrative of a past
  GraphQL introspection (`stopRunningSchedule` not `stopSchedule`) — independently
  re-confirmed unchanged at 1.13.25 by diffing `dagster_graphql`'s mutation schema directly,
  left as correctly-dated history rather than rewritten.
- [ ] 2.5 **Not checkable from this environment.** `.uis.extend/dagster-code-locations.yaml`
  is per-installation and not in this repository — whoever runs `helm upgrade` for Phase 3
  needs to confirm the real entry before/during that step, not assume it from here.
- [x] 2.6 `version.txt`: `1.6.185` → `1.6.186`.

### Validation — met

`grep -rn "1\.13\.19\|0\.29\.19"` across `manifests/`, `ansible/`, `provision-host/`, and
`website/docs/services/` (the paths this plan actually touches) returns only correctly-dated
historical citations — listed and individually checked above, none silently stale.

---

## Phase 3: Verify, the same way #535 was verified

### Tasks

- [x] 3.1 `ansible-playbook --syntax-check` on all three touched playbooks
  (`360-setup-dagster.yml`, `360-test-dagster.yml`, `361-dagster-automation.yml`) — pass.
- [x] 3.2 Full static + unit suite, `yq` genuinely installed and confirmed present (not
  silently skipped): **85/85 scripts pass** (58 static + 27 unit).
- [x] 3.3 `npm run build` in `website/` — clean, no broken anchors.
- [ ] 3.4 **Real cluster deploy — not optional, and not mine to run.** Per this repo's own
  division of labor, UIS does not build or test its own work; `imac` does. `helm upgrade` the
  chart to `1.13.25` on a real installation, and confirm:
  - [ ] 3.4.1 Webserver and daemon pods come up healthy at the new version.
  - [ ] 3.4.2 Atlas's code location is actually RUNNING the `1.13.25`/`0.29.25` build (per
    Phase 0.5/#1845 — published is not running; confirm the live pod's resolved versions, not
    just the tag `.uis.extend/dagster-code-locations.yaml` names), and loads (`LOADED`, not a
    gRPC handshake failure).
  - [ ] 3.4.3 A real run launches and completes successfully.
  - [ ] 3.4.4 The thing this bump is *for*: confirm two overlapping marts-touching runs
    actually queue — the same verification bar #1847 has been waiting on, now with both sides
    of the connection on current patch versions.

### Validation

A tester (imac) confirms 3.4 end-to-end on a real cluster and reports back on
[urb-agents#1847](https://github.com/terchris/urb-agents/issues/1847) and this plan's tracking
issue.

---

## Acceptance Criteria

- [x] Atlas's version is confirmed against what actually builds and ships, not a lockfile that
  turned out to be disconnected from it — `1.13.25`/`0.29.25`, already the target.
- [ ] Any other known tenant's version compatibility is confirmed too (Phase 0.4, still open).
- [x] Atlas-data needs no bump for this plan's purpose (Phase 1) — confirmed, not assumed.
- [ ] Confirmed that `1.13.25` is actually running on a live cluster, not just published
  (Phase 0.5 / `#1845`) — before Phase 3 treats it as a given.
- [x] `dagster_chart_version` is `1.13.25`.
- [x] Every version-specific technical claim in `manifests/360-dagster-config.yaml` is
  re-verified against real `1.13.25` source and the actual published chart image — not
  relabeled — including the webserver/daemon SQLAlchemy version, read from the real image's
  layers (`2.0.54`, confirmed unchanged mechanism via a direct `pool/impl.py` diff). Atlas's
  code-location SQLAlchemy could not be independently re-verified the same way; recorded as
  genuinely open, not assumed.
- [ ] `.uis.extend/dagster-code-locations.yaml`'s real entry is confirmed to already point at
  an image resolving `1.13.25`/`0.29.25` — not checkable from this environment (Phase 2.5).
- [x] Full static + unit suite passes with `yq` present — 85/85.
- [x] `website/` builds clean.
- [ ] A real cluster deploy confirms the webserver, daemon, and atlas's code location (its
  *running* pod, not just its published tag) all come up healthy at the new version, and that
  a real run completes.
- [ ] The tag-concurrency fix's own verification bar (#1847: two overlapping runs queue
  instead of stacking) is confirmed on the upgraded instance.

---

## Implementation Notes

- **Do not treat "no breaking changes in CHANGES.md" as "no verification needed."** This
  file's own history (the `startTimeoutSeconds` saga, the SQLAlchemy pool-churn
  misattribution, both documented in `manifests/360-dagster-config.yaml`) is a record of this
  exact repository getting Dagster's internals wrong by reasoning instead of reading the
  source at the actual pinned version. This plan's Phase 2.2 exists so the bump doesn't add a
  seventh entry to that list.
- **The gRPC-compatibility risk is real but not a hard gate** — confirmed by reading the gRPC
  layer directly, there's no version check to trip. That's exactly why Phase 0 needed a human
  answer (atlas's actual pin) rather than a grep, and why the answer — a real 15–21 patch
  version gap, not a near-miss — changed the plan's shape rather than just confirming it.
- **The first Phase 0 answer was wrong, and the way it was wrong is the more durable lesson
  than the number itself.** `uv.lock` looked like the authoritative source for "what version
  does atlas-data run" and wasn't — the Dockerfile re-resolves fresh at build time and never
  reads it. A lockfile existing is not evidence it's consulted. The fix was checking a real
  published image's actual resolved dependencies, not a more careful reading of the lockfile.
- **Atlas caught and corrected their own answer unprompted**, on a thread that was already
  closed, rather than letting a wrong "meaningfully behind" stand. That's the behavior this
  plan's Phase 0 structure was built to make cheap to act on if it happened — re-scoping twice
  in one day cost a doc edit, not a wasted implementation.
- **"Already at target" is not the same guarantee as "pinned at target."** Atlas-data's
  build-time floating resolution means this answer is a snapshot, not a fact that stays true —
  it can drift again on any future rebuild, with zero deliberate action, exactly as it drifted
  to `1.13.25` this time. Phase 1.4 names this as atlas's own concern to fix, not something
  this plan's platform-side bump resolves.
- **Published is not running — kept as a live caveat, not resolved by this correction.**
  Phase 0.5 / `#1845` is the open thread; Phase 3's real-cluster verification is where this
  actually gets checked, not assumed from a build log.
- **A fresh `pip install` today is not evidence of what an already-built image contains, and
  this almost produced a wrong answer while executing Phase 2.** SQLAlchemy released `2.1.0`
  on 2026-09-24 — a real major-within-2.x jump, and the same incident class that broke
  atlas-data's own floating build on 2026-09-25. `pip install dagster-webserver==1.13.25`
  today resolves SQLAlchemy `2.1.3`, not `2.0.54`, because `dagster` only requires
  `sqlalchemy<3,>=1.0` and a fresh resolution picks up whatever's newest and still in range —
  regardless of what was newest when the chart's own pre-built image was actually assembled
  (2026-10-01). The chart's official image pins via its own `uv` build cache and does not
  re-resolve on pull; reading the real published image's layers gave `2.0.54`, the correct
  answer, where a local install would have reported the wrong one. The general lesson this
  file already half-knew (atlas's `uv.lock` vs. real-build gap, this same session) generalizes
  further than tenant code: it applies to verifying the PLATFORM's own pinned images too.

## Files to Modify

**In this repository** (Phase 2 — done 2026-10-05):
- `ansible/playbooks/360-setup-dagster.yml` (chart pin + a stale version comment)
- `ansible/playbooks/360-test-dagster.yml` (a Jinja default-fallback version string)
- `manifests/360-dagster-config.yaml` (the full re-verification)
- `website/docs/services/analytics/dagster.md` (two version mentions)
- `provision-host/uis/tests/static/test-dagster-pool-ceiling-documented.sh` (re-run,
  unchanged, 7/7)
- `provision-host/uis/tests/static/test-dagster-tag-concurrency-documented.sh` (re-run,
  unchanged, 7/7)
- `provision-host/uis/tests/static/test-config-comments-match-upstream.sh` (re-run,
  unchanged, 28/28)
- `version.txt` (`1.6.185` → `1.6.186`)

**In `atlas-data`** (not needed for this plan — Phase 1 confirmed already satisfied):
- `uv.lock` — optional, separate cleanup (Phase 1.3), atlas's own call, not blocking.

**Per-installation, not committed to either repository** (Phase 2.5):
- `.uis.extend/dagster-code-locations.yaml`'s real tenant entry — confirm, don't change,
  unless it's pointing at something older than `v20261004-311c0d8`.

## Related

- [urb-agents#1847](https://github.com/terchris/urb-agents/issues/1847) — the deadlock
  incident this platform's concurrency fix (and this upgrade) trace back to.
- [urb-agents#1850](https://github.com/terchris/urb-agents/issues/1850) /
  [#1851](https://github.com/terchris/urb-agents/issues/1851) — the tag-concurrency-limits fix,
  shipped as PR #535.
- [urb-agents#1845](https://github.com/terchris/urb-agents/issues/1845) — the still-open
  published-vs-running question for atlas's code location, with imac.
- [urb-agents#1852](https://github.com/terchris/urb-agents/issues/1852) — the question to
  atlas; first (wrong) answer, `1.13.4`.
- [urb-agents#1853](https://github.com/terchris/urb-agents/issues/1853) — atlas's
  self-correction: actually `1.13.25`/`0.29.25`, already at target, and why the first answer
  was wrong (`uv.lock` disconnected from the real build).
- [INVESTIGATE-service-dagster.md](../backlog/INVESTIGATE-service-dagster.md) — original design record.
- [PLAN-service-dagster-001-deploy.md](../completed/PLAN-service-dagster-001-deploy.md) — the
  original deploy, including the version-pin rationale this plan inherits.
