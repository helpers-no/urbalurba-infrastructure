# Plan: `configure postgresql --purge`, or an honest refusal

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Backlog

**Goal**: A per-app database, its owning role, and the Secret written by
`configure postgresql --secret-name-prefix` can be removed by a UIS command — or
UIS states that they cannot and why, in one place, rather than each caller
discovering it.

**Found**: imac, `urb-agents#367`, testing `template remove --purge`. It
announced dropping per-app roles and secrets **twice** and dropped none, exit 0.
`template remove` is fixed to call the verb that does drop
(`configure postgrest --purge`) and to name what it still cannot reach — but the
gap underneath is this.

---

## What exists and what does not

| handler | `--purge` | drops |
|---|---|---|
| `configure postgrest` | ✅ | the two per-app roles, the `<app>-postgrest` Secret |
| `configure postgresql` | ❌ **none** | — |

So today nothing in UIS can remove:

- the application's **database** (`CREATE DATABASE <app> OWNER <app>`)
- its **owning role**
- the Secret written by `--namespace` + `--secret-name-prefix` (`<prefix>-db`),
  which imac had to delete by hand

⚠️ **`configure postgrest --purge` does not touch that Secret either** — it is in
another namespace and belongs to the postgresql handler's work, not PostgREST's.
So it falls between two handlers, which is exactly how it went unnoticed.

## Why this is a plan and not a patch

Dropping a database is the most destructive operation in the product, and it
arrived as a finding in a test report. Adding that code path in a patch
responding to a test report is the wrong pressure to build it under.

Three things need deciding, and none is obvious:

1. **Does `--purge` drop the database, or refuse and print the SQL?** PostgREST's
   purge drops roles, which are cheap to recreate. A database is not. `undeploy`
   and `configure --purge` already draw one line; this may need a second.
2. **What about `--init-file` data?** A tenant's database holds what its pipeline
   produced. `configure postgresql` created the database but did not create the
   *data*, and the distinction matters for who may destroy it.
3. **Is the cross-namespace Secret the postgresql handler's to remove?** It wrote
   it, so probably yes — but it wrote it *into another service's namespace* on
   request, and deleting things in namespaces you do not own is how a platform
   surprises people.

## Tasks

- [ ] 1.1 Decide question 1. ⚠️ **A refusal that prints the exact SQL may be the
      right answer** — it is honest, it needs no new destructive path, and it is
      strictly better than today's silence. Do not assume the answer is "build it"

      🟢 **Independently endorsed by the tester** (imac, `urb-agents#367`), which
      matters because it is a second voice and not an echo of mine:

      > *"`configure postgresql` created the database but not the data in it …
      > so the question of who may destroy it is not answerable from inside the
      > CLI. **A refusal that prints the exact SQL is a real answer**, not a
      > placeholder; it puts the destructive act in a human's hands with no
      > ambiguity about what it will destroy. I would ship that and treat the
      > automated drop as the thing needing justification."*

      That inverts the default: the burden is on building the drop, not on
      declining to
- [ ] 1.2 If dropping: `configure postgresql --app <n> --purge`, refusing while
      any other app's Secret references the database, and requiring `--yes`
- [ ] 1.3 Remove the `<prefix>-db` Secret, or state why not (question 3)
- [ ] 1.4 Make `template remove --purge` call it and report from its JSON
- [ ] 1.5 Update the `template remove` docs, which currently name the gap
- [ ] 1.6 Version bump

## Acceptance

- after `template remove <id> --purge`, either nothing per-app remains, **or** the
  output names precisely what remains and the command that removes it
- no path announces a removal it does not perform

## The lesson this plan carries

🔴 **Three defects in this feature had the same shape: an announced action, no
action, exit 0.** The false code-location removal, the unforwarded override, and
this. In each case the message was written from the intent and the behaviour came
from somewhere else.

imac's framing is the one to keep: *"the reason I keep asserting on state rather
than on output — the output was confident and wrong in both cases."* So the
acceptance above is written as a state assertion, and the fix for this plan must
report from the handler's own JSON rather than from what the caller meant.
