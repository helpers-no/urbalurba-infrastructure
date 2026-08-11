# Plan: The Grafana deploy gate reports the stack, not the race

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

## Status: Active — Phases 1–3 done and verified; Phase 4 (move E2E to a verify playbook) open

**Goal**: Make `uis deploy grafana` succeed deterministically on a healthy stack,
so an automated stand-up never reports failure for telemetry that merely had not
flushed yet.

**Last Updated**: 2026-08-11

---

## Dependencies

**Investigation**: [INVESTIGATE-system-observability](../backlog/INVESTIGATE-system-observability.md) — **OBS-F6**.

**Prerequisites**: none.

**Blocks**: nothing formally, but every automated observability stand-up inherits
this flake, so it gates the "recreate everything, nothing hand-coded" requirement.

**Priority**: High

---

## Problem Summary

`034-setup-grafana.yml` gated the whole deployment on seven checks. Four are
connectivity ("does the datasource answer"). Three are round-trips: push
telemetry via OTLP, then query it back through Grafana.

The round-trips race the backends. Tempo does not make a trace searchable until
it flushes a block; the collector's log pipeline has its own lag. Given 15–30
seconds of patience, they fail on a stack that is entirely healthy.

Three consecutive runs against the same healthy reference installation failed on
**three different checks** — first Loki and Tempo, then neither, then the
Prometheus data query. That is the signature of a timing race, not a broken
stack.

The consequence is worse than a red line in a log. Task 20 aborts the play, so
the `enable` step never runs and **no dashboard is ever applied**. Grafana ends
up running and reported `✅ Deployed` by `uis list`, but absent from
`uis list-enabled` — the failure mode recorded as OBS-F6.

**The conflation is the bug:** "a probe did not verify" is not "the stack is
broken", and only the second justifies aborting a deployment.

---

## Phase 1: Separate reporting from gating

### Tasks

- [x] 1.1 Remove the two round-trip probes from task 20's `when:` condition, so
      they no longer abort the deploy
- [x] 1.2 Add task 20b — a loud, unconditional report of the round-trip result,
      passing or failing, with the `kubectl logs` command to investigate
- [x] 1.3 Comment task 20 with *why* the condition shrank, so the probes are not
      quietly restored to the gate later

### Validation

`uis deploy grafana` completes on a healthy stack; dashboards are applied; the
round-trip outcome is still visible in the output.

---

## Phase 2: Give the remaining checks real patience

The gate is only honest if the checks it *does* keep are deterministic.

### Tasks

- [x] 2.1 Task 13 (Prometheus data query — now the only round-trip that still
      gates): 3×10s → 12×10s. On a cold cluster Prometheus has not completed its
      first scrape when Grafana comes up; 30s was not enough.
- [x] 2.2 Task 16 (Loki round-trip): 3×5s → 12×5s
- [x] 2.3 Task 19 (Tempo round-trip): 3×5s → 12×10s — the block flush is the
      slowest step in the suite, so it gets the widest window

### Validation

Deploy against the reference installation and confirm `failed=0`.

**Result (2026-08-11, host 192.168.68.52):**

```
PLAY RECAP: ok=30  changed=12  unreachable=0  failed=0  skipped=3
✓ Grafana deployed successfully
```

Task 13 consumed one retry and then passed — precisely the flake that used to
abort the deploy. Health, all three datasources, the Prometheus data query and
the Tempo round-trip reported PASS. The Loki round-trip reported FAIL, **non-
fatally**, exactly as designed.

---

## Phase 3: Close the remaining Loki round-trip failure

Phase 2 proved the gate is correct. It did not prove the Loki pipeline is.

**The hypothesis in this section was wrong, and measuring killed it.** It guessed
a label mismatch — that the probe selects `{service_name="telemetrygen"}` while
the generator tags `service.name="grafana-e2e-validation"`. Sending the exact
payload the playbook sends and then querying Loki showed the probe is right:

```
service_name:            "telemetrygen"              <- what the probe queries
service_name_extracted:  "grafana-e2e-validation"
test_type:               "grafana-datasource-test"   <- what the probe asserts on
```

`--telemetry-attributes service.name=...` does not become the stream label; the
resource attribute does, and it is `telemetrygen`. Running task 16's exact
command by hand returned `"status":"success"` and the asserted string, rc=0.
Probe correct, pipeline correct.

### The actual defect: the retry budget outgrew the query window

Both round-trip probes query a **120-second lookback** (`START=$((NOW-120))`).
Phase 2 gave Tempo 12×10s = **exactly 120s** of retries and Loki 12×5s = 60s.

So the two windows were coupled, and nobody had noticed. On the later attempts
the probe searches a period that no longer contains the telemetry *it just sent* —
and every additional retry makes it strictly worse rather than better. Phase 2's
widening had quietly pushed Tempo to the exact edge of its own window.

That also explains the signature that started this whole plan: a probe that
passes, then fails, then passes, with nothing about the stack changing.

### Tasks

- [x] 3.1 Query Loki directly for both label values — establishes the probe is
      correct and the pipeline delivers
- [x] 3.2 Decouple the two windows: lookback 120s → 900s on both probes, so the
      retry budget sits well inside the period being searched
- [x] 3.3 Give the Loki probe the same 12×10s patience as Tempo, now that the
      window can accommodate it
- [x] 3.4 Re-deploy from a **cold** Grafana and confirm task 20b reports OK

### Validation

Two consecutive deploys, each from a deliberately deleted Grafana pod so the
start-up race is present rather than avoided:

| | run 1 | run 2 |
|---|---|---|
| all seven checks | PASS | PASS |
| task 20b | OK | OK |
| PLAY RECAP | `failed=0` | `failed=0` |
| widest probe | 7/12 retries | 8/12 retries |

Headroom is real but not vast — task 16 is the one to watch if this regresses.

### Rejected: a datasource-provisioning readiness gate

A task 9b was written first, polling `/api/datasources` until all three appear,
on the theory that the proxy checks were racing sidecar provisioning. **Measured
and removed**: it passed with **0 retries** while tasks 10 and 11 still needed
55–60s. Datasource *registration* is immediate; what is slow is Grafana's proxy
reaching a backend on a cold pod. A gate that always passes instantly gates
nothing and is worse than no gate, because it reads like protection.

---

## Phase 4: Put the E2E tests where the guide says they go

Phases 1–3 treat the symptom. The structural problem is that
`034-setup-grafana.yml` is doing a **verify playbook's** job.

[adding-a-service.md](../../../contributors/guides/adding-a-service.md) Step 5b is
explicit: E2E tests belong in `NNN-test-<id>.yml`, reached via
`./uis verify <service>`. The setup playbook deploys and confirms readiness;
round-trip validation is a separate, on-demand concern.

Grafana has **no verify playbook at all** — which is why its E2E tests ended up
welded into the deploy path, where a slow flush becomes a failed deployment. Ten
other services already follow the convention (`031-test-alloy.yml`,
`045-test-minio.yml`, …). Grafana is the outlier.

### Tasks

- [ ] 4.1 Create `ansible/playbooks/034-test-grafana.yml`, moving tasks 14–19 and
      20b out of the setup playbook, in the guide's run/assert/display shape
- [ ] 4.2 Register in `VERIFY_SERVICES` (`provision-host/uis/lib/integration-testing.sh`)
- [ ] 4.3 Add the `grafana)` dispatch arms in `uis-cli.sh` — **both** of them, see
      the note below
- [ ] 4.4 Reduce the setup playbook's gate to connectivity + readiness only
- [ ] 4.5 Document `./uis verify grafana` on the Grafana service page

### Note: Step 5b registration is a two-place change, and it is being missed

The guide names two registration points. There is in practice a third, and
services that miss it are silently unreachable:

| Invocation | Dispatch site | 
|---|---|
| `uis verify <id>` | the `case` in `cmd_verify()` (~line 2022) |
| `uis <id> verify` | the main command `case` (~line 2776) |

`VERIFY_SERVICES` stores the **second** form (`alloy:alloy verify`), so
`test-all` uses it — but only `minio` and `argocd` actually register it.
Verified on the reference installation:

```
uis alloy verify        -> ✗ Unknown command: alloy
uis verify alloy        -> ✗ (absent from the verify list)
uis uptime-kuma verify  -> ✗ Unknown command: uptime-kuma
uis minio verify        -> ✓ runs 045-test-minio.yml
```

So `031-test-alloy.yml` is dead code today — reachable by no command — and
uptime-kuma's verify is reachable interactively but not by `test-all`. Grafana
must not repeat this. **This is a defect in its own right and deserves its own
plan; it is recorded here only because it would otherwise be repeated by 4.3.**

### Validation

`./uis verify grafana` runs the round-trips on demand and `./uis deploy grafana`
no longer contains them.

---

## Out of Scope

- Making Loki and Tempo datasources optional — that is
  [PLAN-service-grafana-optional-datasources](./PLAN-service-grafana-optional-datasources.md).
- Retention tuning for either backend.

---

## Process Note

Phases 1 and 2 were implemented and verified **before** this plan was written,
which inverts the WORKFLOW.md order. The change is uncommitted in the working
tree (`ansible/playbooks/034-setup-grafana.yml`) and is recorded here so it can
be reviewed as a plan rather than landed as an untracked fix.
