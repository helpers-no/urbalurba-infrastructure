# Plan: a command that loads the data, and a command that reports on it

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Backlog — filed 2026-09-10 from `imac`'s novice grading
(`urb-agents#506`), BLOCKING 5 and 6. Nothing here is a defect in what exists;
it is surface that does not exist.

🔴 **This plan was announced before it was written.** I told `imac` on #506 that
these were "filed, not rushed" and that their framing was "in the plan
verbatim", and no plan existed for another twenty minutes. Recorded because it
is the same announced-action-not-taken shape this repository has spent a week
removing, committed in the message reporting on it.

**Goal**: after `uis template install <id>` succeeds, a user can load the
application's data and see whether it worked, without knowing Dagster.

---

## Why, in the words of the person who hit it

> *The install succeeds about two times in three, and when it succeeds the user
> cannot use the result. Ten minutes of ingest gives a fully working API — 2.9M
> rows, 13 endpoints — and nothing in the product tells them that is possible.*

Atlas installs, answers HTTP 200, and serves **zero rows**. That is correct
behaviour — the schema and grants are the install-time guarantee, the data
arrives on the ingest schedule — and it is indistinguishable from a broken
install to someone seeing it for the first time.

---

## Phase 1 — `uis dagster materialize`

🔴 **Load-now and keep-fresh are two different operations, and today only the
second exists.** That distinction is `imac`'s and it is the thing to get right:

| | who wants it | what it does |
|---|---|---|
| `./uis dagster materialize --all` | someone evaluating the application | loads the data **now** (~10 min for atlas) |
| `./uis dagster automation --start` | an operator going live | keeps it fresh (weekly Sun 02:00) |

⚠️ **`--start` alone is not a substitute and would strand a novice.** Measured:
every automation condition is cron-based — 37 assets on weekly Sunday 02:00
(+63 h), 3 on monthly 1st (+20 days), and 74 of 114 assets carry no condition at
all. `transform_daily` is +18 h and would transform data not yet fetched. So
enabling the schedules leaves an empty API for **63 hours**.

✅ **The capability already exists**; only the command is missing. `imac`
launched `raw/_migrations` through Dagster's GraphQL API and it succeeded in
under 20 seconds, creating the `raw` and `marts` schemas and 47 tables.

- [ ] 1.1 `./uis dagster materialize --all` — launch and wait, streaming step
      progress. Atlas's full load is 10.1 minutes across three jobs
- [ ] 1.2 `--select <asset>` for a single asset or group
- [ ] 1.3 `./uis dagster automation --start` / `--stop`. It currently reports
      `0 RUNNING, 4 STOPPED` and **cannot change it** — its only flag is
      `--expect`, an assertion

      ⚠️ **The two mutations return different types and guessing costs a
      round.** `startSchedule` returns `ScheduleStateResult`; `startSensor`
      returns `Sensor`. Guessing `SensorStateResult` gives a bare HTTP 400 with
      nothing in it (atlas, `urb-agents#629`, from a production go-live). That
      asymmetry is the reason this verb is worth more than the two-line
      workaround it replaces
- [ ] 1.3b 🔴 `./uis dagster run <job> [--wait]` — **not the same as 1.1.**
      `materialize` is asset-shaped; atlas's installer ends by naming **four
      jobs in order**, and there is no verb that runs a named job at all. The
      documented path today is a hand-written `launchPipelineExecution`
      mutation plus polling `runOrError`, which ops did on a production install
      and only managed because `imac` had written the shape down in
      `uis-tester`. ⚠️ **Without this verb the install guide teaches GraphQL**,
      which is where a novice stops (atlas, `urb-agents#629`)
- [ ] 1.4 ⚠️ `./uis dagster` appears **nowhere** in the 172-line help. `imac`
      found it by guessing. Whatever else this plan does, that line gets added
- [ ] 1.4a 🔴 **Poll the RUN, not the launch call.** ops measured a queue delay
      of **142.5 s** against a **105.1 s** runtime on `transform_checks` — the
      wait before the work starts was longer than the work. **imac, atlas and
      ops each called it hung while being early by under two minutes**
      (`urb-agents#648`). A `--wait` that watches the blocking launch call, or
      that gives up on a fixed short timeout, reproduces that verdict
      automatically and with the platform's authority behind it
- [ ] 1.4b 🔴 **`--wait` must report run state and elapsed time, NOT step
      counts.** atlas measured `transform_checks` looking hung — 45-second
      blocking launch, a minute at `NOT_STARTED`, succeeding in ~105 s — and
      **three people read it as a defect**, because all 647 checks run inside
      **one op**, so `pipelineOrError` and `executionPlanOrError` return
      *"1 op, 1 step"* instantly and cannot see the weight (atlas,
      `urb-agents#629`). Those two are the obvious probes. A `--wait` built on
      them would make UIS the fourth reader of a misleading signal, with the
      platform's authority behind it
- [ ] 1.5 The install summary should say which of the two a user probably wants
- [x] 1.6 ✅ **Done in 1.6.52** — `--dry-run` is advertised in `template list`,
      in `template info` and in the subcommand help. It pulls the definition
      and prints the numbered plan without installing anything; ops called it
      *"the clearest description of atlas that exists anywhere"* and found it
      only by reading the install usage line. A capability nobody is told about
      is one nobody has

## Phase 2 — `uis template status <id>`

The generic form is worth more than an Atlas-specific one, because templates
already declare `provides` and `exports`.

Every status-shaped command today reports **infrastructure** — services, hosts,
secrets, tools, platforms, networks. None reports a row, a source or a table,
which is the only thing the user came for.

`imac`'s sketch, rendered from one endpoint atlas already publishes
(`meta_sources`, carrying `latest_row_count`, `total_runs`,
`downstream_model_count`, `last_ingested_at`):

```
Atlas — http://api-atlas.localhost/
  sources    39 loaded, 2 never run, 41 declared
  records    2,906,032 rows
  endpoints  91 published
  last load  2026-09-10 09:06:23 UTC
  never run: frr, redcross-branches
```

> *One GET and a print. It answers "is my install healthy" better than
> `uis status` — `2 never run` is actionable; four green ticks are not.*

- [ ] 2.1 `uis template status <id>` reads the application record for its
      `exports`, fetches what the application publishes, and renders it
- [ ] 2.2 🔴 **No hardcoding of Atlas.** The application decides what it
      exposes; UIS renders it. An application that publishes nothing gets a
      status saying so, not an error
- [ ] 2.3 Decide the contract: which export name, and what shape. This is the
      one design question in the plan and it is a seam — so it belongs with
      `atlas` and `dev-templates`, not decided here alone
- [ ] 2.4 A URL column in `./uis status` for anything with an IngressRoute, and
      `verify` printing the address it probed. Both from #506 BLOCKING 4;
      1.6.38 did only the install summary

## Phase 3 — the non-blocking findings from #506

- [ ] 3.1 **N1** — when docker is absent UIS prints `docker: command not found`
      and then advises `docker build …`. Both remedies need the command just
      reported missing. Say: *"Docker was not found on your PATH. If you just
      installed Rancher Desktop, open a new terminal."* ⚠️ Real users hit this:
      `rcfiles` only affects new shells
- [ ] 3.2 **N2/N3** — the first-run Quick Start has no route to installing an
      application; `template info` says `Kind: application` while the help files
      it under "Template Deployment". `./uis template list   Show installable
      applications` closes both
- [ ] 3.3 **N9** — the `DAGSTER READY` block answers "where is it" and "how do I
      log in" and sits at line 682 of 701 as one 929-character line with literal
      `\n` escapes inside an Ansible debug envelope. Emit via the launcher's
      logger after the play, or pass `msg` as a YAML list
- [ ] 3.4 **F7** — Dagster tasks 11 and 14 are `...ignoring` with `no_log: true`,
      so a healthy first install prints two red censored `FAILED!` lines and a
      genuine failure looks identical
- [ ] 3.5 **N5/N6/N7** — `expose --status` lists a service then prints `(none)`;
      unescaped unicode in the multi-instance error; Dagster's output ends
      `Verify: ./uis verify dagster` for a verb the help does not document

## Acceptance

- [ ] a novice installs an application, loads its data and confirms it worked,
      using only commands the help documents
- [ ] 🔴 graded on a machine that has never run UIS — see
      [PLAN-templates-002](./PLAN-templates-002-application-catalogue.md). The
      findings this plan comes from were invisible on four clusters that had
      PostgreSQL and Dagster already installed

## Out of scope

- teaching UIS what Atlas's data means. `meta_sources` is atlas's contract;
  UIS renders whatever an application publishes
- scheduling policy. Whether an application ships with schedules stopped is the
  application's decision and `template info` already states atlas's
