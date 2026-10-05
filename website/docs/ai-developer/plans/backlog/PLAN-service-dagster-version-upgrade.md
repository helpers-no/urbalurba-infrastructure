# Plan: Bump Dagster from 1.13.19 to 1.13.25

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Backlog — blocked on Phase 0 (atlas's pinned version), asked 2026-10-05

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

**Blocked on**: [urb-agents#1852](https://github.com/terchris/urb-agents/issues/1852) — asked
atlas what `dagster`/`dagster-postgres` version `atlas-data`'s code-location image currently
pins. Not a formality: `manifests/360-dagster-config.yaml`'s own header says the platform pin
is load-bearing — *"a code-location image pins its own `dagster~=X.Y`... Platform and tenants
move together"* — and a tenant meaningfully behind the new platform version changes this from
a platform-only bump into a coordinated one.

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
determines it — what `atlas-data` currently pins — is asked, not assumed, in
[urb-agents#1852](https://github.com/terchris/urb-agents/issues/1852).

---

## Phase 0: Confirm tenant compatibility (blocking)

### Tasks

- [ ] 0.1 Get atlas-data's current `dagster`/`dagster-postgres` pin from
  [urb-agents#1852](https://github.com/terchris/urb-agents/issues/1852).
- [ ] 0.2 If at or near `1.13.x`: proceed with Phase 1 as a platform-only change.
- [ ] 0.3 If meaningfully behind: this plan's scope grows to a coordinated bump — atlas's own
  pin needs to move too, which is atlas's repository and atlas's call on timing, not a UIS
  platform change. Re-scope before touching any UIS file if this is the outcome.
- [ ] 0.4 Check whether any other code location exists on any live installation (this repo has
  no visibility into any installation's `.uis.extend/dagster-code-locations.yaml` — ask
  whoever operates one, starting with imac per the #1847 incident).

### Validation

Atlas's (and any other known tenant's) pinned version is known and judged close enough to
`1.13.19`/`1.13.25` that a platform-only bump is the right scope. If not, this plan stops here
and a different plan (coordinated multi-repo bump) is filed instead.

---

## Phase 1: Bump the platform pin

### Tasks

- [ ] 1.1 `ansible/playbooks/360-setup-dagster.yml`: `dagster_chart_version: "1.13.19"` →
  `"1.13.25"`.
- [ ] 1.2 **Re-verify, don't relabel, every version-specific source citation in
  `manifests/360-dagster-config.yaml`.** The file's own history is explicit about why this
  step cannot be skipped — a prior version of this exact comment block was wrong twice because
  a reading "fifteen patch releases behind gave a version-fragile answer." Confirmed already
  as part of writing this plan (see Problem Summary) that `optimize_for_webserver`'s
  `pool_size=1/max_overflow=20` and `store_event_batch`'s fast-path list are unchanged at
  `1.13.25` — carry that confirmation into the comment rather than leaving it saying "verified
  in dagster 1.13.19" once the pin no longer says that.
  - [ ] 1.2.1 Update every `(verified at the pinned 1.13.19)` / `dagster 1.13.19 /
    dagster_postgres 0.29.19` citation to name `1.13.25`/`0.29.25`, with the re-verification
    date.
  - [ ] 1.2.2 Add one line noting the `1.13.21` connection-leak fix on the `has_table` check as
    context for the pool-pressure discussion — it doesn't change the documented ceiling, but a
    reader comparing this file against a future Dagster version benefits from knowing which
    specific leak was already closed upstream.
  - [ ] 1.2.3 The SQLAlchemy version mismatch this file documents (webserver ships 2.0.52, a
    tenant's code-location image resolved 2.0.54 — same cluster, two versions) is a `dagster`
    dependency range (`sqlalchemy<3,>=1.0`), not something this bump changes by itself — note
    whether `1.13.25`'s dependency range differs, but do not assume it resolved the mismatch
    without checking the new lockfile/resolution.
- [ ] 1.3 `provision-host/uis/tests/static/test-dagster-tag-concurrency-documented.sh` and
  `test-dagster-pool-ceiling-documented.sh`: re-run after 1.2's edits — both grep for specific
  strings this plan's edits will touch.
- [ ] 1.4 `website/docs/services/analytics/dagster.md`: any version-specific text (the pool
  numbers are the chart's own, not expected to change, but check `grep -n "1.13.19" `  across
  the repo for anywhere this plan missed).
- [ ] 1.5 `version.txt`: bump — `ansible/`, `manifests/`, and `provision-host/uis/tests/` all
  changing means this ships to every installation.

### Validation

`grep -rn "1\.13\.19\|0\.29\.19"` across the repo returns nothing left unaddressed (either
updated to 1.13.25/0.29.25, or confirmed as a historical citation — e.g. "found at 1.13.19,
fixed in 1.13.21" — that is correctly dated rather than silently stale).

---

## Phase 2: Verify, the same way #535 was verified

### Tasks

- [ ] 2.1 `ansible-playbook 360-setup-dagster.yml --syntax-check` with the pinned collections
  installed.
- [ ] 2.2 Full static + unit suite, with `yq` genuinely installed (not silently skipped — see
  the static suite's own `yq` dependency).
- [ ] 2.3 `npm run build` in `website/` — clean, no broken anchors.
- [ ] 2.4 **Real cluster deploy — not optional, and not mine to run.** Per this repo's own
  division of labor, UIS does not build or test its own work; `imac` does. `helm upgrade` the
  chart to `1.13.25` on a real installation, confirm:
  - [ ] 2.4.1 Webserver and daemon pods come up healthy at the new version.
  - [ ] 2.4.2 Atlas's existing code location still loads (`LOADED`, not a gRPC handshake
    failure) — the thing Phase 0 is meant to have already de-risked, confirmed for real here.
  - [ ] 2.4.3 A real run launches and completes successfully.
  - [ ] 2.4.4 The thing this bump is *for*: apply atlas's `tag_concurrency_limits` rule (the
    installation-side step from #1850, if not already applied) and confirm two overlapping
    marts-touching runs actually queue — the same verification bar #1847 has been waiting on.

### Validation

A tester (imac) confirms 2.4 end-to-end on a real cluster and reports back on
[urb-agents#1847](https://github.com/terchris/urb-agents/issues/1847) and this plan's tracking
issue.

---

## Acceptance Criteria

- [ ] Atlas's (and any other known tenant's) version compatibility is confirmed, not assumed,
  before any platform file changes.
- [ ] `dagster_chart_version` is `1.13.25`.
- [ ] Every version-specific technical claim in `manifests/360-dagster-config.yaml` is
  re-verified against `1.13.25` source, not merely relabeled.
- [ ] Full static + unit suite passes with `yq` present.
- [ ] `website/` builds clean.
- [ ] A real cluster deploy confirms the webserver, daemon, and atlas's existing code location
  all come up healthy at the new version, and that a real run completes.
- [ ] The tag-concurrency fix's own verification bar (#1847: two overlapping runs queue
  instead of stacking) is confirmed on the upgraded instance.

---

## Implementation Notes

- **Do not treat "no breaking changes in CHANGES.md" as "no verification needed."** This
  file's own history (the `startTimeoutSeconds` saga, the SQLAlchemy pool-churn
  misattribution, both documented in `manifests/360-dagster-config.yaml`) is a record of this
  exact repository getting Dagster's internals wrong by reasoning instead of reading the
  source at the actual pinned version. This plan's Phase 1.2 exists so the bump doesn't add a
  seventh entry to that list.
- **The gRPC-compatibility risk is real but not a hard gate** — confirmed by reading the gRPC
  layer directly, there's no version check to trip. That makes Phase 0 a judgment call (how
  close is close enough) rather than a pass/fail test, which is exactly why it needs a human
  answer (atlas's actual pin) rather than a grep.
- **This plan deliberately stops at Phase 0 if atlas is meaningfully behind** rather than
  scoping in a cross-repo coordinated bump speculatively. Re-scope when that answer arrives,
  don't pre-build for every possible answer.

## Files to Modify

- `ansible/playbooks/360-setup-dagster.yml`
- `manifests/360-dagster-config.yaml`
- `website/docs/services/analytics/dagster.md`
- `provision-host/uis/tests/static/test-dagster-pool-ceiling-documented.sh` (re-run, likely
  unchanged)
- `provision-host/uis/tests/static/test-dagster-tag-concurrency-documented.sh` (re-run, likely
  unchanged)
- `version.txt`

## Related

- [urb-agents#1847](https://github.com/terchris/urb-agents/issues/1847) — the deadlock
  incident this platform's concurrency fix (and this upgrade) trace back to.
- [urb-agents#1850](https://github.com/terchris/urb-agents/issues/1850) /
  [#1851](https://github.com/terchris/urb-agents/issues/1851) — the tag-concurrency-limits fix,
  shipped as PR #535.
- [urb-agents#1852](https://github.com/terchris/urb-agents/issues/1852) — the blocking
  question to atlas.
- [INVESTIGATE-service-dagster.md](INVESTIGATE-service-dagster.md) — original design record.
- [PLAN-service-dagster-001-deploy.md](../completed/PLAN-service-dagster-001-deploy.md) — the
  original deploy, including the version-pin rationale this plan inherits.
