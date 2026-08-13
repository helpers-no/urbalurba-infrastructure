# INVESTIGATE: `./uis status` doesn't show multi-instance services

**Status:** Investigation complete — ready for PLAN
**Created:** 2026-05-14
**Updated:** 2026-05-15 (decisions locked in; root cause confirmed)
**Surfaced by:** talk53 F5 (Tailscale CLI port verification) — tester noticed `railway-postgrest` deployment running healthily but absent from `./uis status` output.
**Related to:** [INVESTIGATE-docs-customer-onboarding-database](../backlog/INVESTIGATE-docs-customer-onboarding-database.md) (the Railway customer onboarding flow that motivated multi-instance PostgREST in the first place), PLAN-002 / customer-onboarding work expanding the `--app <name>` pattern to more services.

---

## Problem Statement

`./uis status` and `./uis list` don't surface per-instance detail for multi-instance services. When a service like `postgrest` is deployed via the `--app <name>` pattern (e.g. `./uis deploy postgrest --app atlas` + `./uis deploy postgrest --app railway`), each app gets its own Kubernetes Deployment + Service in the shared `postgrest` namespace (`atlas-postgrest`, `railway-postgrest`). But the status/list commands collapse all of them into a single `postgrest` row — the user cannot see from the official "what's healthy" surface:

- How many instances are running.
- Which apps own them.
- What Kubernetes Service name to type into `./uis network expose tailscale <name>` (this is the team-share use case: pick an instance from the status output and expose it via Tailscale Funnel).

See "Root cause (confirmed)" below for what the code is actually doing.

## Symptom — talk53 evidence (original report, partially superseded)

The tester originally reported postgrest as missing entirely from the status output:

```
$ ./uis status
ID                NAME              CATEGORY     HEALTH
nginx             Nginx             MANAGEMENT   ✅ Healthy
whoami            Whoami            MANAGEMENT   ✅ Healthy
postgresql        PostgreSQL        DATABASES    ✅ Healthy
tailscale-tunnel  Tailscale Tunnel  NETWORKING   ✅ Healthy
traefik           Traefik           NETWORKING   ✅ Healthy
```

…while the deployments were demonstrably healthy:

```
$ kubectl -n postgrest get pods
NAME                                 READY   STATUS    RESTARTS   AGE
atlas-postgrest-b945447b5-shr5c      1/1     Running   0          8d
atlas-postgrest-b945447b5-wt6dp      1/1     Running   0          8d
railway-postgrest-7dc674c4f9-jk66h   1/1     Running   0          47h
railway-postgrest-7dc674c4f9-kn57x   1/1     Running   0          47h

$ kubectl get ingressroutes -A | grep postgrest
postgrest   atlas-postgrest        8d
postgrest   railway-postgrest      47h

$ curl -o /dev/null -w "%{http_code}\n" http://api-railway.localhost/
200
```

**Reading the symptom against the current code (per "Root cause" below): the "no postgrest row at all" output likely reflects a pre-label state on the 8-day-old `atlas-postgrest` deployment** (the `app.kubernetes.io/name=postgrest` label was added to the template at a date that may post-date that deployment). On a freshly-deployed cluster today, `./uis status` would show a single `postgrest ✅ Healthy` row — and the gap shifts from "invisible" to "one binary row regardless of instance count." Either framing motivates the same fix.

## Root cause (confirmed 2026-05-15)

`cmd_status` (in `provision-host/uis/manage/uis-cli.sh:262`) and `cmd_list` (line 195) both iterate `get_all_service_ids()` — which scans `provision-host/uis/services/` and returns every `SCRIPT_ID` — and run each service's `SCRIPT_CHECK_COMMAND`. **Postgrest IS in this iteration today.**

The actual gap is **not** "postgrest is invisible." The actual gap is **one row regardless of instance count**:

- Postgrest's check command is `kubectl get deploy -n postgrest -l app.kubernetes.io/name=postgrest --no-headers | grep -qE '\s([1-9][0-9]*)/\1\s'`.
- This matches **any** deployment in the `postgrest` namespace carrying the `app.kubernetes.io/name=postgrest` label.
- When `atlas-postgrest` and `railway-postgrest` are both running, the check passes and `./uis status` shows a single `postgrest ✅ Healthy` row.
- The user **cannot** see from the status output how many instances are running, which apps own them, or what Kubernetes Service name to type into `./uis network expose tailscale <name>`.

The talk53 evidence ("no postgrest row at all") likely reflects a pre-label state on a deployment that's 8 days older than the current `app.kubernetes.io/name=postgrest` template — not a current-code defect. The principle this investigation solves is real regardless: multi-instance services need per-instance visibility, not a single binary-OK summary.

## Why it matters

For solo development the gap is cosmetic — the user knows what they deployed and can `kubectl` directly.

For **customer onboarding** (per the [INVESTIGATE-docs-customer-onboarding-database](../backlog/INVESTIGATE-docs-customer-onboarding-database.md) flow with the Railway customer) the gap is misleading in either failure mode:

- If postgrest appears as one binary `✅ Healthy` row (the today-on-fresh-deploy case), the novice can't tell whether their `atlas-postgrest` is running, whether `railway-postgrest` is also there, or what string to type to expose theirs via Tailscale. The signal is technically accurate but operationally useless.
- If postgrest doesn't appear at all (the talk53 case, attributable to a stale-label state), the novice assumes their deployment failed and starts debugging the wrong thing — same false-negative flavour as talk52 F4 ("Tailscale deploy reported FAILED but actually worked").

The fix lands per-instance visibility, eliminating both modes at once.

The `--app <name>` pattern is also the direction PLAN-002 / customer-onboarding work is expanding (likely to `redis --app foo`, future per-customer postgresql namespaces, etc.). Each new multi-instance service that adopts the pattern inherits the same gap unless we fix it at the framework level.

## Fix candidates

### 1. Extend `./uis status` + `./uis list` to iterate multi-instance services ← **CHOSEN**

For each multi-instance service type (`postgrest` today; future `redis`, etc.), enumerate `<app>-<service>` deployments in the service's namespace and print each as its own row, using the Kubernetes deployment name as the row ID (so the same string can be typed into `./uis network expose tailscale ...`, `kubectl describe deploy -n <ns> ...`, etc.):

```
ID                NAME         CATEGORY      HEALTH
postgresql        PostgreSQL   DATABASES     ✅ Healthy       ← single-instance, unchanged
atlas-postgrest   PostgREST    INTEGRATION   ✅ Healthy       ← multi-instance row
railway-postgrest PostgREST    INTEGRATION   ✅ Healthy       ← multi-instance row
```

- **Pro**: matches user mental model ("what's running?" → "I want to see every running thing")
- **Pro**: ID column is the **actionable identifier** — same string the user types into `./uis network expose tailscale <name>` or `kubectl describe deploy`. Critical for the team-share flow where a user reads the status output, picks an instance, and exposes it via Tailscale Funnel.
- **Pro**: rows sort naturally — `atlas-postgrest` and `railway-postgrest` cluster alphabetically.
- **Pro**: single-instance services unchanged.
- **Pro**: same iteration helper feeds `./uis list` (parallel gap fixed in the same PR).

### 2. Add `./uis status --apps` opt-in flag — **rejected**

Default output unchanged; opt-in flag shows multi-instance variants. **Rejected**: novices won't discover the flag, so the discoverability gap stays the default. Defeats the false-negative-prevention principle.

### 3. Single-line summary at the bottom — **rejected**

Under the per-service table, add a "Multi-instance:" line listing instance counts. **Rejected**: instances don't get health-state info, so it's not actually "status." Half-measure.

## Open questions — answered

1. **Where does multi-instance metadata live?** ✅ Already exists:
   - `SCRIPT_MULTI_INSTANCE="true"` on the service script (e.g. `provision-host/uis/services/integration/service-postgrest.sh:32`).
   - Propagates to `services.json` as `multiInstance: true`.
   - Two helpers query it today: `_is_service_multi_instance` (`provision-host/uis/lib/service-deployment.sh:77`) and `_is_multi_instance` (`provision-host/uis/lib/configure.sh:42`). They're functionally identical — the PLAN consolidates these into one canonical helper (`_is_service_multi_instance`) and updates both call sites.
   - No new fields needed.

2. **Health-check command per instance.** ✅ The existing `SCRIPT_CHECK_COMMAND` stays as-is on multi-instance service scripts; it's still used by `check_service_deployed` from `lib/service-scanner.sh:106`, which is called by deploy/undeploy/dep-check code paths in `lib/service-deployment.sh:199, 297, 340`. Changing it would have wider blast radius than this PLAN wants.

   For status/list display only, the runtime composes a per-instance check by listing the actual deployments and parsing kubectl's standard output:
   ```bash
   kubectl get deploy -n "$SCRIPT_NAMESPACE" -l "app.kubernetes.io/name=$SCRIPT_ID" --no-headers
   ```
   Output (one row per deployment):
   ```
   atlas-postgrest      2/2   2   2   8d
   railway-postgrest    2/2   2   2   47h
   ```
   Parse column 1 (`NAME` — already `<app>-<service>` by deployment naming convention; this becomes the row ID) and column 2 (`READY`, e.g. `2/2`). A deployment is healthy iff column 2 matches `^([1-9][0-9]*)/\1$` — same regex shape postgrest's current `SCRIPT_CHECK_COMMAND` uses, just applied per row.

3. **`./uis list` parity.** ✅ YES — same gap. Both `cmd_status` and `cmd_list` iterate `get_all_service_ids()` and run `SCRIPT_CHECK_COMMAND`. Fix bundles both; same iteration helper feeds both commands.

4. **Naming in output.** ✅ Use the Kubernetes deployment/Service name (`atlas-postgrest`) as the ID column. NAME column = `$SCRIPT_NAME` only (no `(atlas)` parenthetical — the app discriminator is already in the ID).
   - Rationale: the ID is the **actionable identifier** — same string a user types into `./uis network expose tailscale <name>`, `kubectl describe deploy -n postgrest <name>`, etc. The team-share flow ("see what's running → expose one via Tailscale Funnel") depends on this string being visible.
   - Asymmetry-with-other-verbs noted: `./uis deploy postgrest --app atlas` uses `<service> --app <name>` form, while `./uis network expose tailscale atlas-postgrest` uses the Service name. The status output exposes the Kubernetes-real name; the deploy/configure verbs translate `--app` → `<app>-<service>` internally. A future cleanup could make `./uis deploy atlas-postgrest` a synonym, but that's a separate INVESTIGATE — not blocking this fix.

5. **Cross-namespace pattern.** ✅ Read `SCRIPT_NAMESPACE` from the service script. Postgrest sets `SCRIPT_NAMESPACE="postgrest"`. The iteration logic queries `kubectl get deploy -n $SCRIPT_NAMESPACE -l app.kubernetes.io/name=$SCRIPT_ID`. This works for any multi-instance service that shares a single namespace across instances (postgrest's pattern). A future multi-instance service that uses *per-app* namespaces (e.g. `atlas` and `railway` namespaces instead of all-in-`postgrest`) wouldn't fit a single `SCRIPT_NAMESPACE` value — see C-7 for that out-of-scope future case.

## Outcomes — decided

- [x] Confirm the root cause by reading `cmd_status` + the postgrest service's metadata — see "Root cause (confirmed)" section above.
- [x] Decide on metadata vs. convention for multi-instance detection — **metadata**, via the existing `SCRIPT_MULTI_INSTANCE` / `multiInstance` flag.
- [x] Pick a fix candidate (1 / 2 / 3 / hybrid) — **Option 1**, with the deployment name as the row ID.
- [x] Verify whether `./uis list` has the same gap and bundle the fix if so — YES; bundled.
- [x] Decide naming convention for the status row — ID = `<app>-<service>` (deployment/Service name); NAME = `$SCRIPT_NAME`.

## Implementation Contracts — locked

- **C-1: Multi-instance metadata.** Use the existing `SCRIPT_MULTI_INSTANCE="true"` flag (already on `service-postgrest.sh`; already in `services.json` as `multiInstance: true`). Consolidate the two duplicate helpers `_is_service_multi_instance` (lib/service-deployment.sh) and `_is_multi_instance` (lib/configure.sh) into one canonical `_is_service_multi_instance` in `lib/service-deployment.sh`; update the `lib/configure.sh:216` call site.

- **C-2: Per-instance iteration (status + list display only).** For each service with `SCRIPT_MULTI_INSTANCE="true"`, run:
  ```bash
  kubectl get deploy -n "$SCRIPT_NAMESPACE" -l "app.kubernetes.io/name=$SCRIPT_ID" --no-headers 2>/dev/null
  ```
  Parse column 1 (deployment name = `<app>-<service>`) as the row ID; column 2 (`READY`, e.g. `2/2`) for health — healthy iff column 2 matches `^([1-9][0-9]*)/\1$`.

  Behaviour for each case, matching today's single-instance asymmetry between `cmd_status` (only-healthy) and `cmd_list` (always-show-row):

  | Case | `cmd_status` | `cmd_list` |
  |---|---|---|
  | Deployment exists, healthy (e.g., `2/2`) | one `✅ Healthy` row | one `✅ Deployed` row |
  | Deployment exists, degraded (e.g., `1/2`, `0/2`) | no row (same as today's check-failed behaviour for single-instance) | one `⚠ Degraded (<ready>/<replicas>)` row |
  | Zero deployments matching the label selector | no row | one `❌ Not deployed` row for the service-type (ID = `$SCRIPT_ID`) |
  | kubectl error / no cluster | no row | no row for that service (kubectl-error path same as single-instance) |

  **SCRIPT_CHECK_COMMAND on the service script stays unchanged.** It's still used by `check_service_deployed` (lib/service-scanner.sh:106), which is called by `lib/service-deployment.sh:199, 297, 340` for deploy/undeploy/dep-check paths. Those paths only care about "is the service-class active at all," which the current check correctly answers. The per-instance iteration is a *display-side* override used only by `cmd_status` and `cmd_list`.

- **C-3: Status / list output format.**
  - Single-instance row (unchanged): `<SCRIPT_ID>  <SCRIPT_NAME>  <SCRIPT_CATEGORY>  ✅ Healthy`
  - Multi-instance row (new): `<deployment-name>  <SCRIPT_NAME>  <SCRIPT_CATEGORY>  ✅ Healthy`
  - `<deployment-name>` comes directly from `.metadata.name` on each Deployment (e.g. `atlas-postgrest`). No label parsing needed — the deployment name is the actionable identifier the user types into `./uis network expose tailscale <name>` or `kubectl describe deploy -n postgrest <name>`.
  - Header row unchanged. Column widths unchanged (existing `%-15s %-20s %-12s %s` format handles `atlas-postgrest` (15 chars) and `railway-postgrest` (17 chars — overflow visible but no truncation of subsequent columns since `%-15s` left-pads but doesn't truncate). PLAN should validate column widths against the widest expected `<app>-<service>` name and bump the format if needed.
  - Note about the `app.kubernetes.io/instance` label: it's set to just `<app>` (e.g. `atlas`) per the postgrest template (`088-postgrest-config.yml.j2:20`), NOT `<app>-<service>`. The PLAN's iteration uses `.metadata.name` instead because that's the user-facing string.

- **C-4: `./uis list` parity.** Same iteration helper feeds both `cmd_list` and `cmd_status`; behaviour per state is documented in the table under C-2. Bundled in the same PR. Single-instance services in `cmd_list` are unchanged (still show `Deployed` / `Not deployed` / `No check` from the existing `SCRIPT_CHECK_COMMAND` path).

- **C-5: Backwards compatibility.** Interactive readers see more useful detail (a strict improvement). Scripts doing `./uis status | grep '^postgrest'` no longer match — the row is now `atlas-postgrest` / `railway-postgrest`. Mitigation: document the change in the PR body; suggest `./uis status | awk '$1 ~ /-postgrest$/'` as the migration pattern. Acceptable cost — the current users of `./uis status` are interactive, not scripts.

- **C-6: talk53 mystery — explicitly out of scope.** The PLAN does **not** include a phase to reproduce the talk53 "no postgrest row at all" symptom. That output likely reflected a pre-label state on an 8-day-old `atlas-postgrest` deployment, not a current-code defect. Tester verification on the new code path will catch any label-mismatch on freshly-deployed instances.

- **C-7: Single-namespace assumption.** The iteration in C-2 assumes all instances of a multi-instance service share a single `SCRIPT_NAMESPACE`. This holds for postgrest today and matches the convention documented in `service-postgrest.sh` ("UIS deploys one PostgREST instance per consuming application; all instances share a namespace"). If a future multi-instance service deploys per-app namespaces (`atlas` / `railway` namespaces instead of all-in-`postgrest`), the iteration shape needs revisiting. Out of scope for this PLAN — flagged as a known assumption.

- **C-8: Tests.** No tests cover `cmd_status` or `cmd_list` today (verified by grep). The PLAN should decide whether to add unit/integration coverage for the multi-instance iteration path, especially the zero-instance / unreachable-kubectl edge cases. Recommendation: add at least one static test that asserts the format of the kubectl-output parsing (mockable without a cluster); defer integration coverage to tester verification.
