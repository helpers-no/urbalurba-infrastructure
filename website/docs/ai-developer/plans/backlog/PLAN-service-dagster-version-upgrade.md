# Plan: Bump Dagster from 1.13.19 to 1.13.25

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog — Phase 0/1 resolved 2026-10-05: atlas-data is already on target, platform-only bump remains

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

## Phase 2: Bump the platform pin

### Tasks

- [ ] 2.1 `ansible/playbooks/360-setup-dagster.yml`: `dagster_chart_version: "1.13.19"` →
  `"1.13.25"`.
- [ ] 2.2 **Re-verify, don't relabel, every version-specific source citation in
  `manifests/360-dagster-config.yaml`.** The file's own history is explicit about why this
  step cannot be skipped — a prior version of this exact comment block was wrong twice because
  a reading "fifteen patch releases behind gave a version-fragile answer." Confirmed already
  as part of writing this plan (see Problem Summary) that `optimize_for_webserver`'s
  `pool_size=1/max_overflow=20` and `store_event_batch`'s fast-path list are unchanged at
  `1.13.25` — carry that confirmation into the comment rather than leaving it saying "verified
  in dagster 1.13.19" once the pin no longer says that.
  - [ ] 2.2.1 Update every `(verified at the pinned 1.13.19)` / `dagster 1.13.19 /
    dagster_postgres 0.29.19` citation to name `1.13.25`/`0.29.25`, with the re-verification
    date.
  - [ ] 2.2.2 Add one line noting the `1.13.21` connection-leak fix on the `has_table` check as
    context for the pool-pressure discussion — it doesn't change the documented ceiling, but a
    reader comparing this file against a future Dagster version benefits from knowing which
    specific leak was already closed upstream.
  - [ ] 2.2.3 The SQLAlchemy version mismatch this file documents (webserver ships 2.0.52, a
    tenant's code-location image resolved 2.0.54 — same cluster, two versions) is a `dagster`
    dependency range (`sqlalchemy<3,>=1.0`), not something this bump changes by itself — note
    whether `1.13.25`'s dependency range differs, but do not assume it resolved the mismatch
    without checking the new resolution. Atlas's image (commit `311c0d8`) is already at
    `1.13.25`/`0.29.25` — re-measure ITS SQLAlchemy resolution for real rather than assuming
    the old `2.0.54` reading still holds; it was taken against the `1.13.4` build.
  - [ ] 2.2.4 Update the webserver/daemon-vs-code-location version table in that same comment:
    it currently reads 2.0.52 (webserver) against 2.0.54 (atlas's image, measured at the old
    `1.13.4` resolution — now stale on both the dagster version and possibly the SQLAlchemy
    one). Re-measure both sides fresh after the platform bump.
- [ ] 2.3 `provision-host/uis/tests/static/test-dagster-tag-concurrency-documented.sh` and
  `test-dagster-pool-ceiling-documented.sh`: re-run after 2.2's edits — both grep for specific
  strings this plan's edits will touch.
- [ ] 2.4 `website/docs/services/analytics/dagster.md`: any version-specific text (the pool
  numbers are the chart's own, not expected to change, but check `grep -n "1.13.19" `  across
  the repo for anywhere this plan missed).
- [ ] 2.5 Confirm `.uis.extend/dagster-code-locations.yaml`'s real installation entry already
  points at an atlas-data image resolving `1.13.25`/`0.29.25` (`v20261004-311c0d8` or later) —
  per-installation config, not this repo, but check rather than assume, and per Phase 0.5,
  separately confirm that entry's image is actually the one running, not just what the file
  says.
- [ ] 2.6 `version.txt`: bump — `ansible/`, `manifests/`, and `provision-host/uis/tests/` all
  changing means this ships to every installation.

### Validation

`grep -rn "1\.13\.19\|0\.29\.19"` across the repo returns nothing left unaddressed (either
updated to 1.13.25/0.29.25, or confirmed as a historical citation — e.g. "found at 1.13.19,
fixed in 1.13.21" — that is correctly dated rather than silently stale).

---

## Phase 3: Verify, the same way #535 was verified

### Tasks

- [ ] 3.1 `ansible-playbook 360-setup-dagster.yml --syntax-check` with the pinned collections
  installed.
- [ ] 3.2 Full static + unit suite, with `yq` genuinely installed (not silently skipped — see
  the static suite's own `yq` dependency).
- [ ] 3.3 `npm run build` in `website/` — clean, no broken anchors.
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
- [ ] `dagster_chart_version` is `1.13.25`.
- [ ] Every version-specific technical claim in `manifests/360-dagster-config.yaml` is
  re-verified against `1.13.25` source, not merely relabeled — including the
  webserver-vs-code-location SQLAlchemy version table, re-measured against atlas's actual
  current resolution, not the stale `1.13.4`-era reading.
- [ ] `.uis.extend/dagster-code-locations.yaml`'s real entry is confirmed to already point at
  an image resolving `1.13.25`/`0.29.25`.
- [ ] Full static + unit suite passes with `yq` present.
- [ ] `website/` builds clean.
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

## Files to Modify

**In this repository** (Phase 2+):
- `ansible/playbooks/360-setup-dagster.yml`
- `manifests/360-dagster-config.yaml`
- `website/docs/services/analytics/dagster.md`
- `provision-host/uis/tests/static/test-dagster-pool-ceiling-documented.sh` (re-run, likely
  unchanged)
- `provision-host/uis/tests/static/test-dagster-tag-concurrency-documented.sh` (re-run, likely
  unchanged)
- `version.txt`

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
- [INVESTIGATE-service-dagster.md](INVESTIGATE-service-dagster.md) — original design record.
- [PLAN-service-dagster-001-deploy.md](../completed/PLAN-service-dagster-001-deploy.md) — the
  original deploy, including the version-pin rationale this plan inherits.
