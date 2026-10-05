# Plan: Bump Dagster from 1.13.19 to 1.13.25

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog — Phase 0 answered 2026-10-05; re-scoped to a coordinated bump

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

**Phase 0 answer** ([urb-agents#1852](https://github.com/terchris/urb-agents/issues/1852),
atlas, 2026-10-05): atlas-data's `uv.lock`-resolved versions are **`dagster==1.13.4` /
`dagster-postgres==0.29.4`** — same `1.13` minor line, but **15 patch versions behind the
platform's current `1.13.19`, 21 behind the `1.13.25` target.** Not "already basically there."
Per this plan's own Phase 0.3, that moves this from a platform-only bump to a **coordinated**
one — see Phase 1 below. Atlas also raised a real argument for not sequencing the platform
first and atlas-data later: atlas-data is currently behind *both* fixes motivating this bump
(`1.13.21`'s connection-leak fix, `1.13.22`'s faster dequeuing under tag/pool concurrency
limits) and just started depending on the concurrency mechanism `1.13.22` improves
(`atlas/serialises-on: marts`, PR #535) — so the dequeue fix isn't hypothetical for atlas, it's
directly relevant to the thing atlas just turned on.

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
determines it — what `atlas-data` currently pins — turned out to matter: confirmed in
[urb-agents#1852](https://github.com/terchris/urb-agents/issues/1852) at `1.13.4`, 15–21
patch versions behind, not the near-miss a same-minor-line skew might suggest.

---

## Phase 0: Confirm tenant compatibility — ANSWERED 2026-10-05

### Tasks

- [x] 0.1 Get atlas-data's current `dagster`/`dagster-postgres` pin from
  [urb-agents#1852](https://github.com/terchris/urb-agents/issues/1852).
- [ ] 0.2 ~~If at or near `1.13.x`: proceed with Phase 1 as a platform-only change.~~ Not the
  outcome — see 0.3.
- [x] 0.3 Meaningfully behind (`1.13.4` vs. a `1.13.19`→`1.13.25` platform move — 15–21 patch
  versions): this plan's scope grows to a coordinated bump, per the sequencing Phase 1 below.
- [ ] 0.4 Check whether any other code location exists on any live installation (still open —
  atlas is the only tenant confirmed so far; ask whoever operates an installation other than
  atlas's, starting with imac per the #1847 incident, before treating Phase 1 as covering
  every tenant).

### Validation — met

Atlas's pinned version is known: `dagster==1.13.4` / `dagster-postgres==0.29.4`
(`uv.lock`-resolved, not just the `pyproject.toml` pin range `dagster~=1.13`). Real gap, not a
near-miss — re-scoped to Phase 1 below rather than proceeding as a platform-only change.

---

## Phase 1: Coordinate the bump — atlas-data moves with the platform, not after

Atlas's own argument (#1852): atlas-data is currently behind *both* fixes motivating this
bump, and just started depending on the mechanism `1.13.22`'s dequeue fix improves. Bumping
the platform without atlas-data would leave the tenant that most needs this on the version
with the slower dequeue path and the connection leak, while the platform documentation would
read as if the fix had landed for everyone. Sequencing atlas-data's bump with the platform's,
not after it, is the point of calling this "coordinated" rather than "platform, then maybe
atlas eventually."

### Tasks

- [ ] 1.1 Atlas drafts the `atlas-data` bump — `pyproject.toml`'s `dagster~=1.13` /
  `dagster-postgres~=0.29` pins are already wide enough to resolve `1.13.25`/`0.29.25`;
  the real work is re-running `uv lock` and testing atlas-data's own jobs against the new
  resolved versions (atlas's own repo, atlas's own call on exact timing — they've already
  offered to draft this once the coordinated plan is settled).
- [ ] 1.2 Agree the rollout order with atlas: build and publish the new atlas-data
  code-location image first (so it exists and is tagged before the platform bump lands), then
  bump the platform pin (Phase 2) and update `.uis.extend/dagster-code-locations.yaml`'s
  `tag`/`digest` to the new atlas-data image in the same change, so the installation never
  runs an old-pin code location against a new-pin instance (or vice versa) for longer than a
  single deploy cycle.
- [ ] 1.3 Confirm with atlas once their image is published and tagged before starting Phase 2.

### Validation

Atlas-data's new code-location image is built, tagged, and ready to deploy; the rollout order
is agreed before any platform file changes.

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
    without checking the new lockfile/resolution. Re-check against whatever atlas-data's
    Phase 1 bump actually resolves, too — the mismatch was measured between the webserver and
    atlas's own image, and both are changing.
  - [ ] 2.2.4 Update the webserver/daemon-vs-code-location version table in that same comment:
    it currently reads 2.0.52 (webserver) against 2.0.54 (atlas's image, pre-bump). After
    Phase 1, re-measure both.
- [ ] 2.3 `provision-host/uis/tests/static/test-dagster-tag-concurrency-documented.sh` and
  `test-dagster-pool-ceiling-documented.sh`: re-run after 2.2's edits — both grep for specific
  strings this plan's edits will touch.
- [ ] 2.4 `website/docs/services/analytics/dagster.md`: any version-specific text (the pool
  numbers are the chart's own, not expected to change, but check `grep -n "1.13.19" `  across
  the repo for anywhere this plan missed).
- [ ] 2.5 Update `.uis.extend/dagster-code-locations.yaml`'s real installation entry to atlas's
  newly-published `tag`/`digest` (Phase 1.1) in the same deploy — this is per-installation
  config, not this repo, but the sequencing matters: do not bump the platform pin on an
  installation that is still running atlas-data's old image, or vice versa.
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
  chart to `1.13.25` on a real installation, with atlas-data's new image already in place
  (Phase 1/2.5), and confirm:
  - [ ] 3.4.1 Webserver and daemon pods come up healthy at the new version.
  - [ ] 3.4.2 Atlas's code location (now on its own new pin, not the old `1.13.4`) loads
    (`LOADED`, not a gRPC handshake failure).
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

- [x] Atlas's version is confirmed, not assumed, before any platform file changes —
  `1.13.4`/`0.29.4`, meaningfully behind.
- [ ] Any other known tenant's version compatibility is confirmed too (Phase 0.4, still open).
- [ ] Atlas-data's own bump is published and tagged before the platform pin moves (Phase 1).
- [ ] `dagster_chart_version` is `1.13.25`.
- [ ] Every version-specific technical claim in `manifests/360-dagster-config.yaml` is
  re-verified against `1.13.25` source, not merely relabeled — including the
  webserver-vs-code-location SQLAlchemy version table, re-measured after Phase 1.
- [ ] `.uis.extend/dagster-code-locations.yaml`'s real entry points at atlas's new image
  tag/digest in the same deploy the platform pin moves in.
- [ ] Full static + unit suite passes with `yq` present.
- [ ] `website/` builds clean.
- [ ] A real cluster deploy confirms the webserver, daemon, and atlas's (now also bumped) code
  location all come up healthy at the new version, and that a real run completes.
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
- **This plan re-scoped exactly the way it said it would once Phase 0 answered "meaningfully
  behind."** Phase 1 (atlas-data's own bump, coordinated) exists because that was the real
  answer, not a hypothetical one planned for in the abstract.
- **Cross-repo coordination means I don't own Phase 1's execution.** Drafting atlas-data's
  `pyproject.toml`/`uv.lock` bump and publishing the new image is atlas's own repository and
  atlas's own call on timing — Phase 2 (the platform pin) should not start until Phase 1 is
  confirmed done, not just requested.

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

**In `atlas-data`** (Phase 1, atlas's own repository, not this one):
- `pyproject.toml` (pin range already wide enough — `dagster~=1.13`)
- `uv.lock` (the resolved version this plan actually cares about)

**Per-installation, not committed to either repository** (Phase 2.5):
- `.uis.extend/dagster-code-locations.yaml`'s real tenant entry

## Related

- [urb-agents#1847](https://github.com/terchris/urb-agents/issues/1847) — the deadlock
  incident this platform's concurrency fix (and this upgrade) trace back to.
- [urb-agents#1850](https://github.com/terchris/urb-agents/issues/1850) /
  [#1851](https://github.com/terchris/urb-agents/issues/1851) — the tag-concurrency-limits fix,
  shipped as PR #535.
- [urb-agents#1852](https://github.com/terchris/urb-agents/issues/1852) — atlas's answer:
  `1.13.4`/`0.29.4`, meaningfully behind, with the argument for coordinated timing.
- [INVESTIGATE-service-dagster.md](INVESTIGATE-service-dagster.md) — original design record.
- [PLAN-service-dagster-001-deploy.md](../completed/PLAN-service-dagster-001-deploy.md) — the
  original deploy, including the version-pin rationale this plan inherits.
