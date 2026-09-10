# Plan: one deliberate pass over the error paths

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Backlog — 1.6 and 1.7 done and shipped (1.6.24), found while doing
something else; the deliberate pass (1.1-1.5) is still open, and 1.8 is new.

**Goal**: Every path that runs only when something has already failed is
exercised at least once, so a failure reports its cause instead of being
swallowed by the mechanism meant to handle it.

**Proposed by**: imac, `urb-agents#344`, after finding the third instance in one
week. **See the table below for the recorded instances**, most recently one at 1.6.49. Its words: *"Each was invisible until something failed, and each made the
**next** failure harder to diagnose. Might be worth one deliberate pass over the
error paths rather than three more of these arriving one at a time."*

---

⚠️ **The count in this document does not reconcile.** The prose has said *fifteen*
since 1.6.37 and the table lists fifteen rows including the 1.6.47 addition — so one
of the two was already wrong before this row, and nobody has established which. That
is this document's own last table row, applied to itself: *an unreconcilable number
is one nobody checks.* The sweep should settle it rather than carry it forward.

## The three, and what they have in common

| | Defect | Mechanism that defeated it |
|---|---|---|
| 1.6.9 | `installed_version()` returned empty while the image sat readable on disk, so `./uis version` said "no image on this machine yet" | `\|\|` binds to the **pipeline**, whose status is `tr`'s — the fallback was dead code |
| `#335` | Every `configure` failure in a template install was silent; a one-line usage error produced a 135-line log with no cause | `set -e` aborts on `x=$(cmd)` before `x_exit=$?` is read — the handler was unreachable |
| `#344` | `uis verify postgrest` failed with only `{"censored": ...}` on a healthy instance | `no_log: true` without `failed_when` — the task aborted and took the reason with it |

| `#367` | `template remove --purge` dropped the roles correctly, printed none of its reporting, skipped the record cleanup, and exited 4 | `x=$(… \| jq)` on a non-JSON stream — jq exits 4, the assignment inherits it, `set -e` kills the caller |
| 1.6.24 | `template remove` **could never refuse** while a dependant was installed, though the CLI reference documented that it would | `_applications_requiring` read `.requires` out of the record; `_record_application` never wrote the field. A guard whose input nothing produces |
| 1.6.24 | `_applications_requiring atlas` was **also** blocked by an application requiring `atlas-data` | `contains(["x"])` does **substring** matching on string array elements in jq and yq alike: `["atlas-data"] \| contains(["atlas"])` is true. A comparison that reads as membership and is not |
| 1.6.37 | 🔴 **`set -e` killed the error path in `configure postgresql`** — no error text, empty stdout, an orphaned role, and a retry that failed *earlier* than the first attempt | Three bare `x=$(cmd)` assignments followed by `if [[ $? … ]]`. **A lint for this existed and matched only the other spelling** (`rc=$?` alone on the next line) |
| 1.6.37 | 🔴 The PostgreSQL wait used `status.phase == "Running"`, which is true **before the server accepts connections** | Bitnami bounces the server twice during init; `CREATE DATABASE` missed a working server by **223 ms**. Two of three installs passed, so four gradings called it working |
| 1.6.34 | 🔴 A clean install **created a Secret and never wired it** — `EXIT=0`, schema and grants correct, API answering, and the application unable to reach its own database | `env_secrets` read as a list only; a scalar errored inside `join()` and `2>/dev/null` swallowed it. **My docs showed the scalar, my code took the list, my fixture used the list** |
| 1.6.31 | 🔴 **`log_warn`, `log_info`, `log_success`, `log_debug` and `log_progress` all wrote to STDOUT.** Only `log_error` went to stderr, so any diagnostic on a `--json` path corrupted the document a caller was capturing | A *successful* `configure` reported as a failure: the rotation warning landed ahead of the JSON, `_json_field` survived the parse but read an empty status, and the `*)` branch fired |
| 1.6.29 | `make-fixture.sh` printed `./uis template install uisfix` and, two lines below, *"only works because make-fixture adds it"* — **make-fixture added nothing**; every command it printed failed on the allowlist | A script asserting an action it does not take. The class, in a test fixture: the thing meant to catch this had it |
| 1.6.28 | The registry cache was **one file for any URL**, so switching `REGISTRY_URL_PRIMARY` served the previous registry for up to an hour | A cache keyed by nothing, in the documented testing path |
| 1.6.27 | 🔴 `configure postgresql --init-file -` **discarded the SQL** on a database that already existed, exit 0 | Init is applied at line 273; the already-exists branch returns at 231/234. The whole application-catalogue install-time guarantee, undelivered and unreported |
| 1.6.24 | 28 of 68 template tests reported **neither pass nor fail**, and the suite still printed `ALL TESTS PASSED` | `assert_equals "$a" "$b" "msg"` returned 0 and moved no counter. Failures were reported, so the verdict held — but the count could not be reconciled, and an unreconcilable number is one nobody checks |
| 1.6.47 | 🔴 A failing `init:` on an existing database is documented and commented as leaving it **alone**; statements before the failure are already committed, so the schema can be left part-applied | `psql --set ON_ERROR_STOP=on` with **no `--single-transaction`**. The comment explaining why there is no rollback is correct about the decision and wrong about the description — see [PLAN-cli-init-file-partial-apply](./PLAN-cli-init-file-partial-apply.md) |
| 1.6.49 | 🔴 A database dropped without its role made the next install publish a password **it never set** — `status: ok`, and the application cannot authenticate | `CREATE USER` fails, and the guard is `rc != 0 && ! _pg_user_exists` — it checks the role **exists**, not that its password is the one about to be written into a Secret and three connection strings. The correct branch already existed in `360-setup-dagster` task 13 and in `configure postgrest`'s state matrix; this was the third handler, catching up |

Every row above, a different mechanism, one shape: **error handling that looks
correct, defeated by the semantics of the construct it is written in, in a branch
nothing executes until something else is already wrong.**

🔴 **The twelfth is the first that is not silent, and imac's framing of that is
the most useful thing on this page:**

> *The first four were silent — the guard never ran. This one **runs, survives,
> and reports the wrong answer.** That is progress and a new failure mode at
> once, and it argues the assertion should be "a successful configure is
> reported as success", not "the runner does not abort".*

They are right, and it corrects something this plan had wrong. The `#367` fix
(`_json_field`) made the caller survive a non-JSON stream — necessary, and I had
been treating it as sufficient. Surviving the parse is not parsing it: an empty
status falls through to the failure branch and a success is reported as a
failure. **Assert on the outcome, not on the absence of a crash.**

⚠️ **And the twelfth was introduced by the fix for the ninth.** The rotation
warning added in 1.6.27 used `log_warn` for one line and an explicit `>&2` for
the next — two halves of one message on two streams. That is the second time in
this series a fix has carried the next instance (the fourth landed inside the
fix for the third). Three of the twelve now have that provenance.

🔴 **The fifth, sixth and seventh were found here, not by the tester** — the
first three of the seven that were. Both came from the same move: reading the CLI reference against
the code while finishing the docs task, and running the test suite with `yq` on
`PATH` for the first time. Neither needed a cluster.

⚠️ **The sixth is the class turned on the tests themselves**, and it is the one
worth keeping in view: every fix above landed "with tests", and a third of the
tests around the newest of them were reporting nothing at all. `yq` is not
installed on the maintainer's host, so the `yq`-dependent half of that suite had
never once run there — the guard against the guard was itself unexercised.

**Consequence, now implemented in `tests/lib/test-framework.sh`:** assertions
report their own success, outcomes are idempotent per test, and `print_summary`
**fails the suite** when started tests do not equal passed + failed + skipped.
A suite that cannot account for its own tests must not report green.

🔴 **The fourth landed inside the fix for the third.** The `INCOMPLETE` branch
existed to stop a purge failure being rounded up to success, and `set -e` meant
it could never say so. That is the strongest argument in this plan and it was not
available when the plan was written.

⚠️ **imac's diagnosis of the class, which is better than "be careful":**

> *"Each one is a different construct … What they share is that **the guard and
> the guarded thing are written in the same breath, and only the guarded thing
> gets exercised.**"*

And the consequence for task 1.5, in its words:

> *"This purge branch would have been caught by one test that runs `--purge`
> against an app with roles and asserts the exit code is 0 — which is the same
> test that would have caught the previous three in their own domains."*

So the highest-value work here is not reading code. It is **running each path in
its failure mode once and asserting the exit code**, which no amount of review
substitutes for.

⚠️ **Each one made the next failure harder to diagnose**, which is the compounding
part and the reason this is worth a pass rather than three more fixes. The
`no_log` case cost the tester a manual reproduction to learn what a single line
of stderr would have said.

## 🔴 The strongest evidence for a SWEEP rather than a queue of fixes

**The ninth instance already had its fix written — in the other handler.**

`configure postgrest` had exactly this defect: its `no-op` path `return 0`-ed
before any SQL ran, so the documented remediation for the `FOR ROLE` defect did
nothing and an operator was told "nothing to do" while holding a broken
instance (imac, `#330` Finding A). It was fixed: PHASE 5 now reapplies grants so
a re-run converges.

`configure postgresql` — the sibling handler, the same `already-configured`
shape, the same directory — kept it. Nobody looked across.

That is the argument for tasks 1.1–1.5 being a **pass over the class** rather
than a queue of individual fixes, and it is stronger than anything else in this
plan: *when you fix one of these, the same defect is usually sitting in the
nearest analogous code path, and fixing it there is nearly free at that moment
and nearly invisible later.* Add to the workflow: **after fixing an instance,
grep for the sibling.**

⚠️ It also says something about the two-week gap. The postgrest fix landed
`#330`; the postgresql twin survived until a static pre-flight of an unrelated
install path went looking. Nothing in between would have found it, because
nothing in between had a reason to read that branch.

## 🔴 The lint that missed the defect it was written for

The `set -e` instance above is the sharpest the class has produced, and imac
called it so: *the hazard is named in a comment twenty lines below two unguarded
uses.* It is worse than that.

**There was already a lint.** It matched one spelling:

```
x=$(cmd)
rc=$?                      <- a bare assignment, alone on the next line
```

and the defect used the other:

```
create_db_result=$(_pg_exec "CREATE DATABASE …")
if [[ $? -ne 0 ]]; then    <- $? inside a test
```

So the guard against this class was itself written in the same breath as the
one spelling its author had in mind, and only that spelling was ever exercised.
**Widening it to any `$?` after an unguarded command substitution immediately
found a third site imac could not reach** — the `ALTER USER` on the
already-exists path, which needs a database that already exists.

**The rule this adds:** when you write a lint for a defect, enumerate the
*spellings* of that defect, not the instance you just fixed. A lint that matches
one form is a lint that will be cited as coverage for all of them.

⚠️ **Sibling sweep, recorded not fixed.** The same phase-not-ready pattern
appears in `020-setup-tstweb-nginx.yml` (two sites) and `210-setup-litellm.yml`.
Deliberately untouched: they are off the application-install path, I cannot test
them, and a wrong label selector in `kubectl wait` breaks a deploy that works
today. Filed here so the next person does not have to rediscover them — and so
that leaving them is a decision on the record rather than an omission.

## 🔴 A guard that checks a field is WELL-FORMED does not check that it is TRUE

atlas's formulation, `urb-agents#538`, after their `operational.cadence` block
advertised a weekly scrape that has not run since 2026-08-25:

| where | the guard checked | the field promises |
|---|---|---|
| `first_data.jobs` (imac, `#507`) | every job **exists** | **coverage** — run these and you have the data |
| `operational.cadence` (`#538`) | every cron is **defined** | Atlas **runs** on it |

**Both guards were green while the artifact was wrong.** `SCRAPER_CRON` was
still a constant; `scraper_polled()` had no consumer. The block was telling
operators that Atlas scrapes a third-party site every Sunday — in a document
whose own text argues for staying welcome at public-sector APIs.

⚠️ **This is the general form of what my structural tests keep getting wrong.**
The `.app_name` assertion checked that the string *appeared*; the property was
that removal *resolves a tenant from the record*. The `kubectl wait` lint
checks that a retry is *present*; the property is that the wait *tolerates a
pod that does not exist yet*. Presence is cheap to assert and is not the claim.

**The rule:** when writing a guard, state the promise in a sentence first, then
ask whether the assertion could pass while the sentence is false. If it can,
the guard is testing well-formedness and the promise is untested.

atlas's fix is the right shape: a cron is now asserted **live** — an asset
references the builder that wraps it, or it is a `ScheduleDefinition`'s own
`cron_schedule` — and made to fail on purpose.

## A NEIGHBOURING class, worth naming separately rather than inflating this one

**Reconstructing a value that was recorded.** `template remove` stored the
code-location name *resolved* but reconstructed every other per-app name from
the record id — so an application installed with `--param app_name=X` planned a
removal against a **different tenant's** live instance (imac, `urb-agents#481`;
fixed 1.6.29 by recording `app_name`).

🔴 **This is not the same defect as the eleven above and should not be counted
with them.** Those are guards that cannot fire. This one fires perfectly and
computes the wrong target. But it shares the cure, which is why it belongs on
this page: **store the resolved value; never re-derive it from something that
merely usually equals it.** The code-location name learned that in 1.6.21 and
the app_name had to learn it again eight versions later, one field along.

⚠️ **And the reason four fixture rounds missed it is the most transferable
thing in this plan**, in imac's words:

> *`uisfix`'s template id and its `app_name` were the same string, so
> id-and-app_name could not diverge. This is the first install where they
> differ, and it is the first thing that broke.*

⚠️ **Second instance of this neighbouring class, 1.6.31:** `configure postgrest`
re-derived the database name (`app_name` with `-` → `_`) instead of being told
the one `configure postgresql` had just used. They matched for every install
ever run, because no `app_name` had contained a hyphen — **two derivations that
happen to agree are one bug waiting for an input.** Fixed the same way as
`app_name`: whichever service declares `database:` sets it for the whole
install, and nobody re-derives it.

So the cure has now been applied three times to three fields — the
code-location name (1.6.21), `app_name` (1.6.29), the database name (1.6.31) —
each found only when a real input made two "equal" things differ. **When a value
is computed in two places, write down which one is authoritative before an input
tells you.**

🔴 **Third time, 1.6.34, and now with a rule.** The fixture declared
`env_secrets` as a **list**; atlas declared a **scalar**; only the list worked.
The fixture had picked the working side of a difference again — after `id` vs
`app_name`, and after the id-and-app_name conflation before that.

**The rule, generalised past "make the pair differ":** when a field accepts
more than one shape, the fixture must use **the shape the documentation shows a
tenant**, not the shape the code was written against. Mine showed a scalar and
tested a list. The fixture now declares no `env_secrets` at all, which is the
recommended shape, and both explicit forms are covered by unit tests instead.

**A fixture that conflates two values cannot test the difference between them.**
The catalogue fixture now sets `id: uisfix` and `app_name: uisfixapp` on
purpose, with the reason in the file. Generalise it when building any fixture:
list the pairs of fields that are *allowed* to differ, and make each pair
actually differ.

## Why a pass rather than waiting for the fourth

These are not caught by tests, and the reason is structural: a unit test asserts
what happens when things work. Every one of the three had passing tests around it
while it was broken. The only thing that found them was somebody running the tool
and hitting a failure — which means the discovery rate is bounded by how often
things go wrong in front of a human.

**One useful precedent**: the `set -e` fix landed with a test that greps every lib
for the pattern and fails if it returns. That works because the defect has a
*syntactic* signature. Not all three do, which is what makes this a pass and not
a lint.

## Scope

- `provision-host/uis/lib/*.sh` and `manage/*.sh` — command substitution, `||`
  after pipelines, `set -e` interaction. **The syntactic ones are already
  linted**; this pass is for what the grep cannot see
- `ansible/playbooks/*-test-*.yml` and `*-setup-*.yml` — `no_log` without
  `failed_when`, `failed_when: false` with nothing asserting the result
  afterwards, and `assert` messages that name a cause they cannot know
- the launcher `uis` — its fallbacks, which is where instance 1 lived

## Tasks

- [ ] 1.1 Enumerate every `no_log: true` task and record, per task, whether a
      failure there can reach a human with its cause. Fix or justify each
- [ ] 1.2 Enumerate every `failed_when: false` and confirm something downstream
      actually asserts on the result. A silenced failure that nobody checks is
      worse than an abort
- [ ] 1.3 Find `assert` messages that state a cause the task cannot establish —
      the postgrest B2 message blamed pod reachability for what was a permission
      error, until `#330` corrected it. A confidently wrong diagnosis costs more
      than none
- [ ] 1.4 Extend the existing lint where a signature exists; record where it
      cannot, and why, so the next reader does not assume the lint is complete
- [ ] 1.5 For the highest-value paths, **make them fail on purpose once** and read
      what a human gets. That is what found all three of these
- [x] 1.6 🔴 **A guard whose input nothing produces.** New sub-class, found at
      1.6.24: `_applications_requiring` read a `.requires` field that
      `_record_application` never wrote, so `template remove` could not refuse
      while a dependant was installed — and the CLI reference documented the
      refusal as real. **Sweep for readers with no writer**: every field read out
      of `.uis.extend/*.yaml` should be greppable to the code that writes it.
      Fixed for this one, with tests asserting the ROUND TRIP (record it, then
      read it back) rather than the reader alone — testing the reader is exactly
      what let it through. ⚠️ The same function held an eighth-shaped defect one
      line away: `contains([x])` substring-matching where membership was meant.
      Both were in code the round-trip test was written for, and only the
      falsification run — reverting the fix and watching the test fail — proved
      the test could see either
- [x] 1.7 🔴 **The tests themselves.** `assert_x "$a" "$b" "msg"` counted no
      outcome, so 28 of 68 template tests reported neither pass nor fail while
      the suite printed `ALL TESTS PASSED`. Now: assertions self-report,
      outcomes are idempotent per test, and `print_summary` **fails** on any
      started test that reported nothing. All 24 unit and static suites
      reconcile after the change
- [ ] 1.8 ⚠️ **`oras` is installed nowhere the tests run.** Measured on the
      1.6.24 CI run, not assumed: GitHub Actions **has `yq`** and reports the
      same `73 / 70 / 3 skipped` as a local run with `yq` on PATH, so the
      `yq`-dependent tests are covered. The three `oras` resolution tests are
      skipped in CI *and* locally — they have never run anywhere except a
      provision host. Provision `oras` in the test job, or accept that pointer
      resolution is only ever exercised on a cluster and say so where a reader
      will see it.

      🔴 **The local half was mine, not CI's.** `yq` is absent on the
      maintainer's build host, so I had been reading `ALL TESTS PASSED` off runs
      that silently skipped 12 assertions CI was running for me. That is a
      verification defect in how I check my own work, not a coverage gap — and
      it is worth separating, because the first version of this task claimed
      the coverage gap and would have sent someone to fix CI
- [ ] 1.9 Version bump if any shipped path changes

## Acceptance

- no `no_log: true` task can abort without its cause reaching stderr
- every `failed_when: false` has an asserting consumer, or a comment saying why
  the result is genuinely discardable
- at least one deliberate failure per verify playbook has been observed and its
  output recorded in the plan

## Out of scope

Removing `no_log`. It is there because those tasks carry `PGPASSWORD` and that
must not reach a log. The fix is always `failed_when` plus an assert that reads
`stderr` — the field with the diagnosis — rather than `cmd`, the field with the
secret.

## Note on who should do this

⚠️ **The pass is worth little without a cluster.** Task 1.5 is the one that found
every instance so far, and it cannot be done from a build host. The reading and
the lint work anywhere; the deliberate failures belong with the tester.
