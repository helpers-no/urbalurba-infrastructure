# Plan: "leaves the database alone" is not what a failed `init:` does

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Backlog

**Goal**: When an `init:` fails part-way through on a database that already
existed, UIS either applies none of it or says plainly that it applied some of
it. Today it says the first and does the second.

**Found**: 2026-09-10, reviewing a reinstall onto an existing installation
(`urb-agents#584`, `#593`). Not found by a test — found by reading the apply
function after `ops` asked a different question.

---

## The claim, in two places

`website/docs/reference/uis-cli-reference.md`:

> | a failing `init:` | refuses and leaves the database alone — **no rollback**, because that data predates the command |

`configure-postgresql.sh:320`:

```
# ⚠️ NO ROLLBACK HERE, deliberately. The create path drops the
# database it just made; this database predates the command and
# may hold data nothing can reconstruct. Refuse loudly and leave
# it alone
```

**The reasoning is right and the description is wrong.** Not dropping the
database is correct. "Leaves it alone" is not what happens.

## What actually happens

```
psql -h ... -U ... -d "$database" --set ON_ERROR_STOP=on -f -
```

`ON_ERROR_STOP=on` and **no `--single-transaction`**. So psql runs the script in
autocommit: every statement before the failing one is **committed**, the failing
one stops the run, and everything after it never runs.

🔴 So a failed `init:` on an existing database leaves it in a state that is
neither the old schema nor the new one, and the command reports
`database_preserved: true` — which is true about the *database* and reads as a
claim about the *schema*.

⚠️ **This is the failure shape this repository keeps finding**: a message that
describes a stronger guarantee than the code provides, written in the same
breath as the code, with only the succeeding path exercised. Recorded in
[PLAN-system-error-paths-audit](./PLAN-system-error-paths-audit.md), and the
first in that table where the overstatement is in the **reference
documentation** rather than in a log line.

## What it does not affect

- **The create path.** A failure there drops the database it just made, so
  partial application is invisible by construction. The bug is specific to the
  already-exists path.
- **A single-statement `init:`.** There is no "part-way" through one statement,
  so a bootstrap-shaped `init:` (`CREATE SCHEMA IF NOT EXISTS ...`) cannot reach
  this. The first application tenant is in exactly that position — measured, not
  assumed — which is why this is filed rather than escalated.
- **The idempotency contract itself.** That contract is documented, unambiguous
  and correct: *the schema after one application equals the schema after two*.
  This plan is not about tenants who violate it. It is about what UIS does when
  any `init:` fails for any reason — a syntax error, a lock timeout, a
  disconnect at statement 30 of 51.

## What needs deciding

1. **`--single-transaction`, or honest wording?** Postgres DDL is transactional,
   so one flag turns this into all-or-nothing and makes the existing sentence
   true.

   ⚠️ **But it is not free**: `CREATE INDEX CONCURRENTLY`, `VACUUM`, and
   `ALTER TYPE ... ADD VALUE` on older servers cannot run inside a transaction
   block, so the flag would break any tenant that needs them. Nobody needs them
   today; adopting the flag decides that nobody may.
2. **If the flag: is it default-on with an opt-out, or opt-in?** Default-on is
   the safe direction and silently forbids a legal SQL construct. An
   `init_single_transaction: false` escape hatch in the artifact keeps it legal
   and makes the tenant say so.
3. **What does the JSON report?** `database_preserved: true` is the field that
   currently overstates. It may need to become two facts — the database was not
   dropped, and whether the schema was left partial.

## Tasks

- [ ] 1.1 🟢 **Fix the wording first, independent of everything else.** It is
      free, it is true today, and it is strictly better than the current
      sentence whichever way question 1 goes
- [ ] 1.2 Decide question 1
- [ ] 1.3 If the flag: implement, with question 2's escape hatch decided
- [ ] 1.4 Split or rename the JSON field per question 3
- [ ] 1.5 Version bump

## Acceptance

- ⚠️ **A test where the `init:` fails at statement 2 of 3 on a pre-existing
  database**, asserting what remains. A test whose `init:` succeeds, or whose
  `init:` is one statement, exercises the branch that was always going to pass —
  which is how this survived every existing test
- no message, JSON field or doc row claims a guarantee the code does not give

## The lesson this plan carries

The comment explaining why there is no rollback is one of the better comments in
the file: it names the trade, names the data it is protecting, and refuses the
tidy-up. **Being right about the decision is not the same as being right about
the description**, and a good explanation is unusually effective at stopping
anyone from checking the sentence next to it.
